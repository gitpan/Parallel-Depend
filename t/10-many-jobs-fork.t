package Testify;

use strict;
use base    qw( Parallel::Depend );

use Devel::Size qw( size total_size );
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

log_error "Be forwarned: this will generate 52_728 log+run files!!!!";

my @sched
= do
{
    my $last    = '';

    map
    {
        my $group   = $_;

        (
            "$group : ",
            map
            {
                (
                    "$group < $_ :              >",
                    "$group < $_ = frobnicate   >",
                )
            }
            ( 'aa' .. 'zz' )
        )
    }
    ( 'a' .. 'z' )
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
    debug   => 1,

    maxjob      => 8,
    nofork      => '',
    fork_ttys   => [ @ARGV ],

);

my $que = $mgr->active_queue;

log_error 'Queue structure size: ' . total_size $que;

my @pathz   = map { @$_ } values %{ $que->{ files } };

plan tests => 5 + 2 * @pathz;

ok "$mgr" eq "$obj",    "Prepare with existing object";
ok $$mgr eq 'foobar',   "Manager object contents unmolested";

ok ! $mgr->execute, 'Execute returns false';

ok $$mgr eq 'foobar', "Manager object contents unmolested";
ok ! $que->{ namespace },    '$que->{ namespace } empty';

for( @pathz )
{
    ok -e,          "Existing:  $_";

    /[.]err$/
    ? ok ! -s _,    "Zero-size: $_"
    : ok   -s _,    "Non-empty: $_"
}

# avoid leaving this much cruft on the filesystem.

unlink @pathz;

0

__END__
