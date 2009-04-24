package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use FindBin qw( $Bin );

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my @pathz
= qw
(
    log/05-nested-group-nofork.pass3.out
    log/05-nested-group-nofork.pass3.err
    log/05-nested-group-nofork.pass1.out
    log/05-nested-group-nofork.pass1.err
    log/05-nested-group-nofork.pass3.foo.out
    log/05-nested-group-nofork.pass3.foo.err
    log/05-nested-group-nofork.pass3.bar.out
    log/05-nested-group-nofork.pass3.bar.err
    log/05-nested-group-nofork.pass3.pass2.out
    log/05-nested-group-nofork.pass3.pass2.err
    log/05-nested-group-nofork.pass3.pass2.foo.out
    log/05-nested-group-nofork.pass3.pass2.foo.err
    log/05-nested-group-nofork.pass3.pass2.bar.out
    log/05-nested-group-nofork.pass3.pass2.bar.err
    log/05-nested-group-nofork.pass1.foo.out
    log/05-nested-group-nofork.pass1.foo.err
    log/05-nested-group-nofork.pass1.bar.out
    log/05-nested-group-nofork.pass1.bar.err
    run/05-nested-group-nofork.pass3.run
    run/05-nested-group-nofork.pass1.run
    run/05-nested-group-nofork.pass3.foo.run
    run/05-nested-group-nofork.pass3.bar.run
    run/05-nested-group-nofork.pass3.pass2.run
    run/05-nested-group-nofork.pass3.pass2.foo.run
    run/05-nested-group-nofork.pass3.pass2.bar.run
    run/05-nested-group-nofork.pass1.foo.run
    run/05-nested-group-nofork.pass1.bar.run
);

sub bletch
{
    my ( $mgr, $job ) = @_;

    print STDOUT "stdout from bletch ($job)($mgr)\n";
    print STDERR "stderr from bletch ($job)($mgr)\n";

    "bletch ( $job )"
}

sub blort
{
    my ( $mgr, $job ) = @_;

    print STDOUT "stdout from blort ($job)($mgr)\n";
    print STDERR "stderr from blort ($job)($mgr)\n";

    "blort ( $job )"
}

plan tests => 9 + 4 * @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    sched   => <<'END',

foo = bletch

pass1 < foo : bar       >
pass1 < bar = bletch    >

pass3 < foo : bar                   >
pass3 < bar : pass2                 >
pass3 < bar = blort                 >
pass3 < pass2 < foo : bar       >   >
pass3 < pass2 < foo = blort     >   > 
pass3 < pass2 < bar = bletch    >   >

pass3 : pass1

END

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    nofork  => 1,
    force   => 1,
    verbose => 2,

    debug   => 1,
);

ok "$mgr" eq "$obj", "Prepare with existing object";

ok $$mgr eq 'foobar', "Manager object contents unmolested";

for( @pathz )
{
    ok   -e "$tmpdir/$_" , "Existing:  $_";

    /run$/
    ? ok   -s _, "Non-empty: $_"
    : ok ! -s _, "Zero-size: $_"
    ;
}

ok 1 == ( $mgr->debug( 1 ) ), "Debug set to 1";

ok ! $mgr->execute, 'Execute returns false';

ok $$mgr eq 'foobar', "Manager object contents unmolested";

for( @pathz )
{
    ok -e "$tmpdir/$_" ,    "Existing:  $_";

    /pass\d\.err$/
    ? ok ! -s _,            "Zero-size: $_"
    : ok -s _,              "Non-empty: $_"
    ;
}

my $que = $mgr->active_queue;

ok ! $que->{ namespace },    '$que->{ namespace } empty';

ok ! exists $que->{ forkz }, '$que->{ forkz } localized';

ok ! % { $que->{ before } }, '$que->{ before } consumed';
ok ! % { $que->{ after  } }, '$que->{ before } consumed';

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__
