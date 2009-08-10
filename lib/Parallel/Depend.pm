########################################################################
# housekeeping
########################################################################

package Parallel::Depend;

use v5.10.0;
use strict;
use autodie qw( open close );

use File::Basename;
use IO::File;

use Benchmark       qw( :hireswallclock );
use Cwd             qw( abs_path );
use Scalar::Util    qw( blessed looks_like_number refaddr weaken );
use Storable        qw( dclone );
use Symbol          qw( qualify qualify_to_ref );
use List::Util      qw( first );

use Parallel::Depend::Queue;
use Parallel::Depend::Util;

########################################################################
# package variables
########################################################################

our $VERSION = v4.0.8;

# inside-out structure for the caller's objects.

my %mgr2que = ();

my $que_class  = qualify 'Queue';

# constant variables.

use vars qw
(
    $ad_hoc_group
    $group_job
);

*ad_hoc_group   = \q{_};
*group_job      = \'group';

# these get sanity checked, anything else gets
# slapped in place for the caller to deal with

my @standard_attrz
= qw
(
    autoload
    debug
    fork_ttys
    maxjobs
    nofork
    verbose
);

# these cannot be used as job names.

my @directivz
= qw
(
    :
    =
    %
    <
    ~
);

my @reserved_wordz
= 
(
    @directivz,
    '_'
);

# used with split to break up schedule lines 
# into [ name token value ] groups (notice the 
# capturing paren's around the [] literals).
#
# ':' may appear in a perl function definition.
# need to specifically look for the surrounding
# whitespace.

my $token_rx    = qr{ [ \t]+ ([@directivz]) [ \t]+ }xo;

########################################################################
# public interface, fodder for overloading
########################################################################

########################################################################
# queue returns the current manager's queue,
# share_queue installs a copy for use with a derived object.
#
# the initial queue is installed by prepare.

sub has_queue
{
    my $mgr = shift;

    exists $mgr2que{ refaddr $mgr }
}

*was_prepared = \&has_queue;

sub queue
{
    my $mgr = shift;

    @_
    ? $mgr2que{ refaddr $mgr } = shift
    : $mgr2que{ refaddr $mgr }
    or log_fatal "Bogus queue: unknown '$mgr'"
}

# Note: this may be called as a precaution.
# if the current manager does not have a queue
# then do nothing.
#
# caller gets back the que in case they need to
# modify something in-place as part of the 
# handoff.

sub share_queue
{
    my ( $mgr, $child ) = @_;

    my $que = $mgr2que{ refaddr $mgr }
    or return;

    $mgr2que{ refaddr $child }  = $que;
}

DESTROY
{
    my $mgr = shift;

    delete $mgr2que{ refaddr $mgr };

    return
}

# install set/get method for the standard attributes.

for my $name ( @standard_attrz )
{
    my $ref = qualify_to_ref $name;

    *$ref
    = sub
    {
        my $mgr     = shift;
        my $que     = $mgr2que{ refaddr $mgr };

        my $attrz   = $que->{ attrib } || $que->attrib;

        if( @_ )
        {
            given( shift )
            {
                when( undef )
                {
                    delete $attrz->{ $name }
                }

                default
                {
                    $attrz->{ $name } = $_
                }
            }
        }

        exists $attrz->{ $name }
        ? $attrz->{ $name }
        : return
    };
}

########################################################################
# call this before handing the arguments to prepare
# or ad-hoc off to $que->new;

sub validate_attrib
{
    shift;

    my %attrz   = ref $_[0] ? %{ $_[0] } : @_;

    $attrz{ maxjob  } //= 1;

    for my $name ( keys %attrz )
    {
        my $value   = $attrz{ $name };

        given( $name )
        {
            when( 'sched' )
            {
                # called from prepare (vs. ad_hoc).
                # shouldn't have any 'ad_hoc' attribute
                # set at this level.

                $attrz{ ad_hoc }
                and log_fatal "Bogus attributes: global 'ad_hoc'",
                \%attrz;
            }

            when( [ qw( logdir rundir ) ] )
            {
                $value
                or log_fatal "Bogus attribute: false '$name' ($value)";

                my $path = gendir $value
                or log_fatal "Bogus prepare: unusable '$name' ($value)";

                $attrz{ $_ } = $path;
            }

            when( 'nofork' )
            {
                # or-equals: even if this is assigned false
                # it will get set in debug mode without a
                # value for fork_ttyz.

                $attrz{ $_ }
                ||= $^P && $attrz{ fork_ttyz }
                ? ''
                : $^P
                ? 1
                : $attrz{ maxjob } < 0
                ? 1
                : ''
                ;
            }

            when( 'maxjob' )
            {
                $attrz{ nofork } = 1
                if $value < 0;
            }

            when( 'ad_hoc' )
            {
                $value //= 1;
            }

            # everything else defaults to zero.

            default
            {
                $attrz{ $_ } //= 0;
            }
        }
    }

    $^P && ! $attrz{ fork_ttys }
    and log_message "Debugger without fork_ttys: this may cause pain";

    $attrz{ verbose } //= '';
    $attrz{ debug   } //= '';

    # still alive?
    # then the attributes seem usable: hand back
    # the local copy.

    \%attrz
}

########################################################################
# parsing mechanism
########################################################################

# insert this job into the queue with a list of what
# it depends on.
#
# the keys of %$beforz are those jobs
# with jobs that go before them. They
# are runnable when all of the
# dependencies have been complated,
# i.e., the hash %{ $queued->{job} } is
# empty.
#
# $after->{$job} is an array of the
# other jobs that will depend on $job
# completing. This is used to quickly
# remove entries from
# $queued->{$anotherjob} when $job
# completes.
#
# for all pratical purposes, keys %$beforz is the
# "queue" here.

sub precheck
{
    my ( $mgr, $nspace, $job ) = @_;

    my $que     = $mgr->queue;

    local $que->{ namespace }   = $nspace;

    my $job_id  = $que->job_id( $job );

    my $attrz   = $que->merge_attrib( $job_id );

    my $prefix  = $que->{ prefix };

    my $force   = $attrz->{ force   };
    my $restart = $attrz->{ restart };
    my $usetty  = $attrz->{ ttylog  };

    for( @{ $attrz }{ qw( logdir rundir ) } )
    {
        -e or genpath $_;
    }

    @{ $que->{ files }{ $nspace, $job } }
    = map
    {
        my ( $type, $ext ) = @$_;

        my $base    = $nspace ? "$prefix.$nspace" : $prefix;
        my $path    = "$attrz->{ $type }/$base.$job.$ext";

        if( 'run' eq $ext )
        {
            if( $force )
            {
                # skip the sanity checks
            }
            elsif( -e $path )
            {
                my @linz
                = do
                {
                    open my $fh, '<', $path;

                    local $/ = "\n";

                    <$fh>
                };

                # at this point, anything without a
                # completion is fatal; the difference
                # is that restart records successful
                # completions.

                if( @linz < 3 )
                {
                    # precheck, no dispatch: looks
                    # like a running queue.

                    $force 
                    ? log_error "Possibly running: $nspace, $job ($path)"
                    : log_fatal "Running queue: $nspace, $job ($path)"
                    ;
                }
                elsif( @linz < 4 )
                {
                    # precheck + dispatch, no exit:
                    # looks like a running job.

                    $force 
                    ? log_error "Possibly running: $nspace, $job ($path)"
                    : log_fatal "Running job: $nspace, $job ($path)"
                    ;
                }
                elsif( $restart )
                {
                    # record false exits to skip the
                    # job on this pass. execute and
                    # complete use the false skips
                    # to stub the job instead of
                    # actually running it.

                    chomp( my $exit = $linz[-1] );

                    $exit
                    or $que->{ skip }{ $nspace, $job } = 0;
                }
                else
                {
                    # if not restarting a queue, the
                    # exit status is immaterial if
                    # the job completed: do nothing.
                }
            }

            # at this point the existing path is
            # no longer useful: generate the new
            # runfile and populate it with the
            # precheck data.
            #
            # trapping problems opening the files
            # here saves a LOT of trouble.

            eval
            {
                my $fh  = IO::File->new( "> $path" )
                or die "Roadkill: open '$path', $!\n";

                $fh->printflush( "'$nspace'\n$job\n" )
                or die "Roadkill: print '$path', $!\n";
            }
            or log_fatal $@;

            -e $path
            or die "Roadkill: missing '$path'\n";

            # at this point the file seems usable.

            $path
        }
        elsif( $usetty )
        {
            # logfiles are useless if output is going
            # to the tty: remove them to avoid stale
            # data on restarts.

            -e $path && unlink $path;

            ()
        }
        else
        {
            # zero out the log file, also
            # sanity checks whether the file
            # can safely be opened later.

            open my $fh, '>', $path
            or die "Roadkill: open '$path', $!\n";

            $path
        }
    }
    (
        [ rundir => 'run' ],
        [ logdir => 'out' ],
        [ logdir => 'err' ],
    );

    # at this point the job is runnable and has
    # the file handles stored for future use.

    return
}

########################################################################
# parse the schedule.
# this is broken up into chunks to simplify
# reading the code.
# the entry points are prepare (new schedule) and 
# ad_hoc (add jobs to existing schedule from within
# a job running within the schedule).

