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

our $AUTOLOAD = '';

AUTOLOAD
{
    my ( $mgr, $job ) = @_;

    my $i       = rindex $AUTOLOAD, ':';
    my $name    = substr $AUTOLOAD, ++$i;

    print STDOUT "stdout from $name ($job)($mgr)\n";
    print STDERR "stderr from $name ($job)($mgr)\n";

    "$name ( $job )"
}

unlink @pathz;

plan tests => 8 + 4 * @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    autoload    => 1,

    force   => 1,
    maxjob  => 0,
    nofork  => 1,

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    verbose => $ENV{ VERBOSE }  || 1,
    debug   => $ENV{ DEBUG }    || '',

    sched   => <<'END',

hak % nada
foo = outer

pass1 < hak   % one                 > # un-nested group
pass1 < bar   = one                 > # un-nested group
pass1 < bar   : foo                 > # un-nested group

pass3 < hak   % three               > # group with nesting
pass3 < bar   = three               > # group with nesting
pass3 < foo   = middle              > # group with nesting
pass3 < pass2 : foo                 > # group with nesting
pass3 < bar   : pass2               > # group with nesting

pass3 < pass2 < hak % two       >   > # nested group
pass3 < pass2 < bar = two       >   > # nested group
pass3 < pass2 < foo = inner     >   > # nested group
pass3 < pass2 < foo : bar       >   > # nested group

pass3 : pass1

END
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

eval
{
    $mgr->execute;

    1
}
or BAIL_OUT "Failed execution: $@";

ok $$mgr eq 'foobar', "Manager object contents unmolested";

for( @pathz )
{
    ok -e "$tmpdir/$_" ,    "Existing:  $_";

    /pass\d\.err$/
    ? ok ! -s _,            "Zero-size: $_"
    : ok -s _,              "Non-empty: $_"
    ;
}

my $que = $mgr->queue;

ok ! $que->{ namespace },    '$que->{ namespace } localized';

ok ! exists $que->{ forkz }, '$que->{ forkz  } localized';

ok ! % { $que->{ before } }, '$que->{ before } consumed';
ok ! % { $que->{ after  } }, '$que->{ after  } consumed';

# avoid leaving cruft on the filesystem

#unlink @pathz;

0

__END__
