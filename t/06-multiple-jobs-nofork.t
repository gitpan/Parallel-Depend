package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use Devel::Size     qw( size total_size );
use Scalar::Util    qw( looks_like_number );

use Parallel::Depend::Util qw( log_message );

my $tmpdir  = $FindBin::Bin . '/../tmp';

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

    nofork  => 1,
    force   => 1,
    verbose => 1,

    debug   => 0,
);

my $que = $mgr->active_queue;

log_message 'Queue structure size: ' . total_size $que;

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
    ok $pid == $$,              "$job PID is this process($pid != $$)";
    ok '0' eq $exit,            "$job exit is zero ($exit)";
}

# avoid leaving this much cruft on the filesystem.

unlink @pathz;

0

__END__
