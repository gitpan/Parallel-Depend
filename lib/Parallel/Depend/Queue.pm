########################################################################
# housekeeping
########################################################################

package Parallel::Depend::Queue;

use v5.10;
use strict;
use vars qw( $job_id_sep $nspace_sep );

use File::Basename;

use Parallel::Depend::Util  qw( log_fatal log_message );
use Scalar::Util            qw( blessed );
use Symbol                  qw( qualify_to_ref );

########################################################################
# package variables
########################################################################

our $VERSION    = v1.2.0;

my $empty       = {};

*job_id_sep     = \qq{$;};
*nspace_sep     = \q{.};

my @no_inherit_attrz
= qw
(
    ad_hoc
    alias
);

########################################################################
# public interface
########################################################################

sub new
{
    my $proto   = shift;

    my $que     = $proto->construct;

    $que->init( @_ );

    $que
}

sub construct
{
    my $proto   = shift;

    bless {}, blessed $proto || $proto
}

sub init
{
    # populate the queue structure, load the
    # initial arguments as attributes.
    
    my $que     = shift;

    my $argz    = ref $_[0] ? shift : +{ @_ };

    my $base
    = delete $argz->{ base } || basename $0, '.pl', '.pm', '.t';

    # Notice the lack of 'alias' and 'attrib' in the initial_queue:
    # these are localized during dispatch from the contents of 
    #
    #   local $que->{ attrib } = $que->attrib;
    #   local $que->{ attrib } = $que->attrib( $job_id );

    %$que =
    (
        # defined by the schedule.
        # { prior }{ $job } => jobs that run prior to $job.
        # { after }{ $job } => jobs that run after $job.
        # runnable uses prior; complete uses after.

        before  => {},  # jobs blocked from running.
        after   => {},  # jobs with other jobs following.

        # assembled in prepare to track clean jobs on
        # restart or failed ones during execution, 
        # paths for run, log, err files.

        skip    => {},  # job_id => $reason, 0 => clean.

        # stderr, stdout, runfile paths for each job.
        #
        # prefix used to generate the basenames of 
        # all files.

        prefix  => $base,

        files   => {},  # $job_id => [ run, out, err ]
    );
    
    # global namespace is '', which gets the 
    # initial set of attributes and an empty
    # set of aliases.

    $que->{ _attrib }{ '' } = $argz;
    $que->{ _alias  }{ '' } = {};

    $que
}

########################################################################
# default is a shallow copy of the current 
# context's data.  this allows prepare and 
# ad_hoc calls to use local $que->{ foo } = 
# $que->foo( $new_context ) when preparing or 
# executing the schedule.

for
(
    [ alias   => []                 ],
    [ attrib  => \@no_inherit_attrz ],
)
{
    my ( $type, $purge ) = @$_;

    my $key     = '_' . $type;

    my $get     = qualify_to_ref $type;

    *$get
    = sub
    {
        my ( $que, $nspace ) = @_;

        $nspace //= $que->{ namespace } || '';

        my $a   = $que->{ $key };

        $a->{ $nspace }
        ||= do
        {
            my %b   = %{ $que->{ $type } };

            delete @b{ @$purge };

            \%b
        }
    };
}

sub purge_group
{
    my ( $que, $group ) = @_;

    my $job_id  = $que->job_id( $group );

    my $grp_id  = $que->namespace( $group );

    for( @{ $que }{ qw( _attrib _alias ) } )
    {
        delete @{ $_ }{ ( $grp_id, $job_id ) };
    }

    return
}

########################################################################
# these keep $job_id_sep and $nspace_sep private.

sub namespace
{
    my $que = shift;

    'namespace' ~~ $que
    or log_fatal 'Bogus namespace: queue missing namespace';

    defined ( my $nspace  = $que->{ namespace } )
    or log_fatal "Damaged queue: undefined namespace", $que;

    if( $nspace && @_ )
    {
        join $nspace_sep, $que->{ namespace }, $_[0]
    }
    elsif( @_ )
    {
        $_[0]
    }
    else
    {
        $nspace
    }
}

sub job_id
{
    my $que = shift;

    @_ 
    ? join $job_id_sep, $que->{ namespace }, $_[0]
    : $que->{ namespace } . $job_id_sep
}

sub job_id_split
{
    my ( $que, $job_id ) = @_;

    $job_id //= $que->{ job_id }
    or log_fatal 'Bogus job_id_split: missing job_id';

    split /$job_id_sep/o, $job_id, 2
}

sub job_name
{
    my $que = shift;

    my $job = shift // $que->{ job }
    or log_fatal 'Bogus job_name: missing job';

    my $i = index $job, $job_id_sep;

    $i < 0
    ? $job
    : substr $job, ++$i
}

sub resolve_alias
{
    my $que     = shift;
    my $job     = $que->job_name( @_ );

    my $alias
    = $que->{ alias }{ $job }
    // $que->attrib->{ alias }
    // $job
    ;

    wantarray
    ? ( $alias => $job )
    : $alias
}


########################################################################
# mainly used to merge attributes from jobs with the currently
# context's attributes. 

sub merge_attrib
{
    my $que         = shift;

    my ( $alias, $name ) = $que->resolve_alias( @_ );
     
    my $nspace      = $que->namespace;

    my $attrz       = $que->{ _attrib };

    my $global      = $que->attrib;
    my $alias_attrz = $attrz->{ $nspace, $alias } || $empty;
    my $job_attrz   = $attrz->{ $nspace, $name  } || $empty;

    wantarray
    ?  ( %$global, %$alias_attrz, %$job_attrz )
    : +{ %$global, %$alias_attrz, %$job_attrz }
}

sub set_job_attrib
{
    my $que     = shift;

    my $job     = shift 
    or log_fatal "Bogus set_job_attrib: missing job argument";

    my $nspace  = $que->{ namespace };

    my $attrz   = $que->{ _attrib }{ $nspace, $job } ||= {};

    my $argz    = ref $_[0] ? shift : +{ @_ };

    while( my ( $name, $value ) = each %$argz )
    {
        defined $value
        ? $attrz->{ $name } = $value
        : delete $attrz->{ $name }
    }

    return
}

sub get_job_attrib
{
    my $que     = shift;

    my $job     = shift 
    or log_fatal "Bogus set_job_attrib: missing job argument";

    my $nspace  = $que->{ namespace };

    my $attrz   = $que->{ _attrib }{ $nspace, $job }
    or return;

    wantarray
    ? @{ $attrz }{ @_ }
    : $attrz->{ $_[0] }
}

# keep require happy

1

__END__
