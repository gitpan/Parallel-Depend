
use strict;

use Test::More;
use FindBin qw( $Bin );

my $module  = 'Parallel::Depend';
my $tmpdir  = $Bin . '/../tmp';

# methods in Parallel::Depend.

my @methodz
= qw
(
    initial_queue
    active_queue
    active_attrib
    active_alias
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

plan tests  => 9 + @methodz;

use_ok $module;

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

# simple schedule: blort runs after foo, 
# bar runs after blort without forking, 
# regardless of whether it ran before or
# seems to have running jobs (force) 
# with extra verbosity.

my $mgr
= eval
{
    $module->prepare
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
};

ok $mgr, "Schedule prepares ($@)";

# this may be more than you want to know :-)
#
# the active queue is localized for the current
# namespace running. this checks that the jobs
# running after or before each job match what is
# expected for a simple schedule (i.e., that the
# que guts are not botched).

my $que = $mgr->active_queue;

ok $que, "Manager has a queue";

my $beforz  = $que->{ before };
my $afterz  = $que->{ after  };

ok $afterz->{ '', 'foo' }[0]   eq "$;blort",    'blort follows foo';
ok $afterz->{ '', 'blort' }[0] eq "$;bar",      'bar follows blort';

ok ! @{ $afterz->{ '', 'bar' } },               'nothing follows bar';

ok "$;blort" ~~ $beforz->{ '', 'bar' },         'blort is before bar';
ok "$;foo"   ~~ $beforz->{ '', 'blort' },       'foo is before blort';

ok ! %{ $beforz->{ '', 'foo' } },               'nothing is before foo';

0

__END__
