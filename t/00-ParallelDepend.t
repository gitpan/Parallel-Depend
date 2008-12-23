
use strict;
use Test::More;

use Cwd             qw( getcwd );

my @methodz =
qw
(
    log_format
    mgr_que
    install_que
    failure
    queued
    ready
    depend
    dequeue
    complete
    status
    alias
    precheck
    runjob
    unalias
    shellexec
    sched_list
    group
    subque
    construct
    new
    prepare
    validate
    execute
);

my $module  = 'Parallel::Depend';

my $tmpdir  = getcwd . '/tmp';

-d $tmpdir || mkdir $tmpdir, 0777
or die "Failed mkdir '$tmpdir': $!";

plan tests => 3 + 2 * @methodz;

use_ok $module, "$module' is usable";

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

my $sched
= qq
{
    var_dir   % $tmpdir
    verbose   % 99

    foo :
    foo = bar

    fee < fie : >
    fee < foe : >
    fee < fum : >

    Bletch::Blort::blah : foo

    foo : fee

    fee :
};

my $queue   = $module->prepare
(
    verbose => 2,
    rundir  => $tmpdir,,
    logdir  => $tmpdir,
    sched   => $sched,
);

ok $queue, 'Prepare returns a queue';

ok $queue->isa( $module ), "Queue object is a $module";

ok $queue->can( $_ ), "Queue object can '$_'"
for @methodz;

unlink glob "$tmpdir/*";
rmdir $tmpdir;

__END__
