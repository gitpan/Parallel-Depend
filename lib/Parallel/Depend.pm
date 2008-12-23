########################################################################
# housekeeping
########################################################################

package Parallel::Depend;

our $VERSION = 2.00;

use strict;
use feature qw( :5.10 );
use autodie qw( open close seek write );

# prettify messages during compile.

local $\ = "\n";
local $, = "\n\t";
local $| = 1;

# values for $que->{ skip }{ $job }:
#
#   CLEAN is is used in restart mode to flag jobs that have
#   completed cleanly and don't need to be rerun.
#
#   ABORT flags jobs with a failed dependency that are being
#   skipped because they cannot be run. their waitfor entries
#   will be flagged with ABORT also.

use constant CLEAN  =>  1;
use constant ABORT  => -1;

use Carp;
use Data::Dumper;
use File::Basename;

use Scalar::Util    qw( blessed looks_like_number refaddr reftype );
use Storable        qw( dclone );
use Symbol          qw( qualify_to_ref      );


use Parallel::Depend::Util;

########################################################################
# package variables
########################################################################

# elements of a parent que that are copied into the subque.
# the attributes are managed by S::D, the user section is
# for whatever payload data users want to insert.

my @inherit = qw( attrib user alias );

# default attribute values.

my %defaultz =
(
    # i.e., don't choke the number of parallel jobs.
    # change this to 1 for serial behavior.

    maxjob  => 0,

    # debug will not actually run anything, it only checks
    # whether the que hangs.
    #
    # nofork runs all of the jobs at simple subroutine
    # calls. this behaves as though majob == 1 but won't
    # mess up the debugger.
    #
    # debug mode runs with minimum verbosity of 1.
    #
    # force ignores all pidfiles -- both empty ones
    # guarding jobs and ones with zero exits in them.
    #
    # restart obeys empty pidfiles and stubs out execution
    # of jobs whose pidifles show a zero exit status.
    #
    # if abort is true then the que behaves like make:
    # aborting all jobs if any one of them fails; setting
    # abort to false causes the que to behave like "make -k":
    # completing any portions of the que that do not depend
    # on a failed job before exiting.

    debug   => 0,   # debug mode does not run anything.
    verbose => 0,   # verbosity == integer level.


    nofork  => '',  # run the jobs w/o forking.

    force   => '',  # force execution, ignores pidfiles
    restart => '',  # stub out jobs w/ zero exit in pidfile.
    abort   => 1,   # false behaves like make -k.


    # force alias to use methods, allows class to
    # handle job dispatch for itself via autoload
    # if one is present.

    autoload    => '',

    # avoid writing to .err and .out files, just use STDOUT
    # and STDERR. mainly for debugging. the .out and .err
    # files are truncated to avoid leaving around stale data.

    ttylog  => 0,   # use STDOUT/ERR for logging.

    # if these are not supplied as arguments or inherited then
    # prpare will croak.

    logdir  => '',
    rundir  => '',

    # used to prefix logdir and rundir entries with the
    # group name to avoid basename collisions for jobs
    # aliased in mutiple groups.

    group => '',



);

# que data.
# this largely managed by the sub's below
# but is also localized by validate

my %mgr2que = ();

########################################################################
# subroutines
########################################################################

# called as
#
#   my ( $mgr, $que ) = &mgr_que
#
# in the methods to strip the manager object
# off the stack and return the que data with
# it.

sub mgr_que
{
    my $mgr = shift;
    my $que = $mgr2que{ refaddr $mgr }
    or confess "Unknown object: '$mgr'";

    wantarray ? ( $mgr, $que ) : $que
}

sub install_que
{
    my $mgr = shift;
    my $que = shift
    or confess 'Bogus install que: missing que!';

    $mgr2que{ refaddr $mgr }    = $que
};

for my $attr
(
    qw
    (
        restart
        force
        noabort
        nofork

        verbose
        debug
        sub

        rundir
        logdir
    )
)
{
    # read-only access to queue attributes.

    my $ref = qualify_to_ref $attr;

    *$ref
    = sub
    {
        $mgr2que{ refaddr $_[0] }{ attrib }{ $attr }
    };
}

for my $name
(
    qw
    (
        jobz
        pidz
    )
)
{
    # runtime status; these should probably not
    # be modified, but there may be a reason so
    # the references are returned.

    my $ref = qualify_to_ref $name;

    *$ref
    = sub
    {
        $mgr2que{ refaddr $_[0] }{ $name }
    };
}

sub failure
{
    $mgr2que{ refaddr $_[0] }{ failure } || ''
}

*errstr = \&failure;

########################################################################
# queue management: check the state, take jobs off the que, check
# what jobs depend on the current one, handle job completion when
# the tasks finish.
#
# note that dequeue and complete are NOT the same action: jobs must
# be removed from the queue before they are forked since the queue
# will be examined multiple times while the job is running.

sub queued
{
    my ( $mgr, $que )   = &mgr_que;

    sort keys %{ $que->{ queued } }
}

sub ready
{
    my ( $mgr, $que )   = &mgr_que;

    my $queued  = $que->{ queued };

    sort grep { ! keys %{ $queued->{ $_ } } }  keys %$queued
}

sub depend
{
    my ( $mgr, $que )   = &mgr_que;

    my $job = shift;

    sort keys %{ $que->{ depend }{ $job } };
}

########################################################################
# take a job out of the queue. this is not the same as
# listing it as complete: jobs must be removed from the
# queue immediately when they are forked since the que
# may be examined many times while the job is running.
#
# dequeing the job simply removes the job's name from
# the queued hash.
#
# job completion involves:
#
#   remove this job from the list of depend list of jobs
#   that depend on it.
#
#   if there is a cleanup method defined for the $que
#   then call it for the job.

sub dequeue
{
    my ( $mgr, $que )   = &mgr_que;

    my $job = shift;

    delete $que->{ queued }{ $job };
}

sub complete
{
    my ( $mgr, $que )   = &mgr_que;

    my $job     = shift;

    my $queued  = $que->{ queued };
    my $depend  = $que->{ depend };

    delete $queued->{ $_ }{ $job }
    for @{ $depend->{ $job } };

    delete $que->{ jobid }{ $job };

    if( my $cleanup = $mgr->can( 'cleanup' ) )
    {
        print "$$: Cleaning up after: $job"
        if $mgr->verbose;

        $cleanup->( $que, $job )
    }
}

########################################################################
# few bits of information, saves extra hard-coding of structure info.
# these are mainly useful for generating sub-queues with the config
# values intact.
########################################################################

# make a shallow copy of the attributes.
# everything hard-coded here is at a single level anyway.

sub status
{
    my ( $mgr, $que )   = &mgr_que;

    my %attrib = %{ $que->{ attrib } };

    wantarray ? %attrib : \%attrib
}

# note that the %{...} mess avoids external code
# mucking around with the values -- none of the alias
# entries are references themselves.

sub alias
{
    my ( $mgr, $que )   = &mgr_que;

    if( @_ )
    {
        # hand back a sliced-up hash...

        my %return = ();

        @return{ @_ } = @{ $que->{ alias } }{ @_ };

        %return;
    }
    else
    {
        # ... or the whole thing.

        %{ $que->{ alias } }
    }
}

########################################################################
# pre-check a queue to ensure that it does not deadlock and that all
# of the jobs are runnable. this includes creating .out, .err, and
# .pid files and sanity checking existing pidfile status.
#
# this can be overloaded on various O/S to use /proc/blah to
# get more detailed in its checks. default is to croak on a
# pidfile w/o exit status.

