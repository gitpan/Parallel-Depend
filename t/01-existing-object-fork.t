########################################################################
# make sure that the manager object is left alone during the 
# process and that the que structure is populated correctly.
########################################################################

package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use FindBin qw( $Bin );

# test an existing object without forking (see also notes
# in 01*fork.t).

my @methodz
= qw
(
    run_message
    prepare
    ad_hoc
    precheck
    validate
    unalias
    runjob
    shellexec
    queued
    runnable
    dequeue
    complete
    execute
);

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my @pathz =
(
    "$tmpdir/run/$base.foo.run",
    "$tmpdir/log/$base.foo.out",
    "$tmpdir/log/$base.foo.err",
);

sub foo
{
    # put something into the out and err files.
    # return false to keep execute happy.

    print STDOUT "Hello\n";
    print STDERR "world\n";

    return 0
}

plan tests => 8 + @methodz + 4 * @pathz;

# avoid stale data screwing up the tests.

unlink @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

ok $obj->can( $_ ), "Object can '$_'"
for @methodz;

my $mgr = $obj->prepare
(
    sched   => 'foo :',

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    force   => 1,
    verbose => 2,

    nofork  => '',
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
