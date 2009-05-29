########################################################################
# housekeeping
########################################################################

package Parallel::Depend::Queue;

use v5.10;
use strict;
use vars qw( $job_id_sep );

use File::Basename;

use Parallel::Depend::Util  qw( log_fatal log_message );
use Scalar::Util            qw( blessed );
use Symbol                  qw( qualify_to_ref );

########################################################################
# package variables
########################################################################

our $VERSION    = v1.0.0;

my $empty       = {};

*job_id_sep     = \"$;";

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
    # return the existing que if it exists otherwise
    # install a que if one is supplied otherwise die.
    
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
        # used within _attrib, _alias to separate out
        # individual jobs. contents are managed by the
        # $mgr object.

        namespace   => '',

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
        # prefix is added before logdir and rundir entries
        # with the name to avoid basename collisions for jobs
        # aliased in mutiple groups.

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

for my $type ( qw( alias attrib ) )
{
    my $get = qualify_to_ref $type;
    my $has = qualify_to_ref 'has_' . $type;

    my $key = '_' . $type;

    *$get
    = sub
    {
        my ( $que, $contxt ) = @_;

        $contxt //= $que->{ namespace };

        $que->{ $key }{ $contxt }
        ||= +{ %{ $que->{ $type } } }
    };

    *$has
    = sub
    {
        my ( $que, $subkey ) = @_;

        $subkey ~~ $que->{ $type }
    };
}

########################################################################
# mainly used to merge attributes from jobs with the currently
# context's attributes. 

sub merge_attrib
{
    my $que     = shift;

    my $context
    = 2 == @_
    ? join $job_id_sep, @_
    : 1 == @_ 
    ? shift
    : log_fatal 'Bogus job_attrib: invalid argument count', \@_
    ;

    my $global  = $que->attrib;

    if( my $local = $que->{ _attrib }{ $context } )
    {
        +{
            %$global,
            %$local,
        }
    }
    else
    {
        $global
    }
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

# keep require happy

1

__END__