sub precheck
{
    my ( $mgr, $que )   = &mgr_que;

    my $job = shift;

    # basenames of jobs w/in groups are prefixed by
    # the group name. this allows the same job to be
    # re-aliased in mutiple groups w/o file collisions.

    my $group = $que->{ attrib }{ group };

    $group .= '-' if $group;

    # this stuff only goes out of the verbosity is
    # at the "detail" level.

    my $verbose = $mgr->verbose > 1;

    # jobs can be shell paths, strip the directory to get
    # something valid.

    my $base    = basename $job;

    my $pidfile
    = $que->{ pidz }{ $job}
    = $que->{ attrib }{ rundir } . "/$group$base.pid"
    ;

    my $outfile
    = $que->{ outz }{ $job }
    = $que->{ attrib }{ logdir } . "/$group$base.out"
    ;

    my $errfile
    = $que->{ errz }{ $job }
    = $que->{ attrib }{ logdir } . "/$group$base.err"
    ;

    print "$$: Precheck: $job" if $verbose;

    # gets set to true in the if-block if the job is running.

    my $running = 0;

    # this gets set to true in the block below if we
    # are running in restart mode and the jobs exited
    # zero on the previous pass. setting it to zero here
    # avodis uninit variable warnings.

    $que->{ skip }{ $job }  = 0;

    # phony jobs never execute, they are placeholders.

    return 0
    if defined $que->{ alias }{ job }
    && $que->{ alias }{ $job } eq 'PHONY'
    ;

    # any pidfile without an exit status implies a running job
    # and prevents further execution. in restart mode any file
    # with a zero exit status will be skipped.

    if( -s $pidfile )
    {
        open my $fh, '<', $pidfile or croak "$$: < $pidfile: $!";

        chomp( my @linz = <$fh> );

        close $fh;

        print "$$:  Pidfile:  $pidfile", @linz if $verbose;

        if( @linz >= 3 )
        {
            # the job exited, check the status in case we
            # are running in restart mode. either way, the
            # caller gets back false since the jobs isn't
            # running any longer.
            #
            # restart skips anything that exited zero.
            #
            # otherwise we can just zero out the pidfile and
            # keep going.

            print "$$: Completed: $job" if $verbose;
            print "$$: Previous status:", @linz
            if $que->{ attrib }{ nofork };

            if( $que->{ attrib }{ restart } )
            {
                # take the last exit from the file -- the child
                # and parent both write the same thing to the
                # file so whichever the last one is will be
                # sufficient.
                #
                # since a sub return can be any string that
                # evaluates numerically to zero we have to
                # use a numeric comparison here for a valid test.

                my( $pid, $cmd, $exit ) = @linz[0,1,-1];

                if( $exit == 0 )
                {
                # no reason to re-run this job.
                # note: this is always printed.

                print "$$: Marking job for skip on restart: $job";

                $que->{ skip }{ $job }  = CLEAN;
            }
            else
            {
                print "$$:  $job previous non-zero exit, will be re-run"
                if $verbose;
            }
        }
            else
            {
                print "$$: Not Running:  $job" if $verbose;
            }
        }
        elsif( $que->{ attrib }{ force } )
        {
            # assume the thing is not running and be done with it.
            # this gets a message regardless of verbosity.

            print STDERR "$$: Forcing restart of possibly running job: $job";
        }
        elsif( @linz )
        {
            # without a completion or force, pidfiles without
            # an exit are assumed to be running jobs.

            print STDERR "\n$$: Pidfile without exit: $job";

            $running = 1;
        }
    }
    elsif
    (
        -e $pidfile
        &&
        ! $que->{ attrib }{ restart }
        &&
        ! $que->{ attrib }{ force }
    )
    {
        # jobs with empty pidfiles are assumed to be running
        # unless the restart or force switches are given.
        #
        # Note: on Solaris or Linux this could check things
        # via /proc or Unix::Process. Occams Razor tells me
        # to leave this alone until it proves to be a problem.

        print STDERR "\n$$:	Still running: empty $pidfile";

        $running = 1;
    }
    else
    {
        print "\n$$: No pidfile: $job is not running"
        if $verbose;
    }

    # zero out the pid/log/err files if the job isn't running
    # at this point. leaving this down here makes it simpler
    # to update the block above if there is more than one way
    # to decide if things are still running.

    if( $que->{ skip }{ $job } || $running )
    {
        print "\n$$: Leaving existing pidfile untouched"
        if $verbose;
    }
    else
    {
        # after this point it seems likely that opening the
        # necessary files for write at runtime will succeed.
        # leaving them open here doesn't save much time and
        # is a headache in debug mode.

        open my $fh, '>', $pidfile;

        for my $path ( $outfile, $errfile )
        {
            # zero out the logs if they will be written
            # to, otherwise leave them alone. This is mainly
            # a sanity check here, since the forked process
            # will write to these anyway -- makes more sense
            # to find out that the log can't be written
            # before starting the execution however.
            #
            # assumption here is that production systems
            # will usually run consistently with ttylog or
            # without: usual reason for switching is a test
            # run that probably shouldn't overwrite any
            # existing logs.

            unless( $que->{ attrib }{ ttylog } )
            {
                open my $fh, '>', $path
                or croak "Failed writing empty $path: $!";
            }
        }
    }

    # caller gets back true if we suspect that the job is
    # still running, false otherwise.

    $running
}

########################################################################
# convert the job tag from the schedule into what gets run and run it.
# these are general fodder for overloading.
########################################################################

########################################################################
# execute the job after the process has forked.
# overloading this is heavily tied to changes
# in unalias.
#
# this may be called as a sub or method, in any
# case the closure will be the last argument.
#
# returning the exit status here makes avoiding
# phorkatosis simpler since the caller can manage
# the exit in one place, and ensures that the exit
# status gets written to the pidfile even if the
# parent process dies while this is running.
#
# the caller gets back whatever the code
# reference returns.

sub runjob { $_[-1]->() }

########################################################################
# the result here gets passed to runjob for
# execution. idea here is to hand off whatever
# seems most useful to run.
#
# Changes to unalias should be carefully checked
# againsed what runjob expects to handle.
#
# checking for the package is
# generally overkill but allows this to be
# called as a normal subroutine and still
# return something useful.
#
# Note: need to make sure that:
#
#	foo = Package::Name->blah
#
# ends up as Package::Name->blah( 'foo' );
#
# the $packge, $subname trick will break on
# this because "Name->blah" won't be any kind
# of valid subroutine w/in the package.
#
# generate the closre called in the child process:
#
# process $run into a sub referent if we can find
# a way:
#
#	phony aliases return a numerically false exit
#	string immediately.
#
#	code blocks are evaled into a sub -- note that
#	this leaves any variables in the block expressed
#	here, in this package.
#
# Note: from here down the sub's are called with an
# argument of the original job tag from the
# schedule. see the POD for examples of where
# this can be useful for dispatching multiple
# jobs through the same code.
#
#	check for fully qualified subnames -- this has
# 	to be done AFTER checking for code blocks, which
# 	may contain legit "::". since S::D may not have
# 	already use-ed the module, require it here --
#	ignore any error since the package may be
#
#	check if the que object has a method to handle
# 	the call.
#
#	check if the current package has a subroutine
#	name.
#
# caller gets back the anonymous sub referent or
# the contents of $run.