{
    # the following lexicals make up the guts
    # of both prepare and ad_hoc public methods.

    # values here are set up in the public subs,
    # used by the lexical ones.

    my $mgr         = '';
    my $que         = '';

    my $verbose     = '';
    my $detail      = '';
    my $debug       = '';

    # pre-declare $add_sched to allow recursion
    # from $add_groups.

    my $add_sched   = '';

    # attributes are put aside by namespace
    # and overlaid onto the current attributes
    # when a job is dispatched.
    #
    # the rest live in a flat namespace by
    # { $nspace, $job_id }

    my $add_attrib
    = sub
    {
        my $tokenz = shift;

        log_message "Add attrib: '$que->{ namespace }'"
        if $detail;

        # grab a reference to the namespace
        # attributes and install the schedule
        # values into them.

        my $attrz   = $que->attrib;

        %$attrz =
        (
            %{ $que->{ attrib } },
            map
            {
                '%' eq $_->[0]
                ? @{ $_ }[1,2]
                : ()
            }
            @$tokenz
        );

        # reset the verbosity using the
        # current attributes. allows
        # groups to manage their own
        # verbose level.

        $verbose    = $attrz->{ verbose };
        $detail     = $verbose > 1;
        $debug      = $attrz->{ debug   };

        log_message 'Current:', $attrz, 'Global:', $que->{ _attrib }
        if $detail;

        return
    };

    my $add_job_attrib
    = sub
    {
        my $tokenz = shift;

        log_message "Add job Attrib: '$que->{ namespace }'"
        if $detail;

        # jobs may have multiple settings:
        # have to accumulate them.

        my %jobz    = ();

        for( grep { '~' eq $_->[0] } @$tokenz )
        {
            my ( $attr, $val ) = split /\s+/, $_->[2], 2;

            $val //= 1;

            $jobz{ $_->[1] }{ $attr } = $val;
        }

        log_message 'Job:', \%jobz, 'Global:', $que->{ _attrib }
        if $detail;

        # note that this will usually add nothing to
        # the local area since most jobs will not have
        # any settings.

        while( my( $job, $attrz ) = each %jobz )
        {
            $que->set_job_attrib( $job => $attrz );
        }

        return
    };

    my $add_alias
    = sub
    {
        my $tokenz = shift;

        log_message "Add alias: '$que->{ namespace }'"
        if $detail;

        my $aliasz = $que->alias;

        %$aliasz =
        (
            %{ $que->{ alias } },
            map
            {
                '=' eq $_->[0]
                ? @{ $_ }[1,2]
                : ()
            }
            @$tokenz
        );

        log_message $aliasz
        if $detail;

        return
    };

    my $add_depend
    = sub
    {
        my $tokenz = shift;

        my $nspace  = $que->{ namespace };
        my $beforz  = $que->{ before };
        my $afterz  = $que->{ after  };

        log_message "Add depend: '$nspace'"
        if $detail;

        for( grep { ':' eq $_->[0] } @$tokenz )
        {
            log_message 'Processing rule:', $_
            if $detail;

            # split up the dependencies into after and
            # before jobs.
            #
            # initial sanity check: none of the after
            # jobs are in the before list.

            my( $a, $b ) = map { [ split ] } @{ $_ }[1,2];

            for my $job ( @$a )
            {
                first { $_ eq $job } @$b
                and log_fatal "Bogus $nspace: self-dependenent '$job'";
            }

            # precheck each job once.  this looks
            # for problems in the external
            # environment (e.g., running jobs).

            for my $job ( @$a, @$b )
            {
                next if exists $beforz->{ $nspace, $job };

                first { $_ eq $job } @reserved_wordz
                and log_fatal "Unusable job name: '$job' (reserved)";

                log_fatal "$$: Unrunnable: $job"
                if $mgr->precheck( $nspace, $job );

                $beforz->{ $nspace, $job }   = {};
                $afterz->{ $nspace, $job }   = [];
            }

            # at this point every job in the rule has been
            # put where we can find it again. now to deal
            # with the targets.
            #
            # assigning $beforz->{ $after_id } guarantees
            # that the job is in the schedule even if it
            # has no prior jobs.

            for( @$a )
            {
                my $after_id    = $que->job_id( $_ );

                my $ab          = $beforz->{ $after_id } = {};

                for( @$b )
                {
                    my $before_id   = $que->job_id( $_ );

                    @{ $ab }{ $before_id } = ();

                    push @{ $afterz->{ $before_id } }, $after_id;
                }
            }

            # at this point all jobs are cataloged by what
            # must run before they can start in
            # $que->{ before } and which jobs to notify after
            # it runs in $que->{ after }.
        }

        log_message
        'Before:', $beforz,
        'After:',  $afterz
        if $detail;

        return
    };

    # groups are skipped as a unit: if the group has
    # a zero skip value then it is stubbed in the
    # schedule and its contents are ignored.

    my $add_single_group
    = sub
    {
        my ( $group, $sched ) = @_;

        my $nspace  = $que->{ namespace };
        my $beforz  = $que->{ before };
        my $afterz  = $que->{ after  };

        my @in_group
        = eval
        {
            local $que->{ namespace }
            = $que->namespace( $group );

            log_message "Group: '$group' ($que->{namespace})"
            if $detail;

            # localize the group's data, its own group
            # entry is redundent at this point.

            my $save_mgr
            = delete $que->{ attrib }{ save_mgr };

            local $que->{ attrib }  = $que->attrib;
            local $que->{ alias  }  = $que->alias;

            $que->{ attrib }{ ad_hoc_mgr } = $mgr
            if $save_mgr;

            $add_sched->( $sched );

            my $prefix  = $que->job_id;

            grep
            {
                ! index $_, $prefix
            }
            keys %$beforz
        };

        # the group itself has to be run in the 
        # foreground in order to clean out the 
        # queue structure when it completes.

        $que->set_job_attrib
        (
            $group, ad_hoc => 1
        );

        # note that @in_group may be empty, main
        # example will be ad_hoc jobs that don't
        # return any jobs to run.

        $@ and log_fatal "Failed group: '$group'", $@;

        # insert this into the parent's alias table
        # not the group's.

        $que->{ alias }{ $group } ||= $group_job;

        # catch: the group has to depend on all
        # of its immediate members, and thus runs
        # after them. this means that the group
        # members have to be started before the
        # group.
        #
        # fix:
        #
        # - add the group's contents into its
        #   own before list.
        # - add the group's before entries
        #   into its children,
        # - push the group's contents onto
        #   the after list of the group's
        #   own before list.
        #
        # this leaves the group's before jobs
        # enabling the group entries, which
        # then enable the group.

        my $group_id    = $que->job_id( $group );

        my @priorz      = keys %{ $beforz->{ $group_id } };

        # the group runs after its contents.

        @{ $beforz->{ $group_id } }{ @in_group } = ();

        # tie the group to its contents and
        # the contents to the group's befores.

        for my $job_id ( @in_group )
        {
            push @{ $afterz->{ $job_id } }, $group_id;

            @{ $beforz->{ $job_id } }{ @priorz } = ();
        }

        # inverse of the previous step: add the group
        # contents onto the after list of jobs running
        # before the group.

        for my $job_id ( @priorz )
        {
            push @{ $afterz->{ $job_id } }, @in_group;
        }

        # at this point jobs the group depends on will
        # enable the group members, an the group members
        # will enable the group itself; the group runs
        # last.

        return
    };

    my $add_groups
    = sub
    {
        my $tokenz = shift;

        my $nspace  = $que->{ namespace };

        my $skipz   = $que->{ skip   };
        my $afterz  = $que->{ after  };
        my $beforz  = $que->{ before };

        my $aliasz  = $que->{ alias };

        my %groupz  = ();

        log_message "Add groups: '$nspace'"
        if $detail;

        for( grep { '<' eq $_->[0] } @$tokenz )
        {
            my ( undef, $group, $syntax )   = @$_;

            $group ne '_'
            or log_fatal "Unusable group: '_' (reserved word)";

            # ignore any groups not listed in the
            # dependencies.

            exists $beforz->{ $nspace, $group }
            or next;

            exists $skipz->{ $nspace, $group }
            &&
            ! $skipz->{ $nspace, $group }
            or do
            {
                # anything not being skipped 
                # needs to be added into the 
                # schedule.

                $syntax =~ s{ \s+ $}{}x;

                $syntax =~ s{ \s* > $}{}x
                or log_fatal
                "Bogus entry: '$group' ($nspace) lacks '>' in '$syntax'";

                push @{ $groupz{ $group } }, $syntax;
            }
        }

        log_message \%groupz
        if $detail;

        while( my ( $group, $sched ) = each %groupz )
        {
            $add_single_group->( $group, $sched );
        }
    };

    $add_sched
    = sub
    {
        my $sched   = shift;

        my @tokenz
        = map
        {
            # convert:
            # 'foo : bar'   -> [ qw( : foo bar   ) ]
            # 'more = less' -> [ qw( = more less ) ]
            # 'verbose % 2' -> [ qw( % verbose 2 ) ]
            #
            # 'x < y = z >' -> [ '<',  'x', 'y = z >' ]
            #
            # Yes: this leaves a dangling '>' on the group
            # definitions that has to get split off in the
            # group handler (see exampe, above).

            [ ( split $token_rx, $_, 2 )[ 1, 0, 2 ] ]
        }
        grep
        {
            # strip out obvious whitespace and comment lines
            # zero-width negative look-behind avoids stripping
            # any non-comment char's preceeding the comment.

            s{ (?<![\\])[#] .* $}{}x;

            s{^ \s+  }{}x;
            s{  \s+ $}{}x;

            s{ ([@directivz]) $ }{$1 }xo;

            m{\S}
        }
        ref $sched
        ? @$sched
        : ( split /\n/, $sched )
        ;

        log_message 'Tokens:', \@tokenz
        if $detail;

        # pass the tokens through each stage of the 
        # compiler.

        for
        (
            $add_attrib,
            $add_job_attrib,
            $add_alias ,
            $add_depend,
            $add_groups,
        )
        {
            $_->( \@tokenz );
        }

        # at this point the schedule has been
        # installed into the queue object.

        return
    };

    # leave any jobs with empty 'before' lists
    # runnable.

    my $unblock_jobs
    = sub
    {
        $_ && %$_ or $_ = ''
        for values %{ $que->{ before } };

        return
    };

    sub prepare
    {
        # scrub, default, and install the args.
        # then pass the schedule into add_sched.

        $mgr        = shift;

        blessed $mgr
        or log_fatal "Bogus prepare: not a class method ($mgr)";

        my $argz    = $mgr->validate_attrib( @_ );

        $debug      = $argz->{ debug   };
        $verbose    = $argz->{ verbose };
        $detail     = $verbose > 1;

        log_message 'Preparing:', $argz
        if $verbose;

        my $sched   = delete $argz->{ sched }
        or log_fatal "Bogus prepare: '$mgr' lacks sched", $argz;

        $que
        = eval
        {
            # generate and install the que data
            # handler for this manager.

            my $class
            = delete $argz->{ queue_class } || $que_class;

            my $q   = $class->new( $argz );

            $mgr->queue( $q )
        }
        or log_fatal "Failed queue generation: $@";

        log_message 'Initial queue:', $que
        if $detail;

        eval
        {
            my $init_nspace             = 

            local $que->{ namespace }
            = $que->{ _namespace }
            = $argz->{ namespace } || '';

            local $que->{ attrib }      = $que->attrib;
            local $que->{ alias  }      = $que->alias;

            $que->{ attrib }{ init_namespace }
            = $init_nspace;

            $DB::single = 1 if $^P && $debug;

            $add_sched->( $sched );

            $unblock_jobs->();
        };

        $@ and log_fatal 'Failed schedule:', $@;

        log_message 'Resulting queue:', $que
        if $detail;

        # at this point the schedule is folded into
        # the queue structure.
        #
        # pass back the manager object for daisy-chaining.

        $mgr
    }

    # generate a virtual job with empty job_id, this gets
    # added to the blocking lists for any jobs the current
    # job is blocking. after that, current job can finish
    # without its dependent jobs starting prematurely.

    sub ad_hoc
    {
        $mgr        = shift;

        $que        = $mgr->queue
        or log_fatal
        "Bogus ad_hoc: '$mgr' has no queue",
        'Missing $parent->share_queue( $child )?',
        ;

        my $sched   = @_ > 1 ? [ @_ ] : shift
        or log_fatal "Bogus ad_hoc: missing schedule";

        ref $sched
        or $sched   = [ split /\n/, $sched ];

        $verbose    = $mgr->verbose;

        log_message 'Adding ad-hoc:', $sched
        if $verbose;

        # simplify cases where the generator may end
        # up with nothing to schedule.

        @$sched or return;

        # at this point it seems like the
        # schedule is worth installing.
        #
        # this much of the work has to be
        # done in the starting namespace.

        my $job     = $que->{ job }
        or log_fatal "Bogus ad_hoc: no job";

        my $job_id  = $que->{ job_id }
        or log_fatal "Bogus ad_hoc: no job_id";

        # sanity check the ad-hoc group, add it
        # to the overall queue.

        my $nspace  = $que->namespace( $job );

        $mgr->precheck( $nspace, $ad_hoc_group );

        # then localize the state, installing a
        # the parent's attribute values on the way.

        local $que->{ namespace } = $nspace;
        local $que->{ alias     } = $que->alias;
        local $que->{ attrib    } = $que->attrib;

        # flag for add_single_group; removed
        # during processing.

        $que->{ attrib }{ save_mgr } = 1;

        ( $debug, $verbose ) 
        = @{ $que->{ attrib }}{ qw( debug verbose ) };

        $detail     = $verbose > 1;

        $add_single_group->( $ad_hoc_group => $sched );

        my $beforz  = $que->{ before    };
        my $afterz  = $que->{ after     };

        my $blocked = $afterz->{ $job_id };

        $afterz->{ $nspace, $ad_hoc_group } = $blocked;

        for( @$blocked )
        {
            $beforz->{ $_ }{ $nspace, $ad_hoc_group } = ();
        }

        # at this point the dependencies have been handled,
        # unblock any runnable jobs.

        $unblock_jobs->();

        log_message 'Resulting queue:', $que
        if $detail;

        return
    }

}

########################################################################
# duplicate and localize the consumable portons
# of the queue structure, then dequeue and
# complete all of it. if there are ever pending
# but un-runnable jobs then the queue is deadlocked.

sub validate
{
    my $mgr = shift;

    my $que = $mgr->queue;

    # localize consumed portions of the queue.

    local $que->{ skip }    = dclone $que->{ skip };
    local $que->{ after }   = dclone $que->{ after };
    local $que->{ before }  = dclone $que->{ before };

    local $que->{ check }   = 1;

    local $que->{ namespace }
    = $que->{ _namespace };

    while( $mgr->queued )
    {
        my @runz    = $mgr->runnable
        or log_fatal 'Deadlocked queue:', $que;

        for( @runz )
        {
            $mgr->dequeue( $_ );
            $mgr->complete( $_ );
        }
    }

    # survival indicates that the dependencies are usable.

    $mgr
}

########################################################################
# prepare the jobs for execution and disptach them.
#
# unalias is called just prior to the job being
# dequeued and can be overloaded to return just
# about anything.

my $nil     = sub{ 0 };
my @stubz   = qw( PHONY STUB );

# convert a job_id or job name to the alias 
# and optionally the job name.

sub unalias
{
    my $mgr     = shift;

    my $que     = $mgr->queue;
    my $attrz   = $que->attrib;

    my ( $run, $job ) = $que->resolve_alias( @_ );

    my $name
    = $run ne $job
    ? "$job ($run)"
    : $job
    ;

    my $verbose = $attrz->{ verbose };
    my $detail  = $verbose > 1;

    # use the calling object to dispatch
    # methods in the closure if this job
    # was entered via an ad_hoc schedule.

    exists $attrz->{ ad_hoc_mgr }
    and $mgr = $attrz->{ ad_hoc_mgr };

    my $package = blessed $mgr;

    log_message "Resolving methods in: $package"
    if $verbose;

    my $sub = '';

    given( $run )
    {
        # @stubz check has to be first.
        # next few are in the likely order, with
        # AUTOLOAD the last internal check and
        # then shellexec as default.
        #
        # Note: shellexec *always* logs its use to
        # help catch typos in method names, etc.

        when( @stubz )
        {
            log_message "Stub: $job"
            if $detail;

            $sub = $nil;
        }

        when( $mgr->can( $_ ) )
        {
            if( $detail )
            {
                my $class   = blessed $mgr;

                log_message "$class can: $_"
            }

            # closure isolates the current manager.

            $sub = sub { $mgr->$run( $job ) };
        }

        when( ( my $i = rindex $_, '::' ) > 0 )
        {
            my $pkg = substr $run, 0, $i;
            my $sub = substr $run, $i+2;

            eval "require $pkg"
            or log_fatal "Bogus unalias: failed require '$pkg', $@";

            my $ref = $pkg->can( $sub )
            or log_fatal "Bogus unalias: '$pkg' cannot '$sub' in $name";

            log_message "$pkg can: $job"
            if $detail;

            $sub = sub { $ref->( $job ) };
        }

        when( /^ [{] .* [}] $/x )
        {
            # literal block => eval it as sub code.
            # notice the .*: this may be an empty block!

            log_message "Literal block"
            if $detail;

            $sub = eval "sub $run"
            or log_fatal "Bogus unalias: Invalid block for $job: $run";
        }

        default
        {
            # no obvious way to dispatch the thing using
            # method, sub, or block: punt to autoload or
            # shell to handle the thing. note that autoload
            #
            # logging threshold for these is lower since
            # errors are harder to trace.

            if
            (
                $que->{ attrib }{ autoload }
                and
                $mgr->can( 'AUTOLOAD' )
            )
            {
                # they asked for it... let the autoload
                # demangle the run call for itself.

                log_message "Autoload: $run ($job)"
                if $verbose;

                $sub = sub { $mgr->$run( $job ) };
            }
            else
            {
                # punt whatever it is to the shell.
                # this allows the path to resolve shell commands but
                # will require shell items with the same names as methods
                # to have a '/' inserted in them somewheres.
                #
                # worthwhile to warn people about this.

                log_message "Shellexec: $run ($job)"
                if $verbose;

                $sub = sub { $mgr->shellexec( $run ) };
            }
        }
    }

    wantarray
    ? ( $run => $sub )
    : $sub
}


########################################################################
# runjob is called for everything that gets executed.
# if all restults are logged, with numeric returns
# taken as-is for exit values. note that $sub is the
# anon sub returned from unalias, above.
#
# shellexec handles the bookkeeping of system and
# non-zero exit status.

sub runjob
{
    my ( $mgr, $job_id, $sub ) = @_;

    $mgr->run_message( $job_id, pid => $$ );

    my $que     = $mgr->queue;
    my $filz    = $que->{ files }{ $job_id };

    my $result
    = eval
    {
        # no reason this couldn't re-open stdin if
        # a file were found. problem is passing in
        # the path -- probably better off leaving
        # that to the running modules than finding
        # a reliable way to manage it.

        local *STDOUT = IO::File->new( '>>' . $filz->[1] )
        if $filz->[1];

        local *STDERR = IO::File->new( '>>' . $filz->[2] )
        if $filz->[2];

        $sub->()
    };

    my $err = $@;

    $mgr->run_message( $job_id, result => $result // $err );

    my $exit
    = looks_like_number $result
    ? $result
    : $err
    ? -1
    : 0
    ;

    $exit
}

sub shellexec
{
    my $mgr = shift;

    # if anything goes wrong put a message
    # into the logfile and pass the non-zero
    # exit status up the food chain.

    if( system(@_) == -1 )
    {
        # we failed to run the program,

        log_fatal "Failed system: $!", \@_;

        -1
    }
    elsif( $? )
    {
        # system succeeded in running the
        # program but it failed during
        # execution.

        if( my $exit = $? >> 8 )
        {
            log_error "Non-zero return for $_[1]: $exit";
        }
        elsif( $? & 128 )
        {
            log_error "Coredump from $_[1]";
        }
        elsif( my $signal = $? & 0xFF )
        {
            log_error "$_[1] stopped by signal: $signal";
        }

        $?
    }
    else
    {
        log_message 'Succeeded:', \@_
        if $mgr->verbose > 1;

        0
    }
}

# placeholder for $mgr->group( $group_name )
# dispatched in execute.
#
# hand back the group name.

sub group
{
    # this has to clean out the attributes
    # for the group. avoids clutter and 
    # allows destruction of ad_hoc_mgr.

    my ( $mgr, $group ) = @_;

    my $que     = $mgr->queue;

    $que->purge_group( $group );

    my $nspace  = $que->{ namespace };

    log_message "Complete: group $nspace - $group";

    "'$group' ($nspace)"
}

########################################################################
# dispatch the queue.
########################################################################

########################################################################
# anything in the 'before' list -- runnable or not --
# is pending.
#
# only job_ids with an empty value in the list
# are runnable.

sub queued
{
    my $mgr     = shift;
    my $que     = $mgr->queue;
    my $beforz  = $que->{ before };

    # reduce the question to pure boolean.

    !! keys %$beforz
}

sub runnable
{
    my $mgr     = shift;
    my $que     = $mgr->queue;
    my $blocked = $que->{ before };

    grep
    {
        ! $blocked->{ $_ }
    }
    keys %$blocked
}

########################################################################
# the queue my be examined any nubmer of times
# during the lifetime of one job. therefor the
# jobs have to be removed from the before section
# prior to being dispatched in order to avoid
# multiple dispatches.

sub dequeue
{
    my ( $mgr, $job_id ) = @_;

    my $que     = $mgr->queue;

    delete $que->{ before }{ $job_id };

    $que->{ check }
    or $que->{ times }{ $job_id }  = Benchmark->new;

    return
}

sub complete
{
    my ( $mgr, $job_id, $exit ) = @_;

    $exit   //= 0;

    my $que     = $mgr->queue;
    my $attrz   = $que->merge_attrib( $job_id );

    my $skipz   = $que->{ skip };
    my $beforz  = $que->{ before };
    my $afterz  = delete $que->{ after }{ $job_id };

    unless( $que->{ check } )
    {
        # skip the last words and file check
        # in validate mode.

        my $timestr
        = do
        {
            my $t0  = delete $que->{ times }{ $job_id };
            my $t1  = Benchmark->new;

            timestr timediff $t1, $t0;
        };

        $mgr->run_message( $job_id, time => $timestr );
        $mgr->run_message( $job_id, exit => $exit );

        log_message "Complete: '$job_id', $exit ($timestr)"
        if $attrz->{ verbose } > 1 ;

        # discard the files structure.

        delete $que->{ files }{ $job_id };
    }

    if( $exit && $attrz->{ abort } )
    {
        # if the job failed with abort mode then
        # there is nothing more to do.
        #
        # Note: this is not an issue for skipped
        # jobs since exit is false (undef).

        my ( $nspace, $job ) = $que->job_id_split( $job_id );

        log_fatal "Abort: Non-zero exit, $nspace, '$job'", $exit
    }
    elsif( $exit )
    {
        # propagate the reason to any following
        # jobs in no-abort mode.

        $skipz->{ $_ } = "Non-zero exit: $job_id, $exit"
        for @$afterz;
    }

    # if we are still alive at this point then
    # enable the following jobs.

    if( exists $skipz->{ $job_id } )
    {
        if( my $reason = delete $skipz->{ $job_id } )
        {
            # propagate any fatality to following
            # jobs in no-abort mode.

            $skipz->{ @$afterz } = ( $reason ) x @$afterz;
        }
        else
        {
            # false skip entry: successful job
            # skipped on restart => pretend it
            # completed successfully.
        }
    }

    # regardless of skip chain, enable
    # the following jobs.

    for( @$afterz )
    {
        for( $beforz->{ $_ } )
        {
            delete $_->{ $job_id };

            $_ && %$_ or $_ = '';
        }
    }

    # at this point the before list of any
    # jobs following this one have been updated
    # and any skip reasons have been propagated
    # to the next level.

    return
}

########################################################################
# runfile output: append a message or write-and-close the file.

sub run_message
{
    # ignore the type for file storage, use it
    # it is mainly useful for tied databases to
    # keep track of $run->{ $jobid, $type }.

    my ( $mgr, $job_id, $type, $data ) = @_;

    my $que     = $mgr->queue;

    my ( $nspace, $job ) = $que->job_id_split( $job_id );

    my $path    = $que->{ files }{ $job_id }[0]
    or log_fatal "Bogus run_message: '$job' ($nspace) lacks runfile";

    my $fh  = IO::File->new( '>>' .  $path )
    or log_fatal "Bogus run_message: open '$path' for '$job'($nspace), $!";

    chomp $data;

    $fh->printflush( $data, "\n" );

    return
}

sub install_fork_tty
{
    my $mgr = shift;

    my $que = $mgr->queue;

    if( my $ttyz = $que->{ attrib }{ fork_ttys } )
    {
        $DB::fork_TTY   = shift @$ttyz
        or do
        {
            log_fatal 'No tty available';

            exit -1;
        };

        -e $DB::fork_TTY
        or do
        {
            log_fatal "Non-existant: '$DB::fork_TTY'";

            exit -1;
        };

        # at this point the tty should be usable.
    }
    else
    {
        # assume that people know what they are doing
        # running with $^P set and no ttys (e.g., 
        # profiling the code).
    }
}

########################################################################
# do the deed.
# this is where the before/after lists are consumed, unalias is
# called, and the results written out.
#
# HUP: stop dispatching new jobs and wait for
# the current ones to exit.
# TERM: blast anything running, reap them,
# and record the results.
# QUIT/INT: blast the forks and exit immediately.

sub execute
{
    my $mgr     = shift;
    my $que     = $mgr->queue;

    exists $que->{ executed }
    and log_fatal "Bogus execute: already executed ($mgr)";

    # used to track jobs with forked dispatch.
    # $que->{ forkz }{ $pid } = $job_id;

    log_fatal "Bogus execute: running queue", $que->{ forkz }
    if $que->{ forks };

    my %forkz   = ();

    local $que->{ forks } = \%forkz;

    # install attributes for this context.

    local $que->{ attrib }  = $que->attrib;

    my $skipz   = $que->{ skip };
    my $filz    = $que->{ files };

    my $attrz   = $que->{ attrib };

    my $debug   = $attrz->{ debug   };
    my $verbose = $attrz->{ verbose };

    my $detail  = $verbose > 1;

    # signal handling in the parent.
    # these are disabled in the child process
    # when forking.
    #
    # $parent check avoids a logic race if a
    # signal arrives before the child has a 
    # chance to reset the signal handlers.

    my $abort   = '';
    my $parent  = $$;

    local $SIG{ HUP }
    = sub
    {
        if( $$ == $parent )
        {
            $abort  = "$$ killed with HUP";
        }
        else
        {
            $SIG{ HUP } = 'DEFAULT';
            kill HUP => 0;
        }
    };

    local $SIG{ TERM }
    = sub
    {
        if( $$ = $parent )
        {
            $abort  = "$$ killed with TERM";

            kill TERM => keys %forkz;

            # don't exit: just reap the proc's as
            # they exit from the sigterm.
        }
        else
        {
            $SIG{ TERM } = 'DEFAULT';
            kill TERM => 0;
        }
    };

    local $SIG{ INT }
    = sub
    {
        if( $$ == $parent )
        {
            # blow off the forks and flag
            # all of the jobs running for
            # restart.

            kill INT => keys %forkz;

            $abort = "$$ killed with INT";
        }
        else
        {
            $SIG{ INT } = 'DEFAULT';
            kill INT => 0;
        }
    };

    local $SIG{ QUIT }
    = sub
    {
        if( $$ == $parent )
        {
            # blow off the forks and exit immediately.

            kill QUIT => keys %forkz;

            exit -1
        }
        else
        {
            $SIG{ QUIT } = 'DEFAULT';
            kill QUIT => 0;
        }
    };

    # i.e., reap them here.

    local $SIG{ CHLD } = 'DEFAULT';

    $DB::single = 1 if $^P && $debug;

    my %job2attrz   = ();
    my @pending     = ();

    # start with the initially declared namespace.
    # this was installed via prepare -- usually as
    # the empty string (default).

    local $que->{ namespace } = $que->{ _namespace };

    # loop forever until there is nothing either
    # queued or running.

    for( ;; )
    {
        @pending = $mgr->runnable;

        # queue is exhausted if nothing is either
        # running or pending.

        %forkz || @pending
        or last;

        # this is compared often enough to be worth caching.

        my $running = keys %forkz;

        RUNNABLE:
        for my $job_id ( @pending )
        {
            # break up the id into components and check if
            # should be dispatched.

            my ( $nspace, $job ) = $que->job_id_split( $job_id );

            $skipz->{ $job_id } //= 'Skip on SIGHUP'
            if $abort;

            if( exists $skipz->{ $job_id } )
            {
                # don't bother to run jobs in the skip
                # chain: complete will propagate true
                # values to the next level; false values
                # are jobs skipped on restart.

                $mgr->run_message
                (
                    $job_id,
                    skip =>
                    $skipz->{ $job_id } || 'Skip on restart'
                );

                my $exit = $skipz->{ $job_id } ? -1 : 0;

                $mgr->dequeue( $job_id );
                $mgr->complete( $job_id, $exit );

                next RUNNABLE
            }

            # job seems worth running...
            # now check the runing job limits.
            #
            # groups may have different maximum
            # jobs set, need to check the attributes
            # for each pending job.
            #
            # localize $attrz for the current job's
            # namespace. Aside: take time to rename
            # "$attrz" on the next cleanup; something
            # like $job_attrz?

            local $que->{ namespace } = $nspace;

            my $attrz
            = local $que->{ attrib }
            = $job2attrz{ $job_id }
            //= $que->merge_attrib( $job_id )
            ;

            log_message "Attributes: $job", $attrz
            if $detail;

            $verbose    = $attrz->{ verbose };
            $detail     = $verbose > 1;

            my $maxjob  = $attrz->{ maxjob };

            if( $attrz->{ nofork } )
            {
                # nothing more to check: jobs are 
                # running single-stream.
            }
            elsif( $maxjob > $running )
            {
                # the usual case: $maxjob jobs are
                # forked initially and one more is
                # started each time one exits.
            }
            elsif( $maxjob )
            {
                # note that this check may leave all of
                # the pending jobs un-runnable due to
                # local differences in maxjob.

                log_message
                "jobs / slots = $running / $maxjob ($nspace, $job)"
                if $detail;

                next RUNNABLE;
            }
            else
            {
                # unlimited jobs: keep going
            }

            # at this point it looks like the job
            # is going to get run.

            delete $job2attrz{ $job_id };

            local $que->{ job       } = $job;
            local $que->{ job_id    } = $job_id;
            local $que->{ alias     } = $que->alias;

            $DB::single = 1
            if $^P && $debug > 1;

            my ( $name, $sub ) = $mgr->unalias( $job );

            # check both the job and its alias for 
            # ad-hoc attributes.

            my $nofork  = $attrz->{ nofork } || $attrz->{ ad_hoc };

            # dequeue the job here to avoid multiple
            # execution attempts.

            $mgr->dequeue( $job_id );

            if( $nofork )
            {
                # this will have no effect on $running
                # since the job starts and exits here.

                log_message "Nofork: $name ($nspace)"
                if $verbose;

                # dispatch and post-process the job
                # in one place.

                my $exit  = $mgr->runjob( $job_id, $sub );

                $mgr->run_message( $job_id, exit => $exit );

                if( $exit )
                {
                    $skipz->{ $job_id }
                    = "Non-zero exit: $job = '$exit' ($nspace)";
                }

                $mgr->complete( $job_id, $exit );
            }
            else
            {
                # job is going to be forked: sanity
                # check the ttys in debug mode to
                # avoid severe pain later on.

                $^P && $mgr->install_fork_tty;

                $mgr->can( 'prefork' )
                and $mgr->prefork;

                if( ( my $pid = fork ) > 0 )
                {
                    # parent: store the pid and recovery
                    # information and keep going.

                    log_message "Forked: $name ('$nspace', $pid)"
                    if $verbose;

                    $forkz{ $pid }  = $job_id;

                    ++$running;
                }
                elsif( defined $pid )
                {
                    @SIG{ qw( TERM QUIT INT CHLD ) }
                    = ( 'DEFAULT' ) x 4;

                    # call postfork before setting
                    # $0 since postfork may want to
                    # set the value for itself.

                    $0  = "$nspace - $job";

                    $mgr->can( 'postfork' )
                    and $mgr->postfork;

                    ##################################
                    # exit here to avoid phorkatosis #
                    ##################################

                    exit $mgr->runjob( $job_id, $sub )
                }
                else
                {
                    log_fatal "Phorkafobia: $job_id, $!"
                }
            }
        }

        # at this point all runnable jobs have
        # been dispatched -- or are being throttled
        # via maxjobs.
        #
        # now wait job and complete the next job, 
        # which opens up a slot under maxjobs.
        #
        # unknown pids happen when a child process
        # forks and dies before its child (e.g., 
        # forking a gzip to finish writing data).
        # choices are to ignore it here or give up
        # since the outcome cannot be logged.
        #
        # the normal cycle will reap what we fork
        # here, so for the moment these are just
        # logged if verbose it turned on.

        WAIT:
        for( ;; )
        {
            if( ( my $pid = wait ) > 0 )
            {
                my $exit    = $?;

                if( my $job_id  = delete $forkz{ $pid } )
                {
                    log_message "Reaped: $job_id ($pid => $exit)"
                    if $verbose;

                    $mgr->complete( $job_id, $exit );
                }
                else
                {
                    # notice the orphan and keep going until
                    # there is nothing to wait for or we hit
                    # one of the ones we forked.

                    log_error "Orphan process: $pid ($exit)"
                    if $verbose;

                    next WAIT
                }
            }
            elsif( %forkz )
            {
                # someone set $SIG{ CHLD } to 'IGNORE' 
                # or installed their own signal handler.
                # only thing to do is log the fact, reset
                # the forks and keep going.

                log_error
                'Oddity: no procs, non-empty forks:', \%forkz;

                %forkz  = ();
            }
            else
            {
                # nothing more to do: empty forkz and 
                # no child procs.
            }

            # normally only go through here once.

            last
        }
    }

    if( my $nspace = $que->{ _namespace } )
    {
        log_message
        "Non-root namespace: '$nspace' complete",
        "Skipping deadlock checks";
    }
    elsif( $mgr->queued )
    {
        # at this point if nothing is runnable or 
        # running then there should be nothing queued.

        my $blockz  = $que->{ before };
        my $pendz   = $que->{ after };

        log_fatal 
        'Deadlocked queue:',
        'Blocked jobs:',        [ sort keys %$blockz ],
        'Remaining jobs:',      [ sort keys %$pendz  ],
        'Entire Queue:',        $que
    }
    else
    {
        log_message 'Queue completed';
    }

    # flag the que as complete.

    $que->{ executed } = 1;

    return
}

# keep require happy

1

__END__

=head1 NAME

Parallel::Depend : Parallel-dependent dispatch of
perl or shell code.

=head1 SYNOPSIS

    package Mine;

    use base qw( Parallel::Depend Whatever::Else );

    my $manager = Mine->constructify( @whatever );

    my @argz =
    (
        # assign values to attributes

        restart     => '',  # restart in-process queue
        force       => '',  # ignore/overwrite previous execution

        verbose => 1,       # quiet (0), progress (1), detail (2).
        debug   => 0,       # DB::single set before first parse, dispatch

        nofork      => '',  # single-stream, useful for testing.
        maxjobs     => 8,   # 0 => unlimited, x < 0 => nofork.
        fork_ttys   => '',  # used for $DB::fork_TTY with perl debugger

        autoload    => '',  # choose between autoload and shell

        logdir      => "$Bin/../var/log",   # stderr, stdout files
        rundir      => "$Bin/../var/run",   # job status files

        sched   => <<'END'

        this : that     # this runs after that
        that : other    # that runs after other

        # multiple dependencies per line or 1 : 1.

        foo bar : bletch blort
        foo : bim
        foo : bam
        bim bam : this that

        # redundent but harmless if included.

        foo bar : blort bletch

        # without aliases jobs are dispatched as manager
        # object methods, perl function calls, code
        # blocks, AUTOEXEC, or shell depending on where
        # the job can be found.
        # aliases are expanded in the same fashion but
        # are passed the job name as an argument.

        foo = frobnicate                # $manager->frobnicate( 'foo' )

        bar = Some:Package::function    # $coderef->( 'bar' )

        bim = { your code here }        # $anon_sub->( 'bim' )

        bam = /path/to/shell            # system( '/path/to/shell', 'bam' )

        this    = ./blah -a -b          # system( './blah -a -b', 'this' )

        # example of reusing an alias: zip a
        # maxjobs files in parallel.

        /tmp/bakcup/bigdump.aa  = squish
        /tmp/bakcup/bigdump.ab  = squish
        /tmp/bakcup/bigdump.ac  = squish
        /tmp/bakcup/bigdump.ad  = squish
        /tmp/bakcup/bigdump.ae  = squish
        /tmp/bakcup/bigdump.af  = squish

        /tmp/bakcup/bigdump.aa :
        /tmp/bakcup/bigdump.ab :
        /tmp/bakcup/bigdump.ac :
        /tmp/bakcup/bigdump.ad :
        /tmp/bakcup/bigdump.ae :
        /tmp/bakcup/bigdump.af :

        # groups are sub-schedules that have their
        # own namespace for jobs, are skpped entirely
        # on restart if the group completes successfully,
        # and can set their own attributes.

        pass2 < maxjob % 4          >   # throttle heavy-duty jobs.
        pass2 < fee fie foe fum :   >   # all these can run in
        pass2 < this that other :   >   # parallel, no harm splitting them up
        pass2 < this  = squish      >   # locally defined aliases: these are
        pass2 < that  = squash      >   # *not* the same as the jobs above.
        pass2 < other = frobnicate  >

        # attributes can be set, apply to all nested
        # levels. helpful within groups.
        #
        # for example, extract the contents of some
        # files, process them, then cleanup the 
        # results. each group uses its own alias
        # to handle the files.

        maxjob % 0              # unlimited forks

        after  < maxjob % 2 >   # two-way only for after group

        prior  < alias % extract >  # default alias within the group
        after  < alias % cleanup >
        during < alias % process >

        prior  < file1 : >  # $mgr->extract( 'file1' )
        prior  < file2 : >  # $mgr->extract( 'file2' )

        during < file1 : >  # $mgr->process( 'file1' )
        during < file2 : >  # $mgr->process( 'file2' )

        after  < file1 : >  # $mgr->cleanup( 'file1' )
        after  < file2 : >  # $mgr->cleanup( 'file2' )

        # assign job-specific attributes -- mainly to control
        # verbosity or flag jobs as installing ad-hoc schedules.

        this ~ ad_hoc       # default for all attributes is 1
        this ~ verbose 0    # or add your own value
        that ~ verbose 2

        # as you might have guessed by now, text after
        # an un-escaped hash sign is treated as a comment.
END
    );

    my $outcome
    = eval
    {
        $manager->prepare ( @argz );    # parase, validate the queue.
        $manager->validate;             # check for deadlocks
        $manager->execute;              # do the deed

        "The End"
        
    }
    or die $@;

    or just:

    $manager->prepare( @argz )->validate->execute;

    # if you want to derive a new object from a
    # new one and use it to execute the que or add
    # ad_hoc jobs (e.g., factory class) then you
    # must share the queue for the new object.

    sub derive_new_object
    {
        my $mgr     = shift;

        my $derived = $mgr->new( @_ );

        $mgr->share_queue( $derived );

        $derived
    }

    # at this point the derived object uses 
    # the same queue as the original $manager
    # (not a clone, the same one). executing
    # with $derived will have the same effect
    # on the queue as $manager.

    $derived->execute;

=head1 DESCRIPTION

Parallel::Depend does parallel, dependent dispatch of
perl methods, perl functions, inline code blocks, or
external shell commands. The schedule syntax is derived
from Make but does not require that all jobs be wrapped
in shell code to execute and also supports sub-schedules
("groups" ) that are dispatched as a unit.

Execution history, including stdout and stderr of each
job, is kept in per-job files for simpler access after
the fact.

=head2 Schedule Syntax

The schedule can contain dependencies, aliases, attribute
assignments, group definitions, and perl-style comments.

=head3 Dependecies ":"

Dependencies between jobs use a ':' syntax much like make:

	# commenting the schedule is often helpful.

    foo : bar
    foo : bletch
    bim : foo
    bam : foo

or

    # produces the same result as above:

    foo : bar bletch

    bim bam : foo

Job names are non-whitespace ( /\S/ if you like regexen)
and are separated by whitespace. If you need whitespace
arguments in order to dispatch the job then see "aliases"
below.

=head3 Job Aliases "="

Jobs are normally dispatched as-is as either method
names, perl functions, perl code blocks, or to the
shell via system( $job ).

Processing a number of inputs through the same
cycle, passing arguments to the methods, or
including shell commands with multiple arguments
requries aliasing the job name:

	job1 = make -wk -c /foo bar bletch;
	job2 = Some::Module::mysub
	job3 = methodname
	job4 = { print "this is a perl code block"; 0 }

	job3 : job2 job1

Will eventually call Some::Module::mysub( 'job2' ) and
$mgr->methodname( 'job3' ); job1 will be handled as
system( 'make ...' ). job4 will not be executed since
there is no dependency rule for it.

Passing a number of arguments to the same routine
is done by aliasing them the same way.

Say you want to gzip a large number files, running
the zips n-way parallel:

    my $sched
    = q
    {
        /path/to/file1  = gzip
        /path/to/file2  = gzip
        /path/to/file3  = gzip

        /path/to/file1  :
        /path/to/file2  :
        /path/to/file3  :
    };

    My::Class->prepare
    (
        sched   => $sched,
        maxjob  => 4
    )
    ->execute;

=head4 Types of aliases

=over 4

=item Method Alias

if $mgr->can( $alias ) then the alias will be
dispatched as

    $mgr->$alias( $job );

For example

    /path/to/file = squish
    /path/to/file :

will dispatch:

    $mgr->squish( '/path/to/file' );

=item Shell Alias

    /path/to/file   = /bin/gzip -9v

Will call 

    system '/bin/gzip -9v', '/path/to/file'

(splitting the command line on un-escaped whitespace
is hell, the shell can do it well enough for itself).

=item Perl Function Alias

If you don't want to pass the queue manager object (i.e.,
functonal interface) just include the package with '::':

    /path/to/file1  = My::Class::Util::gzip

will end up calling

    $coderef->( '/path/to/file1' );

=item Code Block Alias

For complete -- if somewhat dangerous -- control
use a codeblock. This will be compiled on the fly
into a subroutine and run with job as its argument.

Using 

    foo     = { a block of perly code }
   
Will eval "sub $alias" to get a subref and 
dispatch $subref->( 'foo' ). This is one way
to dodge passing around the manager object if
necessary.

=item AUTOLOAD

If the 'autoload' attribute is set, the manager
can 'AUTOLOAD', and the alias looks like a method
call then unalias will trust to luck and compile

    sub { $mgr->$alias( $job ) }

For you. This can be helpful for allowing nested
class structures to derive their own objects to 
handle specific parts of processing: just pass 
class name as the job, alias it to the method
being dispatched, and have your AUTOLOAD take the
argument as the class to dispatch into. This case
is where sharing the queue also comes in handy.

It is also useful with modules that depend on 
autoload side effects to function.

=back

=head3 Groups (sub-schedules) "< ... >"

Groups are schedules within the schedule:

	group : job1

	group < job2 job3 job4 : job5 job6 >
	group < job3 : job5 >

Groups provide a separate namespace for their jobs, 
attributes, and aliases and are skipped wholesale
on restart.

The most common use of groups is to process a set
of data through multiple stages. This can be done 
easily by putting each stage in a group, assigning
a hardwired alias within the group, and adding the
data. For example:

    my @fixed =
    (
        'maxjob % 4',
        'prior  < alias % /path/to/gzip -dv >',
        'during < alias % process >',
        'after  < alias % /path/to/gzip -9v >',

        'during : prior',
        'after  : during',
    );

    my @variable
    = map
    {
        (
            "prior  < $_ : >",
            "during < $_ : >",
            "after  < $_ : >",
        )
    }
    glob '/tmp/incoming/*';

    $mgr->prepare( @fixed, indir @variable );
    $mgr->execute;

Will run all of the jobs 4-way parallel through gzip -d, 
the process method, and gzip -9.

On a restart if the "prior" group completed then 
it will be stubbed on restart and none of its 
contents run. This helps avoid expensive side-
effects in preparing the jobs.

=head3 Rolling Your Own

The unalias method returns an id string ($name) for
tracking the job and a closure to execute for
running it:

	my ( $name, $sub )  = $mgr->unalias( 'job1' );

	my $return = $mgr->runjob( $sub );

The default runjob simply dispatchs $sub->() but it
might be overloaded to wrap, eval, or otherwise manage
the execution. Overloading unalias gives you complete
control over how the jobs are processed. This can be
helpful for cases where the method + argument is not
sufficient.

=head3 Setting Schedule Attributes

Settings are used to override defaults in the schedule
preparation. Defaults are taken from hard-coded defaults
in S::D, parameters passed into prepare as arguments, or
the parent que's attributes for sub-queues or groups.
Settings use '%' to spearate the attribute and its value
(mainly because '=' was already used for aliases):

	verbose % 1
	maxjob  % 1

The main use of these in top-level schedules is as an
alternative to argument passing. In sub-queues they are
the only way to override the que attributes. One good
example of these is setting maxjob to 2-3 in order to
allow multiple groups to start in the main schedule and
then to 1 in the groups to avoid flooding the system.

Groups inherit the attributes of their enclosing group;
everyone inherits from the the global settings.

For example:

    maxjob % 4

    expensive < maxjob % 2 >
    cheap     < maxjob % 8 >

Leaves most things runnin 4-way parallel, with jobs in
the "expensive" group throttled, ones in "cheap" run
8-ways.

Sometimes attributes need to be set for one job. This
is usually to up verbosity to check a failure or to
flag the job as installing an ad-hoc schedule:

    alias % frobnicate

    /input/path = check_filesystem

    /input/path ~ ad_hoc

    /input/path : extract
    cleanup : /input/path

Will run "find_files" without forking so that it can 
call $mgr->ad_hoc( ... ) to install a scheudle on the
fly. Both "extract" and "cleanup" will be passed to
"frobnicate", where the input path will be passed to 
"check_filesystem". 

The "check_filesystem" call will be made without forking.
This allows the method to install jobs for files it finds.
This also creates a group "check_filesystem._" to contain
the results of the ad-hoc schedule (see ad_hoc method).

=head3 Ad-Hoc schedules

There are times when you want a job to run in order to
determine what happens next. Examples are searching the
filesystem for inputs or processing the chunked output
a previous stage. In both caess it is easier to have a
job add to the running schedule.

The "ad_hoc" call adds jobs into the current schedule.
For this to work the current job cannot be forked. This
means that either the entire queue runs with "nofork"
set or that the job is flagged as "ad_hoc". The difference
is that ad_hoc is a flag for only one job:

    /input/dir ~ ad_hoc

    /input/dir = find_files

    /input/dir : download
    load_data  : /input/dir

This will fork download, wait until it completes, then
dispatch find_files without forking. When the sub-schedule
installed by find_files completes then load_data will be
called.

The ad_hoc call installs a new group 'job._', which can
contain its own attributes, aliases, or groups:

    sub find_files
    {
        my ( $mgr, $path ) = @_;    # $path is '/input/dir'

        my @jobz
        = map
        {
            my $base    = basename $_;
            my ( $grp ) = $base =~ m{ [.] (\w+) [.]gz };
            o
        }
        or die "Invalid input: '$path' has no files";
    }

=head1 Arguments

=over 4

=item sched

The schedule can be passed as a single argument (string or
reference) or with the "depend" key as a hash value:

	sched => [ schedule as seprate lines in an array ]

	sched => "newline delimited schedule, one item per line";

Or can be passed a hash of configuration information with
the required key "sched" having a value of the schedule
scalar described above.


The dependencies are described much like a Makefile, with targets
waiting for other jobs to complete on the left and the dependencies
on the right. Schedule lines can have single dependencies like:

	waits_for : depends_on

or multiple dependencies:

	wait1 wait2 : dep1 dep2 dep3

or no dependencies:

	runs_immediately :

Jobs on the righthand side of the dependency ("depends_on"
or "dep1 dep2 dep3", above) will automatically be added to
the list of runnable jobs. This avoids having to add speical
rules for them.

Dependencies without a wait_for argument are an error (e.g.,
": foo" will croak during prepare).

It is also possible to alias job strings:

	foo = /usr/bin/find -type f -name 'core' | xargs rm -f

	...

	foo : bar

	...

will wait until bar has finished, unalias foo to the
command string and pass the expanded version wholesale
to the system command. Aliases can include fully qualified
perl subroutines (e.g., " Foo::Bar::subname") or methods
accessable via the $que object (e.g., "subname"), code
blocks (e.g., "{returns_nonzero; 0}". If no subroutine,
method or perl block can be extracted from the alias then
it is passed to the shell for execution via the shellexec
method.

If the schedule entry requires newlines (e.g., for
better display of long dependency lists) newlines
can be embedded in it if the schedule is passed into
prepare as an array reference:

	my $sched =
	[
		"foo =	bar
				bletch
				blort
		",
	];

	...

	Parallel::Depend->prepare( sched => $sched ... );
	Parallel::Depend->prepare( sched => $sched ... );

will handle the extra whitespace properly. Multi-line
dependencies, aliases or groups are not allowed if the
schedule is passed in as a string.


One special alias is "group". This is a standard method
used to handle grouped jobs as a sub-que. Groups are
assigned using the '~' character and by having the
group name aliased to group. This guarantees that the jobs
do not start until the group is ready and that anything
the group depends on will not be run until all of the
group jobs have completd.

For example:

	# main schedule has unlimited number of concurrent jobs.

	maxjob % 0

	name ~ job1 job2 job3

	gname : startup

	# optional, default for handling groups is to alias
	# them to the $mgr->group method.

	gname = group

	gname : startup

	# the group runs single-file, with maxjob set to 1

	gname < maxjob % 1 >
	gname < job1 job2 job3 >

	shutdown : gname


Will run job[123] together after "startup" completes and
will cause "shutdwon" to wait until all of them have
finished.


See the "Schedules" section for more details.

=item verbose

Turns on verbose execution for preparation and execution.

All output controlled by verbosity is output to STDOUT;
errors, roadkill, etc, are written to STDERR.

verbose == 0 only displays a few fixed preparation and
execution messages. This is mainly intended for production
system with large numbers of jobs where searching a large
output would be troublesome.

verbose == 1 displays the input schedule contents during
preparation and fork/reap messages as jobs are started.

verbose == 2 is intended for monitoring automatically
generated queues and debugging new schedules. It displays
the input lines as they are processed, forks/reaps,
exit status and results of unalias calls before the jobs
are exec-ed.

verbose can also be specified in the schedule, with
schedule settings overriding the args. If no verbose
setting is made then debug runs w/ verobse == 1,
non-debug execution with  verbose == 0.

Also "verbose % X" in the schedule, with X as the new
verbosity.

=item validate

Runs the full prepare but does not fork any jobs, pidfiles
get a "Debugging $job" entry in them and an exit of 1. This
can be used to test the schedule or debug side-effects of
overloaded methods. See also: verbose, above.

=item rundir & logdir

These are where the pidfiles and stdout/stderr of forked
jobs are placed, along with stdout (i.e., verbose) messages
from the que object itself.

These can be supplied via the schedule using aliases
"rundir" and "logdir". Lacking any input from the schedule
or arguments all output goes into the #! file's directory
(see FindBin(1)).

Note: The last option is handy for running code via soft link
w/o having to provide the arguments each time. The RBTMU.pm
module in examples can be used in a single #! file, soft linked
in to any number of directories with various .tmu files and
then run to load the varoius groups of files.

=item maxjob

This is the maximum number of concurrnet processs that
will be run at any one time during the que. If more jobs
are runnable than process slots then jobs will be started
in lexical order by their name until no slots are left.

=item restart, noabort

These control the execution by skipping jobs that have
completed or depend on those that have failed.

The restart option scans pidfiles for jobs which have
a zero exit in them, these are marked for skipping on
the next pass. It also ignores zero-sized pidfiles to
allow for restarts without having to remove the initail
pidfiles created automatically in prepare.

The noabort option causes execution to behave much like
"make -k": instead of aborting completely on a non-zero
exit the execution will complete any jobs that do not
depend on the failed job.

Combining noabort with restart can help debug new
schedules or handle balky ones that require multiple
restarts.

These can be given any true value; the default for
both is false.

Also: "maxjob % X" in the schedule with X as the
maximum number of concurrent jobs.

=item Note on schedule arguments and aliases

verbose, debug, rundir, logdir, and maxjob can all be
supplied via arguments or within the scheule as aliases
(e.g., "maxjob = 2" as a scheule entry). Entries hard-
coded into the schedule override those supplied via the
arguments. This was done mainly so that maxjob could be
used in test schedules without risk of accidentally bringing
a system to its knees during testing. Setting debug in this
way can help during testing; setting verbose to 0 on
automatically generated queues with thousands of entries
can also be a big help.

Hard-coding "restart" would require either a new
directory for each new execution of the schedule or
explicit cleanup of the pidfiles (either by hand or
a final job in the schedule).

Hard-codding "noabort" is probably harmless.

Hard-coding "debug" will effectively disable any real
execution of the que.


=head2 Note for debugging

$que->{attrib} contains the current que settings. Its
contents should probably not be modified but displaying
it (e.g., via Dumper $que->{attrib})" can be helpful in
debgging que behavior.

=back

=head1 Description

Parallel scheduler with simplified make syntax for job
dependencies and substitutions.  Like make, targets have
dependencies that must be completed before the can be run.
Unlike make there are no statements for the targets, the targets
are themselves executables.

The use of pidfiles with status information allows running
the queue in "restart" mode. This skips any jobs with zero
exit status in their pidfiles, stops and re-runs or waits for
any running jobs and launches anything that wasn't started.
This should allow a schedule to be re-run with a minimum of
overhead.

The pidfile serves three purposes:

=over 4

=item Restarts

 	On restart any leftover pidfiles with
	a zero exit status in them can be skipped.

=item Waiting

 	Any process used to monitor the result of
	a job can simply perform a blocking I/O to
	for the exit status to know when the job
	has completed. This avoids the monitoring
	system having to poll the status.

=item Tracking

 	Tracking the empty pidfiles gives a list of
	the pending jobs. This is mainly useful with
	large queues where running in verbose mode
	would generate execesive output.

=back

Each job is executed via fork/exec (or sub call, see notes
for unalias and runjob). The parent writes out a
pidfile with initially two lines: pid and command line. It
then closes the pidfile. The child keeps the file open and
writes its exit status to the file if the job completes;
the parent writes the returned status to the file also. This
makes it rather hard to "loose" the completion and force an
abort on restart.

=head2 Schedules

The configuration syntax is make-like. The two sections
give aliases and the schedule itself. Aliases and targets
look like make rules:

	target = expands_to

	target : dependency

example:

	a = /somedir/abjob.ksh
	b = /somedir/another.ksh
	c = /somedir/loader

	a : /somedir/startup.ksh
	b : /somedir/startup.ksh

	c : a b

	/somedir/validate : a b c


Will use the various path expansions for "a", "b" and "c"
in the targets and rules, running /somedir/abjob.ksh only
after /somedir/startup.ksh has exited zero, the same for
/somedir/another.ksh. The file /somedir/loader
gets run only after both abjob.ksh and another.ksh are
done with and the validate program gets run only after all
of the other three are done with.

A job can be assigned a single alias, which must be on a
single line of the input schedule (or a single row in
schedleds passed in as arrays). The alias is expanded at
runtime to determine what gets dispatched for the job.

The main uses of aliases would be to simplify re-use of
scripts. One example is the case where the same code gets
run multiple times with different arguments:

	# comments are introduced by '#', as usual.
	# blank lines are also ignored.

	a = /somedir/process 1	# process is called with various arg's
	b = /somedir/process 2
	c = /somedir/process 3
	d = /somedir/process 4
	e = /somedir/process 5
	f = /somedir/process 6

	a : /otherdir/startup	# startup.ksh isn't aliased
	b : /otherdir/startup
	c : /otherdir/startup

	d : a b
	e : b c
	f : d e

	cleanup : a b c d e f

Would allow any variety of arguments to be run for the
a-f code simply by changing the aliases, the dependencies
remain the same.

If the alias for a job is a perl subroutine call then the
job tag is passed to it as the single argument. This
simplifies the re-use above to:

	file1.gz = loadfile
	file1.gz = loadfile
	file1.gz = loadfile

	file1.gz file2.gz file3.gz : /some/dir/download_files


Will call $mgr->loadfile passing it "file1.gz" and so
on for each of the files listed -- afte the download_files
script exits cleanly.


Another example is a case of loading fact tables after the
dimensions complete:

	fact1	= loadfile
	fact2	= loadfile
	fact3	= loadfile
	dim1	= loadfile
	dim2	= loadfile
	dim3	= loadfile

	fact1 fact2 fact3 : dim1 dim2 dim3

Would load all of the dimensions at once and the facts
afterward. Note that stub entries are not required
for the dimensions, they are added as runnable jobs
when the rule is read. The rules above could also have
been stated as:

	fact1 fact2 fact3 dim1 dim2 dim3 : loadfile

	fact1 fact2 fact3 : dim1 dim2 dim3

The difference is entirely one if artistic taste for
a scalar schedule. If the schedule is passed in as
an array reference then it will usually be easier to
push dependnecies on one-by-one rather than building
them as longer lines.


Single-line code blocks can also be used as aliases.
One use of these is to wrap legacy code that returns
non-zero on success:

	a = { ! returns1; }

or

	a = { eval{returns1}; $@ ? 1 : 0 }

to reverse the return value or pass non-zero if the
job died. The blocks can also be used for simple
dispatch logic:

	a = { $::switchvar ? subone("a") : subtwo("a") }

allows the global $::switchvar to decide if subone
or subtwo is passed the argument. Note that the global
is required since the dispatch will be made within
the Parallel::Depend package.
the Parallel::Depend package.

Altering the package for subroutines that depend on
package lexicals can also be handled using a block:

	a = { package MyPackage; somesub }

Another alias is "PHONY", which is used for placeholder
jobs. These are unaliased to sub{0} and are indended
to simplify grouping of jobs in the schedule:

	waitfor = PHONY

	waitfor : job1
	waitfor : job2
	waitfor : job3
	waitfor : job4

	job5 job6 job7 : waitfor

will generate a stub that immediately returns zero for
the "waitfor" job. This allows the remaining jobs to be
hard coded -- or the job1-4 strings to be long file
paths -- without having to generate huge lines or dynamicaly
build the job5-7 line.

One example of phony jobs simplifying schedule generation
is loading of arbitrary files. A final step bringing the
database online for users could be coded as:

	online : loads

with lines for the loads added one by one as the files
are found:

	push @schedule, "loads : $path", "path = loadfile";

could call a subroutine "loadfile" for each of the paths
without the "online" operation needing to be udpated for
each path found.

The other standard alias is "STUB". This simply prints
out the job name and is intended for development where
tracking schedule execution is useful. Jobs aliased to
"STUB" return a closure "sub{print $job; 0}" and an id
string of the job tag.


In many cases PHONY jobs work but become overly verbose.
The usual cause is that a large number of jobs are tied
together at both the beginning and ending stages, causing
double-entries for each one, for example:

	job1 : startup
	job2 : startup
	job3 : startup
	...
	jobN : startup

	shutdown : job1
	shutdwon : job2
	shutdwon : job3
	shutdown : jobN

Even if the jobs are listed on a single line each, double
listing is a frequent source of errors. Groups are designed
to avoid most of this diffuculty. Jobs in a group have an
implicit starting and ending since they are only run within
the group. For example if the jobs above were in a group;

	middle = group			# alias is optional

	middle < job1 : job2 >
	middle < job3 : job2 >

	middle : startup
	shutdown : middle

This will wait until the "middle" job becomes runnble
(i.e., when startup has finished) and will prepare the
schedule contained in the angle-brackets. The entire
schedule is prepared and executed after the middle job
has forked and uses a local copy of the queued jobs
and dependencies. This allows the "middle" group to
contain a complete schedule -- complete with sub-sub-
schedules if necessary.

The normal method for handling group names is the "group"
method. If the group name has not already been aliased
when the group is parsed then it will be aliased to "group".
This allows another method to handle dispatching the jobs
if necessary (e.g., one that uses a separate run or log
directory).

It is important to note that the schedule defined by
a group is run seprately from the main schedule in a
forked process. This localizes any changes to the que
object and effects on jobs skipped, etc. It also means
that the group's schedule should not have any dependencies
outside of the group or it will deadlock (and so may the
main schedule).

Note: Group names should be simple tags, and must avoid
'=' and ':' characers in the job name in order to be
parsed properly.


=head2 Overloading unalias for special job expansion.

Up to this point all of the schedule processing has been
handled automatically. There may be cases where specialized
processing of the jobs may be simpler. One example is where
the "jobs" are known to be data files being loaded into a
database, another is there the subroutine calls must come
from an object other than the que itself.

In this case the unalias or runjob methods can be overloaded.
Because runjob will automatically handle calling subroutines
within perl vs. passing strings to the shell, most of the
overloading can be done in unalias.

If unalias returns a code reference then it will be used to
execute the code. One way to handle file processing for,
say, rb_tmu loading dimension files before facts would be
a schedule like:

	dim1 = tmu_loader
	dim2 = tmu_loader
	dim3 = tmu_loader
	fact1 = tmu_loader
	fact2 = tmu_loader

	fact2 fact1 : dim1 dim2 dim3

This would call $mgr->tmu_loader( 'dim1' ), etc, allowing
the jobs to be paths to files that need to be loaded.

The problem with this approach is that the file names can
change for each run, requiring more complicated code.

In this case it may be easier to overload the unalias
method to process file names for itself. This might
lead to the schedule:

	fact2 fact1 : dim1 dim2 dim3

and nothing more with

		-e $tmufile or croak "$$: Missing: $tmufile";

		# unzip zipped files, otherwise just redrect them

		my $cmd = $datapath =~ /.gz$/ ?
			"gzip -dc $datapath | rb_ptmu $tmufile \$RB_USER" :
			"rb_tmu $tmufile \$RB_USER < $datapath"
		;

		# caller gets back an id string of the file
		# (could be the command but that can get a bit
		# long) and the closure that deals with the
		# string itself.

		( $datapath, sub { shellexec $cmd } };
	}


In this case all the schedule needs to contain are
paths to the data files being loaded. The unalias
method deals with all of the rest at runtime.

Aside: This can be easily implemented by way of a simple
convention and one soft link. The tmu (or sqlldr) config.
files for each group of files can be placed in a single
directory, along with a soft link to the #! code that
performs the load. The shell code can then use '.' for
locating new data files and "dirname $0" to locate the
loader configuations. Given any reasonable naming convention
for the data and loader files this allows a single executable
to handle mutiple data groups -- even multiple loaders --
realtively simply.




Since code references are processed within perl this
will not be passed to the shell. It will be run in the
forked process, with the return value of tmuload_method
being passed back to the parent process.

Using an if-ladder various subroutines can be chosen
from when the job is unaliased (in the parent) or in
the subroutine called (in the child).

=head2 Aliases can pass shell variables.

Since the executed code is fork-execed it can contain any
useful environment variables also:

	a = process --seq 1 --foo=$BAR

will interpolate $BAR at fork-time in the child process (i.e..
by the shell handling the exec portion).

The scheduling module exports modules for managing the
preparation, validation and execution of schedule objects.
Since these are separated they can be manipulated by the
caller as necessary.

One example would be to read in a set of schedules, run
the first one to completion, modify the second one based
on the output of the first. This might happen when jobs are
used to load data that is not always present.  The first
schedule would run the data extract/import/tally graphs.
Code could then check if the tally shows any work for the
intermittant data and stub out the processing of it by
aliasing the job to "/bin/true":

	/somedir/somejob.ksh = /bin/true

	prepare = /somedir/extract.ksh

	load = /somedir/batchload.ksh


	/somedir/somejob.ksh : prepare
	/somedir/ajob.ksh : prepare
	/somedir/bjob.ksh : prepare

	load : /somedir/somejob.ksh /somedir/ajob.ksh /somedir/bjob.ksh


In this case /somedir/somejob.ksh will be stubbed to exit
zero immediately. This will not interfere with any of the
scheduling patterns, just reduce any dealays in the schedule.

=head2 Note on calling convention for closures from unalias.


	$sub = unalias $job;

The former is printed for error and log messages, the latter
is executed via &$sub in the child process.

The default closures vary somewhat in the arguments they
are passed for handling the job and how they are called:

	$run = sub { $sub->( $job ) };				$package->can( $subname )

	$run = sub { $que->$sub( $job ) };			$mgr->can( $run )

	$run = sub { __PACKAGE__->$sub( $job ) };	__PACKAGE__->can( $run )

	$run = eval "sub $block";					allows perl block code.

The first case comes up because Foo::bar in a schedule
is unlikey to successfully process any package arguments.
The __PACKAGE__ situation is only going to show up in
cases where execute has been overloaded, and the
subroutines may need to know which package context
they were unaliased.

The first case can be configured to pass the package
in by changing it to:

	$run = sub { $packge->$sub( $job ) };

This will pass the package as $_[0].

The first test is necessary because:

	$object->can( 'Foo::bar' )

alwyas returns \&Foo::bar, which called as $que->$sub
puts a stringified version of the object into $_[0],
and getting something like "2/8" is unlikely to be
useful as an argument.

The last is mainly designed to handle subroutines that
have multiple arguments which need to be computed at
runtime:

	foo = { do_this( $dir, $blah); do_that }

or when scheduling legacy code that might not exit
zero on its own:

	foo = { some_old_sub(@argz); 0 }

The exit from the block will be used for the non-zero
exit status test in the parent when the job is run.


=head1 Notes on methods

Summary by subroutine call, with notes on overloading and
general use.

=head 

=head2 ready

Return a list of what is runnable in the queue. these
will be any queued jobs which have no keys in their
queued subhash. e.g., the schedule entry

	"foo : bar"

leaves

	$queued->{foo}{bar} = 1.

foo will not be ready to excute until keys
%{$queued->{foo}} is false (i.e., $queued->{foo}{bar}
is deleted in the completed module).

This is used in two places: as a sanity check of
the schedule after the input is complete and in
the main scheduling loop.

If this is not true when we are done reading the
configuration then the schedule is bogus.

Overloading this might allow some extra control over
priority where maxjob is set by modifying the sort
to include a priority (e.g., number of waiting jobs).

=head2 queued, depend

queued hands back the keys of the que's "queued" hash.
This is the list of jobs which are waiting to run. The
keys are sorted lexically togive a consistent return
value.

depend hands back the keys of que's "depend" hash for a
particular job. This is a list of the jobs that depend
on the job.

Only reason to overload these would be in a multi-stage
system where one queue depends on another. It may be useful
to prune the second queue if something abnormal happens
in the first (sort of like make -k continuing to compile).

Trick would be for the caller to use something like:

	$q1->dequeue( $_ ) for $q0->depend( $job_that_failed );

	croak "Nothing left to run" unless $q1;

note that the sort allows for priority among tags when
the number of jobs is limited via maxjob. Jobs can be
given tags like "00_", "01_" or "aa_", with hotter jobs
getting lexically lower tag values.

=head2 dequeue

Once a job has been started it needs to be removed from the
queue immediately. This is necessary because the queue may
be checked any number of times while the job is still running.

For the golf-inclined this reduces to

	delete $_[0]->{queued}{$_[1]}

for now this looks prettier.

Compare this to the complete method which is run after the
job completes and deals with pidfile and cleanup issues.

=head2 complete

Deal with job completion. Internal tasks are to update
the dependencies, external cleanups (e.g., zipping files)
can be handled by adding a "cleanup" method to the queue.

Thing here is to find all the jobs that depend on whatever
just got done and remove their dependency on this job.

$depend->{$job} was built in the constructor via:

		push @{ $depend->{$_} }, $job for @dependz;

Which assembles an array of what depeneds on this job.
Here we just delete from the queued entries anything
that depends on this job. After this is done the runnable
jobs will have no dependencies (i.e., keys %{$q{queued}{$job}
will be an empty list).

A "cleanup" can be added for post-processing (e.g., gzip-ing
processed data files or unlinking scratch files). It will
be called with the que and job string being cleaned up after.

=head2 unalias, runjob

unalias is passed a single argument of a job tag and
returns two items: a string used to identify the job
and a closure that executes it. The string is used for
all log and error messages; the closure executed via
"&$sub" in the child process.

The default runjob accepts a scalar to be executed and
dispatches it via "&$run". This is broken out as a
separate method purely for overloading (e.g., for even
later binding due to mod's in unalias).

For the most part, closures should be capable of
encapsulating any logic necessary so that changes to
this subroutine will not be necessary.


=head2 precheck

Isolate the steps of managing the pidfiles and
checking for a running job.

This varies enough between operating systems that
it'll make for less hacking if this is in one
place or can be overridden.

This returns true if the pidfile contains the pid
for a running job. depending on the operating
system this can also check if the pid is a copy
of this job running.

If the pid's have simply wrapped then someone will
have to clean this up by hand. Problem is that on
Solaris (at least through 2.7) there isn't any good
way to check the command line in /proc.

On HP it's worse, since there isn't any /proc/pid.
there we need to use a process module or parse ps.

On solaris the /proc directory helps:

	croak "$$: job $job is already running: /proc/$dir"
		if( -e "/proc/$pid" );}

but all we can really check is that the pid is running,
not that it is our job.

On linux we can also check the command line to be sure
the pid hasn't wrapped and been re-used (not all that
far fetched on a system with 30K blast searches a day
for example).

Catch: If we zero the pidfile here then $q->validate->execute
fails because the file is open for append during the
execution and we get two sets of pid entries. The empty
pidfiles are useful however, and are a good check for
writability.

Fix: deal with it via if block in execute.

=head2 prepare

Read the schedule and generate a queue from it.

Lines arrive as:

	job = alias expansion of job

or

	job : depend on other jobs

any '#' and all text after it on a line are stripped, regardless
of quotes or backslashes and blank lines are ignored.

Basic sanity checks are that none of the jobs is currently running,
no job depends on istelf to start and there is at least one job
which is inidially runnable (i.e., has no dependencies).

Caller gets back a blessed object w/ sufficient info to actually
run the scheduled jobs.

The only reason for overloading this would be to add some boilerplate
to the parser. The one here is sufficient for the default grammar,
with only aliases and dependencies of single-word tags.

Note: the "ref $proto || $proto" trick allows this to be used as
a method in some derived class. in that case the caller will get
back an object blessed into the same class as the calling
object. This simplifies daisy-chaining the construction and saves
the deriving class from having to duplicate all of this code in
most cases.

=head2 Alternate uses for S::D::unalias

This can be used as the basis for a general-purpose dispatcher.
For example, Schedule::Cron passes the command line directly
to the scheduler. Something like:

	package Foo;

	use Schedule::Cron;
	use Parallel::Depend;
	use Parallel::Depend;

	sub dispatcher
	{
		my $cmd = shift;

		if( my ( $name, $sub ) = Parallel::Depend->unalias($cmd) )
		if( my ( $name, $sub ) = Parallel::Depend->unalias($cmd) )
		{
			print "$$: Dispatching $name";

			&$sub;
		}
	}

permits cron lines to include shell paths, perl subs or
blocks:

	* * * * *	Some::Module::subname
	* * * * *	{ this block gets run  also }
	* * * * *	methodname

This works in part because unalias does a check for its
first argument being a refernce or not before attempting
to unalias it. If a blessed item has an "unalias" hash
within it then that will be used to unalias the job strings:

	use base qw( Parallel::Depend );
	use base qw( Parallel::Depend );

	my $blessificant = bless { alias => { foo => 'bar' } }, __PACKAGE__;

	my ( $string, $sub ) = $blessificant->unalias( $job );

will return a subroutine that uses the aliased strings
to find method names, etc.


=head2 debug

Stub out the execution, used to check if the queue
will complete. Basic trick is to make a copy of the
object and then run the que with "norun" set.

This uses Dumper to get a deep copy of the object so that
the original queue isn't consumed by the debug process,
which saves having to prepare the schedule twice to debug
then execute it.

two simplest uses are:

	if( my $que = S::D->prepare( @blah )->validate ) {...}

or

	eval { S::D->prepare( @blah )->debug->execute }

depending on your taste in error handling.

=head2 execute

Actually do the deed. There is no reason to overload
this that I can think of.


=head2 group

This is passed a group name via aliasing the group in
a schedle, for example:

    dims    = group # alias added automatically
    facts   = group # alias added automatically

    dims    < dim1 dim2 dim3 : >
    facts   < fact1 fact2 : >

    facts : dims

will call $mgr->group( 'dims' ) first then
$mgr->group( 'facts' ).

=head1 Known Bugs/Features

The block-eval of code can yield all sorts of oddities
if the block has side effects (e.g., exit()). The one-
line format also imposes some strict limits on blocks
for now unless the schedule is passed in as an arrayref.

Dependencies between jobs in separate groups is
not yet supported due to validation issues. The
call to prepare will mangle dependencies between
jobs to keep the groups in order but you cannot
have a job in one group depened explicitly in any
job in another group -- this includes nested groups.

=head1 Author

Steven Lembark, Workhorse Computing
lembark@wrkhors.com

=head1 Copyright

(C) 2001-2009 Steven Lembark, Workhorse Computing

This code is released under the same terms as Perl istelf. Please
see the Perl-5.10 distribution (or later) for a full description.

In any case, this code is release as-is, with no implied warranty
of fitness for a particular purpose or warranty of merchantability.

=head1 See Also

perl(1)

perlobj(1) perlfork(1) perlreftut(1)

Other scheduling modules:

Parallel::Queue(1) Schedule::Cron(1)
