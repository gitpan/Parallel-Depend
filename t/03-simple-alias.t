package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use FindBin qw( $Bin );

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my @pathz =
(
    "$tmpdir/run/$base.foo.run",
    "$tmpdir/log/$base.foo.out",
    "$tmpdir/log/$base.foo.err",

    "$tmpdir/run/$base.bar.run",
    "$tmpdir/log/$base.bar.out",
    "$tmpdir/log/$base.bar.err",
);

sub bletch
{
    my ( $mgr, $job ) = @_;

    print STDOUT "stdout from bletch ($job)($mgr)\n";
    print STDERR "stderr from bletch ($job)($mgr)\n";

    "Handled: $job"
}

plan tests => 7 + 4 * @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

########################################################################
# add an alias to the schedule:
#   foo = bletch
#   bar = bletch
#
# will call $mgr->bletch ( 'foo' ) or ...( 'bar' ) instead
# of looking for a 'foo' or 'bar' method in the object.

my $mgr = $obj->prepare
(
    sched   => <<'END',

foo : bar

foo = bletch
bar = bletch

END

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    nofork  => 1,
    force   => 1,
    verbose => 2,

    debug   => 1,
)
or BAIL_OUT 'Queue failes prepare';

ok "$mgr" eq "$obj", "Prepare with existing object";

ok $$mgr eq 'foobar', "Manager object contents unmolested";

for( @pathz )
{
    ok   -e  , "$_ exists";

    /run$/
    ? ok   -s _, "$_ non-empty"
    : ok ! -s _, "$_ zero size"
    ;
}

eval 
{
    $mgr->execute;
    1
}
or BAIL_OUT 'Queue failes execution';

ok $$mgr eq 'foobar', "Manager object contents unmolested";

for( @pathz )
{
    ok -e  , "Found: $_";
    ok -s _, "Non-empty: $_";
}

my $que = $mgr->queue;

ok ! $que->{ namespace },    '$que->{ namespace } empty';

ok ! exists $que->{ forkz }, '$que->{ forkz } localized';

ok ! % { $que->{ before } }, '$que->{ before } consumed';
ok ! % { $que->{ after  } }, '$que->{ before } consumed';

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__