sub unalias
{
    # $que might be a blessed object or it might be
    # a package name. Either way, we will be able to
    # use it in "$mgr->can( $job )".

    my ( $mgr, $que )   = &mgr_que;

    my $job = shift;

    # if $que is a referent then access its alias sub-hash
    # and grab out the entry for this job. If it doesn't
    # exist then return the job.
    #
    # non-referent first arguments would show up if unalias
    # is used as part of another module (e.g., a dispatcher
    # in Schedule::Cron).

    my $run
    = defined $que->{ alias }{ $job }
    ? $que->{ alias }{ $job }
    : $job
    ;

    # this goes into the pidfile to identify what
    # is being run. it will be the 2nd line of the file,
    # before the child (stringy) exit and parent (fork
    # return) exit lines.

    $que->{ idstring }{ $job }
    = my $idstring
    = $job eq $run
    ? $job
    : "$job ($run)"
    ;

    # generate the closure.

    my $sub
    = do
    {
        if( $run eq 'PHONY' || $run eq 'STUB' )
        {
            # returning the id string is fast and should be safe
            # enough since idstrings will normally not be numeric.
            # but just in case, prefixing it with the stub message
            # guarantees it.

            sub { "STUB $idstring" }
        }
        elsif( $run =~ /^({.+})$/ )
        {
            eval "sub $run"
            or die "$$: Bogus unalias: Invalid block for $job: $run";
        }
        elsif( my ($p,$s) = $run =~ /^(.+)::(.+?$)$/ )
        {
            eval "require $p";

            my $fqsub = $p->can( $s )
            or die "$$: Bogus $job ($run): no $p->can( $s )";

            sub { $fqsub->( $job ) };
        }
        elsif( my $method = $mgr->can( $run ) )
        {
            sub { $mgr->$method( $job ) };
        }
        elsif
        (
            $que->{ attrib }{ autoload }
            and
            $mgr->can( 'AUTOLOAD' )
        )
        {
            # they asked for it... let the autoload
            # demangle the run call for itself.

            sub { $mgr->$run( $job ) }
        }
        elsif( my $pkgsub = __PACKAGE__->can( $run ) )
        {
            sub { __PACKAGE__->$pkgsub( $job ) };
        }
        else
        {
            # punt whatever it is to the shell.
            # this allows the path to resolve shell commands but
            # may require shell items with the same names as methods
            # to have a '/' inserted in them somewheres.

            sub { $mgr->shellexec( $run, $job ) };
        }
    };

    die "$$: Bogus unalias: no subroutine for $idstring"
    unless $sub;

    print "$$: $idstring ($sub)" if $mgr->verbose;

    $sub
}

########################################################################
# putting this into its own method allows better reporting
# and saves the caller from having to figure out what
# a shell vs. subroutine return means: returning non-zero
# to the dispatcher which will report the job as failed.
# Since this checks both the return value of system and
# $? it will catch whatever can be handled automatically.

sub shellexec
{
    my ( $mgr, $que )   = &mgr_que;

    # if anything goes wrong put a message
    # into the logfile and pass the non-zero
    # exit status up the food chain.

    if( system(@_) == -1 )
    {
        # we failed to run the program,

        carp "$$: Failed system(@_): $!";

        -1
    }
    elsif( my $stat = $? )
    {
        # system succeeded in running the
        # program but it failed during
        # execution.

        if( my $exit = $stat >> 8 )
        {
            carp "$$: Non-zero return for $_[1]: $exit";
        }
        elsif( $stat == 128 )
        {
            carp "$$: Coredump from $_[1]";
        }
        elsif( my $signal = $stat & 0xFF )
        {
            carp "$$: $_[1] stopped by signal: $signal";
        }

        $?
    }
    else
    {
        print "$$: system(@_) succeeded"
        if $mgr->verbose > 1;

        0
    }
}

########################################################################
# deal with groups & sub-queues.
########################################################################

########################################################################
# generate a group on the fly running the same method on each
# of the list items passed in. this makes up for having only a single
# variable argument in the passing protocol: S::D::Execute can call
# jobs which hard-code the method or pick it up from defaults and
# then call this with a method name and list.

sub sched_list
{
    my ( $mgr, $que )   = &mgr_que;

    $DB::single = 1 if $mgr->debug;

    my $method = shift
    or die "Bogus sched_list: missing method name";

    $mgr->can( $method )
    or die "Bogus sched_list: the que cannot '$method'";

    my $list = shift
    or die "Bogus sched_list: missing list";

    # this could also call subsched... issue there is
    # compounding the parallel execution. for now
    # single-stream the thing.

    if( 1 )
    {
        $mgr->$method( $_ ) for @$list;
    }
    else
    {
        # ??? unfinished ???

        my $name = "sched_list-$method";

        my @sched
        = map
        {
            ( "$_ : ", "$_ = $method" )
        }
        @$list;
    }

    # caller gets back the method and list processed
    # back as a string.

    join ' ', $method, @$list
}

########################################################################
# schedules with groups use an alias for the groupname and then
# assign jobs w/in the group:
#
#	name = rungroup
#
#	name ~ job [job...]
#
# the ~ line creates $que->{ group }{ $name }, which is then
# processed here.

sub group
{
    my ( $mgr, $que )   = &mgr_que;

    my $name	= shift
    or croak "$$: Bogus rungroup: missing group argument.";

    my $sched = $que->{ group }{ $name }
    or croak "$$: Bogus rungroup for $name: missing group entry in que";

    log_message "Preparing subque $name:", $sched
    if $mgr->verbose > 1;

    # caller gets back the result of running the schedule.
    # since this is normally called from execute, it is
    # already wrapped in an eval to begin with.

    $mgr->subque( $sched )->execute
}

########################################################################
# this is meaningless unless the object used to access
# this method really is based on S::D.  in which case,
# the only thing useful to bless the results into is
# ref $que.

sub subque
{
    my ( $mgr, $que )   = &mgr_que;

    croak "$$: Bogus subque: no schedule argument"
    unless @_;

    my $argz
    = do
    {
        if( @_ > 1 )
        {
            # assume it's a list that can be safely assigned to a hash.

            { @_ }
        }
        elsif( 'ARRAY' eq reftype $_[0] )
        {
            # assume it's a schedule in array or scalar format
            # (e.g., a group). only thing needed here is to add
            # the sched key for prepare.

            { sched => shift }
        }
        elsif( 'HASH' eq reftype $_[0] )
        {
            # assume it's a hash with sched entry.

            shift
        }
        else
        {
            # otherwise it's junk

            confess "Bogus subque: '$_[0]' invalid schedule";
        }
    };

    # modify arguments to show that this is a subque and
    # should inerit from the que's values. this is the
    # only place that this should get set.

    $argz->{ subque } = $que;

    # caller gets back a new que object with the schedule
    # portion configured for the subque.

    $mgr->prepare( %$argz )
}

########################################################################
# que constructor
########################################################################

# minimal constructor and new.
# these are only useful if the que will
# not be dispatching any methods (e.g.,
# schedule with only shell or perl funcs).

sub construct
{
    my $proto   = shift;

    bless {}, ref $proto || $proto;
}

sub new
{
    my $mgr     = &construct;

    if( my $init    = $mgr->can( 'init' ) )
    {
        $mgr->$init( @_ )
    }

    $mgr
}

