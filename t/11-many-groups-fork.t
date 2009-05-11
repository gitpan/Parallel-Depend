package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use Parallel::Depend::Util qw( log_message log_error );

$ENV{ EXPENSIVE_TESTS }
or plan skip_all => 'EXPENSIVE_TESTS envoironment variable not set';

if( $^P )
{
    @ARGV
    or die "Bogus $0: missing fork tty list";
}

my $tmpdir  = $FindBin::Bin . '/../tmp';

my @sched
= do
{
    map
    {
        (
            "$_ : # avoid inter-group dependencies",
            "$_ < foo :             >",
            "$_ < foo = frobnicate  >",
        )
    }
    ( 'aa' .. 'zz' )
};

sub frobnicate
{
    my ( $mgr, $job ) = @_;

    my $que     = $mgr->active_queue;
    my $nspace  = $que->{ namespace };

    my $message = "$job($nspace)";

    log_message $message;

    $message
}

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    sched   => \@sched,

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    force   => 1,
    verbose => 1,
    debug   => 0,

    nofork      => '',
    fork_ttys   => [ @ARGV ],
    maxjobs     => 0,
);

my $que = $mgr->active_queue;

my @pathz   = map { @$_ } values %{ $que->{ files } };

plan tests => 2 * @pathz;

$mgr->execute
and BAIL_OUT "Execution failed (non-zero return)";

for( @pathz )
{
    ok -e,          "Existing:  $_";

    /[.]err$/
    ? ok ! -s _,    "Zero-size: $_"
    : ok   -s _,    "Non-empty: $_"
}

0

__END__
