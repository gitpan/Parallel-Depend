package Tesify;

use strict;
use base qw( Parallel::Depend );

use Test::More;
use FindBin qw( $Bin );

my $module  = 'Parallel::Depend';
my $tmpdir  = $Bin . '/../tmp';

# methods in Parallel::Depend.

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

    autoload
    debug
    fork_ttys
    maxjobs
    nofork
    verbose
);

plan tests  => 7 + @methodz;

use_ok $module;

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

# simple schedule: blort runs after foo, 
# bar runs after blort without forking, 
# regardless of whether it ran before or
# seems to have running jobs (force) 
# with extra verbosity.

my $mgr = bless \( $a = 'as you like it' ), __PACKAGE__;

eval
{
    $mgr->prepare
    (
        rundir  => "$tmpdir/run",
        logdir  => "$tmpdir/log",

        nofork  => 1,
        force   => 1,
        verbose => 2,

        debug   => 1,

        sched   =>
        q
        {
            blort  : foo
            bar    : blort
        },
    )
}
or BAIL_OUT "Prepare: $@";

# this may be more than you want to know :-)
#
# the active queue is localized for the current
# namespace running. this checks that the jobs
# running after or before each job match what is
# expected for a simple schedule (i.e., that the
# que guts are not botched).

my $que = eval { $mgr->queue }
or BAIL_OUT "Queue not installed: $@";

my $beforz  = $que->{ before };
my $afterz  = $que->{ after  };

ok $afterz->{ '', 'foo' }[0]   eq "$;blort",    'blort follows foo';
ok $afterz->{ '', 'blort' }[0] eq "$;bar",      'bar follows blort';

ok ! @{ $afterz->{ '', 'bar' } },               'nothing follows bar';

ok "$;blort" ~~ $beforz->{ '', 'bar' },         'blort is before bar';
ok "$;foo"   ~~ $beforz->{ '', 'blort' },       'foo is before blort';

ok ! $beforz->{ '', 'foo' },                    'nothing is before foo';

0

__END__
