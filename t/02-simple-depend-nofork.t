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

sub foo
{
    print STDOUT "stdout from foo\n";
    print STDERR "stderr from foo\n";

    'foo'
}

sub bar
{
    print STDOUT "stdout from bar\n";
    print STDERR "stderr from bar\n";

    'bar'
}


plan tests => 8 + 4 * @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    sched   => 'foo : bar',

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    nofork  => 1,
    force   => 1,
    verbose => 1,
);

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

ok ! $mgr->execute, 'Execute returns false';

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

