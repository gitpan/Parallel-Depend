package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use Scalar::Util    qw( looks_like_number );

use Parallel::Depend::Util qw( log_message log_error );

if( $^P )
{
    @ARGV
    or die "Bogus $0: missing fork tty list";
}

my $tmpdir  = $FindBin::Bin . '/../tmp';

log_error "\nPhorkatosis caused by this test is intentional";

my @sched
= do
{
    map
    {
        (
            "$_ :               ",
            "$_ = frobnicate    ",
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

    maxjobs     => 8,
    nofork      => 0,
    fork_ttys   => [ @ARGV ],
);

my $que = $mgr->active_queue;

my @pathz   = map { @$_ }       values %{ $que->{ files } };
my @runz    = grep/[.]run$/,    @pathz;

plan tests => 2 * @pathz + 4 * @runz;

$mgr->execute
and BAIL_OUT "Execution failed (non-zero return)";

for( @pathz )
{
    ok -e,          "Existing:  $_";

    /[.]err$/
    ? ok ! -s _,    "Zero-size: $_"
    : ok   -s _,    "Non-empty: $_"
}

my @a   = ();

for( @runz )
{
    my ( $count, $job, $pid, $exit )
    = do
    {
        open my $fh, '<', $_;

        local $/    = "\n";

        chomp ( @a = <$fh> );

        ( scalar @a, @a[1, 2,-1] )
    };

    ok $count >= 6,             "$job was dispatched ($count)";
    ok looks_like_number $pid,  "$job PID is numeric ($pid)";
    ok $pid != $$,              "$job PID is not this process($pid != $$)";
    ok '0' eq $exit,            "$job exit is zero ($exit)";
}

# avoid leaving this much cruft on the filesystem.

unlink @pathz;

__END__