sub prepare
{
    $DB::single = 1;

    local $\ = "\n";
    local $, = "\n";
    local $/ = "\n";

    # the prototype's namespace is used to dispatch
    # any methods in the schedule.
    #
    # if the prototype is already blessed then recycle
    # it as the queue manager, otherwise create a new
    # object to manage the que.

    my $proto   = shift;

    my $mgr
    = blessed $proto
    ? $proto
    : $proto->new
    ;

    # validate & sanitize the arguments
    #
    #	either need one or an even number of arguments.
    #
    #	won't do much good trying to create a sub-que if
    # 	$proto isn't already a que.
    #
    #	writing the pidfiles out will overwrite any history
    #	of the previous execution and make the queue un-
    #	restartable for execution.
    #
    #	avoid processing a false schedule. this can happen via
    #	things like prepare( verbose => 1 ) or prepare();
    #
    #	convert a string schedule to an array referent.
    #	at this point we assume that anyone passing an object
    #	has a proper stringify overload for it.

    croak "\n$$: Missing schedule argument"
    unless @_;

    my %argz = ();

    if( @_ > 1 )
    {
        # treat it as a list for hash assignment

        croak "\n$$: Odd number of arguments"
        if @_ % 2;

        %argz = @_;
    }
    elsif( 'ARRAY' eq ref $_[0] )
    {
        # assume an arrayref is the schedule,

        %argz = ( sched => shift );
    }
    elsif( 'HASH' eq ref $_[0] )
    {
        # treat it as a hash reference containing the
        # entire schedule.
        # queues passed in as array ref's are still hashes
        # like ( sched => \@schedule_as_array ).

        %argz = %{ $_[0] };
    }
    elsif( ! ref $_[0] )
    {
        # it's a scalar string with the schedule in it

        $argz{ sched } = $_[0];
    }
    else
    {
        # unusable reference (e.g., file handle)

        confess "Bogus prepare: unusable arguemnt '$_[0]'"
    }

    # sanity check the arguments.

    confess "Missing schedule list"
    unless $argz{ sched };

    confess "$$: Bogus prepare: subque set without an existing que"
    if $argz{ subque } && ! ref $proto;

    confess "$$: Bogus prepare: cannot prepare a subque without a que"
    unless ! $argz{ subque } || $proto->isa( __PACKAGE__ );

    confess "prepare called with both deubg and restart"
    if( $argz{ debug } && $argz{ restart } );

    # make sure it is an array reference.

    $argz{ sched } = [ split /\n+/, $argz{ sched } ]
    unless ref $argz{ sched };

    # now deal with the arguments themselves and the
    # schedule.

    my $verbose = $argz{ verbose } || 0;

    # at this point the que data can be assembled.
    # much of this won't get used until runtime,
    # having it available simplifies life, however.

    my $que =
    {
        # defined by the schedule.

        queued  => {},  # jobs pending execution.
        depend  => {},  # inter-job dependencies.
        group   => {},  # groups by name
        phony   => {},  # list of phony jobs

        # attributes are slightly different from aliases in
        # that they describe the que object's behavior where
        # aliases are used to define the behavior of the
        # schedule. there is no functional reason that they
        # cannot be stored together; separating them avoids
        # namespace collisions and simplifies inheritence of
        # que settings in subqueues.
        #
        # these are the defaults for new queues..

        attrib  => '',
        alias   => '',

        # bookkeeping of forked proc's.

        skip    => {},  # see constants ABORT, CLEAN.

        jobz    => {},  # $jobz{pid} = $job
        pidz    => {},  # $que->{pidz}{$job} = $job.pid path
        outz    => {},  # $que->{pidz}{$job} = $job.out path
        errz    => {},  # $que->{pidz}{$job} = $job.err path

        executed => '', # this hasn't run before
    };

    $mgr->install_que( $que );

    # subques inherit their parents attributes, which are
    # overridden by explicit arguments and the que's user
    # data area. note that these override anything passed
    # in as arguments.

    if( my $parent  = delete $argz{ subque } )
    {
        exists $parent->{ $_ } and $que->{ $_ } = $parent->{ $_ }
        for @inherit;
    }

    # from this point onward the construction of a que and
    # a sub-que are the same.

    # handle the dependency list, first step is to strip
    # out comments and blank lines, we are then left with
    # valid dependencies.
    #
    # the only lines that really matter will have a ':' or '='
    # in them for "job : target" or "alias = assignment" entries.
    #
    # one common, easily fixed, mistake is "foo:" instead of "foo :".
    # the cleanups handle "foo :"  or "foo:" -> "foo : ".

    my @linz
    = map
    {
        s{ \s+ }{ }xg;

        s{^ (\S+?) [ ]* : [ ]* $}{$1 : }x;

        s{^ (\S+?) ([=%<]) }{$1 $2 }x;

        # convert:
        # 'foo : bar'   -> [ qw( : foo bar ) ]
        # 'more = less' -> [ qw( = more less ) ]
        # 'x < y = z >' -> [ '<',  'x', 'y = z' ]
        #
        # Note: this leaves a dangling '>' on the group
        # definitions that has to get split off in the
        # group handler.

        [ ( split m{ \s+ ( [:=%<] ) \s+ }x, $_, 2 )[ 1, 0, 2 ] ]
    }
    grep
    {
        # strip out obvious whitespace and comment lines

        s{^ \s+ }{}x;
        s{ #.* $}{}x;

        m{\S}
    }
    @{ delete $argz{ sched } }
    or confess 'Empty schedule';

    log_message 'Preparing Schedule From:', \@linz
    if $verbose;

    # step 1: deal with information in the attribues.
    # this overrides any aguments or defaults.
    # if the caller sets an unknown attributes it causes
    # a warning; avoiding an error at this point permits
    # overriding methods to use non-standard attributes
    # assigned via the arguments or schedule.
    #
    # attributes are assigned in the schedule via:
    #
    #   word % setting
    #
    # where the word is all word characters ( i.e., cannot
    # contain either '=' or '<'.
    #
    # the map hands back an arrary of 2-element arrays of
    # the attribute keys and their values.
    #
    # first step is to grab any attributes that were passed
    # in as arguments. these are reserved words defined in
    # %defaultz.
    #
    # then grab the attributes from the schedule.

    $que->{ attrib }
    = do
    {
        my %a
        = map
        {
            '%' eq $_->[0]
            ? @$_[1,2]
            : ()
        }
        @linz;

        $a{ $_ }    //= delete $argz{ $_ }
        for keys %defaultz;

        $a{ $_ }    //= $defaultz{ $_ }
        for keys %defaultz;

        # sanity check the attributes and handle dependencies
        # between them.

        $a{ rundir } or croak "$$: Bogus que args: missing rundir";
        $a{ logdir } or croak "$$: Bogus que args: missing logdir";

        $a{ maxjob } >= 0
        or croak "$$: Bogus que args: negative maxjob";

        # sanity check the directories.

        for( $a{ rundir }, $a{ logdir } )
        {
            print "$$: Checking: $_" if $verbose;

            -e      or croak "Non-existant:  $_";
            -w _    or croak "Un-writable:   $_";
            -r _    or croak "Un-readable:   $_";
            -x _    or croak "Un-executable: $_";
        }

        # debug mode doesn't fork or run the commands. it's useful
        # for debugging dependency lists.
        #
        # perl debugger always runs in nofork mode since it does
        # not handle forks gracefully.

        $a{ nofork   }  ||= $^P unless @::ttyz;
        $a{ verbose  }  ||= 1 if $a{debug};

        \%a
    };

    # verbose displays decision information, non-verobse only
    # displays error messages.
    #
    # $argz{verbose} overrides all other levels during
    # preparation, without an argument it's either
    # 2 (set via $que->{nofork}) or defaults to 0 (not much
    # output).
    #
    # verbose > 0 will display the input lines.
    # verobse > 1 additionally displays each alias/dependency
    # as it is processed.
    #
    # if nothing "verbose" is set in the schedule or arg's
    # then debug mode runs in "progress" mode for verbose.
    #
    # note that we may be in a subque here so verbose has
    # to be re-checked for each processing cycle.

    $verbose = $que->{ attrib }{ verbose } > 1;

    log_message 'Attributes:', $que->{ attrib }
    if $verbose;

    @linz   = grep { '%' ne $_->[0] } @linz;

    # next: deal with information in the aliases.
    # note that aliases w/in groups are dealt with
    # when the group is dispatched (in subque).
    #
    # [ '=', 'name', 'alias' ]

    $que->{ alias }
    = do
    {
        my %a
        = map
        {
            '=' eq $_->[0]
            ? @$_[1,2]
            : ()
        }
        @linz;

        \%a
    };

    log_message 'Aliases:', $que->{ alias }
    if $verbose;

    @linz   = grep { '=' ne $_->[0] } @linz;

    # at this point the aliases have been dealt with;

    # now deal with groups.
    #
    # at this point these look like:
    #
    #	[ '<', groupname,  'syntax >' ]
    #
    # with whitespace around the <>. trick is that
    # the schedule can contain any valid schedule
    # since the extracted information is passed to
    # prepare wholesale. using a regex w/ greedy
    # operators and anchors assures getting the
    # entire group definition. the whole thing has
    # to be processed as an array since there is no
    # telling in advance how many entries might be
    # in a single group.
    #
    # requiring word char's for the group name
    # avoids any '=' before the '<' and allows
    # aliases to use redirection.

    $que->{ group }
    = do
    {
        my $aliasz  = $que->{ alias };

        my @groupz
        = map
        {
            '<' eq $_->[0]
            ? do
            {
                my ( undef, $name, $syntax )   = @$_;

                $syntax =~ s{ > .* }{}x
                or croak "Bogus group: $name, $syntax lacks '>'";

                [ $name => $syntax ]
            }
            : ()
        }
        @linz;

        my @namz
        = do
        {
            my @n       = map { $_->[0] } @groupz;
            my %uniq    = ();
            @uniq{ @n } = ();

            keys %uniq
        };

        my %grp2sched   = ();

        for my $name ( @namz )
        {
            print "$$: Adding group: $name"
            if $verbose;

            $grp2sched{ $name } =
            [
                [ "name % $name" ],
                map
                {
                    $name eq $_->[0]
                    ? $_->[1]
                    : ()
                }
                @groupz
            ];

            # insert the group alias if the user didn't.
            # Note: there might already be an alias if
            # the schedule uses another method to handle
            # this group.

            $aliasz->{ $_ } ||= 'group';
        }

        # hand back the groups

        \%grp2sched
    };

    # at this point all of the items for any one group
    # have been collected in the lookaside list $que->{group}.

    log_message 'Groups defined:', $que->{ group }
    if $verbose;

    @linz   = grep { '<' ne $_->[0] } @linz;

    # items without ' % ',' = ' or ' < ' are the sequence
    # information.

    print "$$: Starting rule processing"
    if $verbose;

    # syntatic sugar, minor speedup.

    my $depend	= $que->{ depend    };
    my $queued	= $que->{ queued    };
    my $phony	= $que->{ phony     };

    for( grep { ':' eq $_->[0] } @linz )
    {
        log_message 'Processing rule:', $_
        if $verbose;

        # break up the line into two pieces on the first ' : '
        # then split the remainin pieces on whitespace. the
        # first non array ($a) are the dependent jobs, the
        # second are what they are dependnt on.

        my( $a, $b ) = map { [ split ] } @{ $_ }[1,2];

        # step 1: validate the job status. this includes
        # checking if any are already running or if we
        # are in restart mode and the jobs don't need to
        # be re-run.
        #
        # overloading to validate external influences (e.g.,
        # existing system resources or data files) should
        # be done here.
        #
        # catch: it's a pain to add all of the dependencies
        # for a job as separate jobs (e.g., a: b c d requiring
        # separate stub entries b:, c: and d:).
        #
        # catch: some jobs don't depened on anything but still need
        # to be in the queue.
        #
        # fix for both: assign an emtpy hash to everything initially.
        # this keeps the grep { ! keys ... } happy and means that
        # runnable will find all of them.
        #
        # Note: after this loop is done running precheck we should
        # have an empty file for each job. tracking the empty files
        # is a good way to know what's left in the queue if we
        # aren't running in verbose mode.

        for my $job ( @$a, @$b )
        {
            # skip files we've already checked.

            next if exists $queued->{ $job };

            croak "$$: Unrunnable: $job"
            if $mgr->precheck( $job );

            $queued->{ $job } = {};
        }

        # at this point every job in the rule has been
        # put where we can find it again. now to deal
        # with the targets.
        #
        # sanity check: does the job deadlock on itself?
        #
        # insert this job into the queue with a list of what
        # it depends on.
        #
        # the keys of %$queued are those jobs
        # still queued [hey!]. They are runnable when all of
        # the dependencies have been complated, i.e., the
        # hash %{ $queued->{job} } is empty.
        #
        # $depend->{$job} references an array of the other jobs
        # that will depend on $job completing. This is used to
        # quickly remove entries from $queued->{$anotherjob}
        # when $job completes.
        #
        # for all pratical purposes, keys %$queued is the
        # "queue" here.

        for my $job ( @$a )
        {
            croak "$$: Deadlock dependency: $job depends on itself"
            if grep { $job eq $_ } @$b;

            @{ $queued->{ $job } }{ @$b } = (1) x @$b;

            push @{ $depend->{$_} }, $job for @$b;
        }
    }

    if( $verbose )
    {
        log_message 'Jobs:',         sort keys %$queued;
        log_message 'Waiting for:',  sort keys %$depend;
    }

    if( @linz = grep { ':' ne $_->[0] } @linz )
    {
        log_warning
    }

    # anything left in @linz at this point is unusable cruft
    # and needs to be logged.

    # quick sanity checks: is everything listed as a dependency
    # also a job and is there at least one job that has no
    # dependencies (i.e., can be run to begin with)?

    # $queued->{$job} exists if $job gets run.
    # $depend->{$job} exists if something depends on $job.
    #
    # at this point $queued{$job} should be defined for
    # keys %$depend or there is a dependency which never
    # will get run.

    if( my @unrun = grep { ! exists $queued->{$_} } sort keys %$depend )
    {
        croak join ' ', "\nSome dependencies do not get run:", @unrun;
    }

    # if there are no jobs ready for the first iteration then
    # we won't get very far...

    if( my @initial =  $mgr->ready )
    {
        print join "\t", "$$: Initial Job(s): ", @initial, "\n"
        if $verbose;
    }
    else
    {
        croak "Deadlocked schedule: No jobs are initially runnable.";
    }

    log_format 'Resulting queue:', $que
    if $verbose;

    # if we are still alive at this point the queue looks
    # sane enough to try.

    $mgr
}

########################################################################
# process the que.
########################################################################

# copy the que and run it once through to determine if there
# are any deadlock or unalis issues. the copy is necessary to
# avoid the debug operation "consuming" all of the queued
# entires.
#
# note that this may have subtle effects in cases where unalias
# has side-effects as it runs (e.g., updating global variables).
#
# if the copied object successfully empties itself then the
# original que object is returned. this allows for:
#
#   eval { S::D->prepare(%argz)->debug->execute };
#
# or
#
#   eval { $mgr->subque(%argz)->debug->execute };
#
# to debug and run the que in one pass since the debug will
# abort execution by returning undef if it fails.
#
# Note: the deep copy is necessary to avoid dequeue
# and complete from consuming the queued and depend
# hashes w/in the que object.
#
# Side effect of this will be creating pidfiles for
# all jobs showing a "debugging" line and non-zero
# exit. This allows debug in and restart mode without
# having to clean up the pidfiles by hand.

sub validate
{
    my ( $mgr, $que )   = &mgr_que;

    eval
    {
        # boolean operator on the que object makes immediate
        # test of $tmp useless.
        #
        # separate variables are for debugging.

        $que
        = local $mgr2que{ refaddr $mgr }
        = dclone $que
        ;

        $que->{ attrib }{ maxjob  }   = 1;
        $que->{ attrib }{ validate}   = 1;
        $que->{ attrib }{ nofork  }   = 0;

        $mgr->execute;

        print "$$: Validation completed\n"
        if $mgr->verbose;
    };

    print STDERR "\n$$: Validate Failed: $@" if $@;

    # caller gets back original object for daisy-chaining or
    # undef (which will abort further execution if it is
    # daisychained).

    $@ ? undef : $mgr;
}

# do the deed.

sub execute
{
    local $\ = "\n";
    local $, = "";
    local $/ = "\n";
    local $| = 1;

    my ( $mgr, $que )   = &mgr_que;

    croak "\n$$: Bogus execute: this que has already executed."
    if( $que->{ executed } );

    # after execute has been called once the que cannot be
    # re-run since the queued array has been consumed.

    croak "$$: Bogus execute: Nothing to run" unless $que;

    my $attrib = $que->{ attrib };

    # set the verbosity level. rather than test
    # for $verbose > X a zillion times this sets
    # a few, hopefully more descriptive, var's.
    #
    # if nothing is set then skips due to abort,
    # non-zero exits, forkaphobia, exec fails
    # and croaks are displayed.
    #
    # print_progress	=>	show jobs being forked, reaped,
    #						jobs skipped on restart.
    # print_detail 		=>	show unalias results, exit status,
    #						runnable jobs, job slot limitations.
    #
    # debug mode always runs w/ verbose == 2 (i.e., sets
    # $print_detail).

    my $print_progress	= $attrib->{ verbose } > 0;
    my $print_detail	= $attrib->{ verbose } > 1;

    # this intentionally goes to STDERR so that the
    # logs have a start/completion message in them
    # at least.

    if( $attrib->{ validate } )
    {
        print STDERR "$$: Begin Debugging";

        log_format 'Debugging:', $que
        if $print_detail;
    }
    else
    {
        print "$$: Beginning Execution";
    }

    # use for logging messages to make sure that the jobs are
    # really run in parallel.

    my $t0 = time;

    # associate pids returned by wait with the jobs we forked.

    my $jobz = {};

    # housekeeping: set run-specific variables to
    # reasonable values.

    $que->{ failure } = '';

    # may have been tickled externally, localizing the value
    # here avoids screwing up the caller's settings.

    local $SIG{ HUP  }  = 'IGNORE';
    local $SIG{ CHLD }  = 'DEFAULT';

    local $SIG{ INT  }
    = sub { $que->{ failure } = "Scheduler aborted by SIGINT" };

    local $SIG{ QUIT }
    = sub { $que->{ failure } = "Scheduler aborted by SIGQUIT" };

    local $SIG{ TERM }  =
    sub
    {
        # blow off anything listed as running and mark the que as
        # aborting. the normal process of reaping child proc's will
        # label the pidfiles with a non-zero exit.

        print STDERR "$$: Killing running jobs on sigterm";

        $que->{ failure }
        = "Parent process ($$) zapped by SIGTERM";

        kill TERM => keys %$jobz if %$jobz;
    };

    # nothing started, yet.

    my $maxjob	= $attrib->{ maxjob };
    my $slots	= $maxjob;

    # things are runnable when the hash stored for them in the queue
    # has no dependencies remaining.
    #
    # sorting the list makes it a bit easier to track the execution
    # but shouldn't effect the outcome at all.
    #
    # notice that this forks all the jobs it can before testing
    # for another exit.
    #
    # note that since the execution of jobs is async. there may be
    # times when we have a queue with no runnable jobs. in this
    # case runnable returns nothing and we fall through to the
    # wait.
    #
    # the || %$jobz test handles the last few jobs, where the
    # queue is empty but we need to cycle through the wait
    # loop.

    while( %{ $que->{ queued } } || %$jobz )
    {
        if( my @runnable = $mgr->ready )
        {
            print join "\t", "$$: Runnable:", @runnable, "\n"
            if $print_detail;

            print "$$: Slots / jobs: $slots / " . scalar @runnable
            if $print_progress;

            RUNNABLE:
            while ( @runnable )
            {
                # if maxjob is set then throttle back the number of
                # runnable jobs to the number of available slots.
                # forking decrements $slots; exits increments it.

                if( $maxjob && ! $slots )
                {
                    print join ' ',
                    "$$: No slots available: Unable to start runnable:\n",
                    @runnable
                    if @runnable && $print_detail;

                    last RUNNABLE;
                }

                # expand the job entry from the dependency list
                # into whatever actually gets passed to the shell.
                #
                # the second argument is the "firstpass" indicator,
                # which is zero now that we aren't calling from
                # the prepare method.

                my $job = shift @runnable;

                my $sub = $mgr->unalias( $job );

                my $jobid = $que->{ idstring }{ $job };

                # open the pidfile first, better to croak here than
                # leave a job running w/o a pidfile. skip this for
                # jobs that completed when running in restart mode.

                open my $fh, '>', $que->{ pidz }{ $job }
                or croak "$$: $job: $que->{ pidz }{ $job }: $!"
                unless( $que->{ skip }{ $job } == CLEAN );

                # deal with starting up the job:
                #	don't fork in debug/nofork mode.
                # 	put an abort message into the pidifle in abort mode.
                #	otherwise fork-exec the thing.
                #
                # debug and nofork skip forking, all of the
                # jobs run w/in this process -- bypassing
                # all of the bookkeeping associated with forks.
                #
                # debug just checks for deadlocks;
                # nofork actually runs the jobs and is intended
                # for debugging.

                $DB::single = 1 if $mgr->debug;

                if( $attrib->{ validate } )
                {
                    print "$$: Debugging: $jobid\n"
                    if $print_progress;

                    print "$$: Checking $que->{ idstring }{ $job }"
                    if $attrib->{ validate };

                    $mgr->dequeue( $job );

                    $mgr->complete( $job );
                }
                elsif( $attrib->{ nofork } )
                {
                    # don't fork, just get the sub and eval it
                    # w/in this process. execution gets here
                    # in the perl debugger or if nofork is
                    # passed in as an argument when creating
                    # the que.
                    #
                    # this leaves the pidfiles and logfiles
                    # untouched.

                    print "$$: Single-threading: $jobid\n"
                    if $print_progress;

                    print $fh "$$\n$jobid";

                    $mgr->dequeue( $job );

                    my $sub = $mgr->unalias( $job );

                    # run the job w/in this process;
                    # aborting the entire que if this job
                    # fails.

                    my $exit = $mgr->runjob( $sub );

                    print "$$: Result of $jobid: " . $exit;

                    print $fh $exit;

                    {
                        # avoid warnings about
                        # non-numerics in addition

                        my $value
                        = looks_like_number $exit
                        ? $exit
                        : 0
                        ;

                        print $fh $value;
                    }

                    $mgr->complete( $job );
                }
                elsif( my $reason = $que->{ skip }{ $job } )
                {
                    # $que->{skip}{$job} is only set if $que->{restart}
                    # or $que->{abort} are set.
                    #
                    # process jobs that are runnable but marked for
                    # skipping.  these include ones that completed
                    # zero on the previous pass in restart mode or
                    # depend on failed jobs in noabort mode. either way,
                    # they don't effect the number of running jobs and
                    # need to be purged from the queue before we decide
                    # how many jobs can be run.

                    if( $reason == CLEAN )
                    {
                        # job is being skipped due to re-execution in restart
                        # mode and the job exiting zero on the preivous pass.
                        #
                        # the pidfile can be ignored since the previous exit
                        # was clean.

                        print "$$: Skipping $jobid on restart."
                        if $print_progress;
                    }
                    elsif( $reason == ABORT )
                    {
                        # this means that a job this one depends on failed.
                        # update the pidfile with an "aborted" message and
                        # non-zero exit status then find the jobs that depend
                        # on this one and update their skip values to ABORT
                        # also.
                        #
                        # %jobz doesn't get updated here: since nothing is forked
                        # there isn't a pid to store anywhere.

                        print "$$: Skipping $jobid on aborted prerequisite."
                        if $print_progress;

                        print $fh "Failed prerequisite in noabort mode\n-1";

                        # first mark the jobs which depend on this one
                        # for abort, then dequeue and complete this one.
                        # dequeueing this job will push

                        $que->{ skip }{ $_ }
                        = ABORT for $mgr->depend( $job );
                    }
                    else
                    {
                        die "$$: Bogus skip setting for $job: $reason";
                    }

                    # either way, we are done with this job.
                    # any jobs left runnable here will be picked up on
                    # the next pass.

                    $mgr->dequeue( $job );
                    $mgr->complete( $job );
                }
                elsif( $reason = $que->{ failure } )
                {
                    # jobz doesn't get updated here: since nothing is forked
                    # there isn't a pid to store anywhere.
                    #
                    # we do have to update the pidfile, however, to show
                    # that the job was aborted.

                    print "$$: Skipping $jobid due to: $reason";

                    print $fh "$$\nAbort: $reason: $jobid\n-1";

                    $mgr->dequeue( $job );
                    $mgr->complete( $job );
                }
                else
                {
                    # actually going to run the job.

                    # first, remove the job from $que->{queued} immediately
                    # since we may call runnable any number of times during
                    # the job's execution.
                    #
                    # %jobz maps the pid of an exited job onto its key in
                    # the queue in order to clean up the dependencies on it.
                    #
                    # once the job is forked the pidfile contains two lines:
                    # process id and command being run.
                    #
                    # the file handle for this job gets a pid written to it
                    # when the job is forked and an exit status appended at
                    # the end. checking for zero exit status of existing
                    # pidfiles in the prepare would be a nice way to allow
                    # for automatic restarts.

                    # if we got here in debug mode then
                    # make reeeeel sure to have a valid
                    # tty out there or exit immediately.

                    if( $^P )
                    {
                        exit -1
                        unless my $tty = shift @::ttyz;

                        for( 'pts', 'dev' )
                        {
                            last if -e $tty;

                            $tty = "$_/$tty";
                        }

                        -e $tty or exit -2;

                        $DB::fork_TTY = $tty;
                    }

                    if( my $pid = fork )
                    {
                        print $fh "$pid\n$jobid";

                        $jobz->{ $pid } = $job;

                        $mgr->dequeue( $job );

                        --$slots;

                        print "$$: Forked $pid: $job\n"
                        if $print_detail;
                    }
                    elsif( defined $pid )
                    {
                        # now in the child process.
                        #
                        # Note: make sure to exit w/in this block to
                        # avoid forkatosis.

                        # parent will propagate SIGTERM, normal
                        # reaping cycle will mark this with a
                        # non-zero exit in the pidfile.

                        local $SIG{ TERM } = 'DEFAULT';

                        # remember to do this before closing stdout.

                        print "$$: Executing: $jobid\n"
                        if $print_detail;

                        unless( $attrib->{ ttylog } )
                        {
                            my $outpath = $que->{ outz }{ $job };
                            my $errpath = $que->{ errz }{ $job };

                            print "$$: $job: stdout -> $outpath\n$$ $job: stderr -> $errpath"
                            if $print_detail;

                            open STDOUT, '>', $outpath or croak "$outpath: $!";
                            open STDERR, '>', $errpath or croak "$errpath: $!";
                        }
                        else
                        {
                        print STDERR "$$: logging $jobid to stdout/stderr";
                        }

                        # do the deed, record the result and exit.
                        #
                        # printing the string to the file handle
                        # allows subroutines to return more useful
                        # completion messages -- so long as they
                        # evaluate to zero.
                        #
                        # Note: child never reaches the point where $fh
                        # is closed in the main loop.

                        my $result = eval { $mgr->runjob( $sub ) } || $@;

                        print $fh $result;

                        close $fh;

                        # avoid logging nastygrams about non-numeric
                        # values in the + 0 step.

                        no warnings;

                        my $exit = $@ ? -1 : $result + 0;

                        warn "$$: $job: $exit" if $exit;

                        exit $exit;
                    }
                    else
                    {
                        # give up if we cannot fork a job. all jobs
                        # after this will have pidfiles with a non-zero
                        # exit appended to them and an abort message.

                        print $fh -1;

                        print STDERR "\nn$$: phorkafobia on $job: $!";

                        $que->{ failure } = "Phorkaphobia at $job";
                    }
                }

                # parent closes the file handle here, regardless
                # of how the file was processed.
                #
                # test avoids problems if the file handle wasn't
                # opened (e.g., if the job was skipped).

                close $fh if $fh;
            }

        }
        elsif( %$jobz eq '0' )
        {
            # if nothing is available for execution then we'd
            # better have some jobs outstanding in the background
            # or the queue is deadlocked.

            print STDERR "\n$$: Deadlocked schedule: neither runnable nor pending jobs.\n";
            print STDERR "\n$$: Remaining jobs:", $mgr->queued;

            $que->{ failure } = 'Deadlock';
        }

        print STDERR "\n$$: Aborting queue due to $que->{ failure }.\n"
        if $que->{ failure };

        # block for something to exit, convert the pid back into a
        # job key remove this job from the dependency lists of
        # whatever remains queued.
        #
        # this should not be a while-loop, since that could
        # leave runnable jobs waiting for unrelated items
        # to start. since any one job might leave multiple
        # jobs runnable, we have to deal with the exits
        # one at a time. the if-block also deals more
        # gracefully with multiple jobs pending due to
        # job slot limits, since any one job will always
        # leave one more job immediately runnable.
        #
        # note: since nothing gets run until all the dependencies
        # have been removed this should never hit an undefined
        # sub-hash in %queued.
        #
        # if there are no outstanding jobs then wait() immediately
        # return -1 and won't block.

        if( (my $pid = wait) > 0 )
        {
            my $status = $?;

            defined ( my $job = $jobz->{ $pid } )
            or die "$$: unknown pid $pid";

            open my $fh, '>>',  $que->{ pidz }{ $job }
            or croak "$que->{ pidz }{ $job }: $!";

            print $fh $status;

            close $fh;

            # deal with non-zero exits: anything that depends on
            # this job will be skipped; depending on the "abort"
            # attribute value the whole que will be stubbed.

            if( $status )
            {
                print STDERR "\n$$: $job Non-zero exit: $status\n";

                # this will cascade to other jobs that depend on
                # this one, forcing them to be skipped in the que.

                print STDERR "\n$$: Cascading abort skip to dependent jobs";

                $que->{ skip }{ $job } = ABORT;

                # next question: should the whole que abort?

                if( $attrib->{ abort } )
                {
                    print STDERR "\n$$: Aborting further job startup.\n";

                    $que->{ failure }
                    = "Nonzero exit from $job ($pid)";
                }
                else
                {
                    print STDERR "\n$$: Noabort in effect, continuing que";
                }
            }
            else
            {
                print "$$: Successful: $job ($pid).\n"
                if $print_progress;
            }

            $mgr->complete( $job );

            delete $jobz->{ $pid };

            ++$slots;

            print "$$: Currently running: ", scalar values %$jobz, "\n"
            if( $print_detail );
        }
    }

    print $attrib->{ validate }
    ? "$$: Validation Completed."
    : "$$: Execution Completed."
    ;

    # avoid running the que multiple times. simpler to
    # catch this at the beginning since it has fewer
    # side effects.

    $que->{ executed } = 1;

    # die or hand back zero...

    $que->{ failure } ? -1 : 0
}

# keep the use pragma happy

1

__END__

=pod

=head1 Name

Parallel::Depend
Parallel::Depend

=head1 Synopsis

Single argument is assumed to be a schedule, either newline
delimited text or array referent:

	my $que = Parallel::Depend->prepare( "schedule one item per line" );
	my $que = Parallel::Depend->prepare( "schedule one item per line" );
	my $que = Parallel::Depend->prepare( [ scedule, one, item, per, array, entry] );
	my $que = Parallel::Depend->prepare( [ scedule, one, item, per, array, entry] );

Multiple items are assumed to be a hash, which much include the
"sched" argument.

	my $que = Scheduler->prepare( sched => $sched, verbose => 1 );

Object can be saved and used to execute the schedule or the schedule
can be executed (or debugged) directly:

	my $que = Parallel::Depend->prepare( @blah );
	my $que = Parallel::Depend->prepare( @blah );

	$que = $mgr->validate;
	$que = $mgr->execute;

or just:

	Parallel::Depend->prepare( sched => $depend )->validate;
	Parallel::Depend->prepare( sched => $depend )->validate;
	Parallel::Depend->prepare( sched => $depend, verbose => 1  )->execute;
	Parallel::Depend->prepare( sched => $depend, verbose => 1  )->execute;

	Parallel::Depend->prepare( $string_schedule )->validate->execute;
	Parallel::Depend->prepare( $string_schedule )->validate->execute;

If the $que object returned by prepare is kept then it can
be used to update a user area: $que->{user}. The contents are
passed through to sub-queues; aside from that it is
not managed by the $que object and is intended for user-space
data. It is a convienent place for storing configuration
informatin that gets modified as it passes down to subqueues:

	my $que = Parallel::Depend->prepare( $sched );
	my $que = Parallel::Depend->prepare( $sched );

	$que->{ user } = { your config data hash here };

or

	my $que = Parallel::Depend->prepare( sched => $schedule, user => $config );
	my $que = Parallel::Depend->prepare( sched => $schedule, user => $config );


allows for:

	sub somejob
	{
		my $que = shift;

		if( $que->{ user }{ someflag } )
		{
			...
		}
	}

Blessing the value in $que->{ user } can also be convienent.


The scheule is composed of jobs, aliases, groups, and settigngs.

Dependencies between jobs use a ':' syntax much like make:

	job1 : job2

	# and, of course, comments like this one.
	# comments are introduced with hash marks that
	# discard from the first hash to the end of a line.

Job names can include any combination of word characters
(numbers, letters, '_') and are separated from other jobs
or scheduler directves by white space.


Aliases allow multiple jobs to use the same subrouine or attach
command line information to a job:

	job1 = make -wk -c /foo bar bletch;
	job2 = Some::Module::mysub
	job3 = methodname
	job4 = { print "this is a perl code block"; 0 }

	job3 : job2 job1


Will eventually call Some::Module::mysub( 'job2' ) and
$mgr->methodname( 'job3' ); job1 will be passed to the
shell unmodified; job4 will be evaled into an anonymous
subroutine and called without arguments.

Groups are schedules within the schedule:

	group : job1

	group < job2 job3 job4 : job5 job6 >
	group < job3 : job5 >

The main use of groups is to start a number of jobs without
having to hard-code all of the dependencies on the one job
(e.g., downloading a number of tarballs depending on setting
up a destination directory). They are also useful for managing
the degree of parallelism: groups are single jobs to the main
schedule's "maxjobs", so multiple groups can run at once with
their own maxjob limits. The first time "gname <.+>" is seen the
name is inserted as an alias if it hasn't already been seen
(i.e., "group" is a built-in alias). The group method is eventually
called with the group's name as an argument to prepare and
execute the sub-que.

The unalias method returns closures blessed into the que's class
and can be used as a general dispatch mechanism:

	my $sub = $mgr->unalias( 'job1' );

	my $return = $mgr->runjob;
	my $return = $sub->runjob;
	my $return = &$sub;


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


=head1 Arguments

=over 4

=item sched

The schedule can be passed as a single argument (string or
referent) or with the "depend" key as a hash value:

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
prepare as an array referent:

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
an array referent then it will usually be easier to
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

If unalias returns a code referent then it will be used to
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

=head2 boolean overload

Simplifies the test for remaining jobs in execute's while
loop; also helps hide the guts of the queue object from
execute since the test reduces to while( $que ).

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

Catch: If we zero the pidfile here then $q->debug->execute
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

	if( my $que = S::D->prepare( @blah )->debug ) {...}

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


Note: Dependencies between jobs in separate groups is
not yet supported since the group execution begins with
a fork that leaves the sub-que with a private copy of
the inter-job dependency tables. Once the group is
started if all of its jobs are not runnable then it
will deadlock. This is currently checked in the group
method by calling debug first:

    $mgr->subque(...)->debug->execute;

which will croak on a deadlock and return non-zero to
the main que.


=head1 Known Bugs

The block-eval of code can yield all sorts of oddities
if the block has side effects (e.g., exit()). The one-
line format also imposes some strict limits on blocks
for now.  In any case, caveat scriptor...

test.pl has a lot of catching up to do on the code. For
now it is best used to check for bugs in the handling of
basic schedule syntax than all of the unalias optins.

=head1 Author

Steven Lembark, Workhorse Computing
lembark@wrkhors.com

=head1 Copyright

(C) 2001-2002 Steven Lembark, Workhorse Computing

This code is released under the same terms as Perl istelf. Please
see the Perl-5.8 distribution (or later) for a full description.

In any case, this code is release as-is, with no implied warranty
of fitness for a particular purpose or warranty of merchantability.

=head1 See Also

perl(1)

perlobj(1) perlfork(1) perlreftut(1)

Other scheduling modules:

Schedule::Parallel(1) Schedule::Cron(1)

=cut
