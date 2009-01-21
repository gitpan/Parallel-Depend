package Testify;

use strict;
use base    qw( Parallel::Depend );

use Test::More;

use Cwd     qw( getcwd );

my @methodz =
qw
(
    queued
    ready
    depend
    dequeue
    complete
    restart
    force
    noabort
    verbose
    debug
    nofork
    rundir
    logdir
    jobz
    pidz
    failure
    precheck
    runjob
    unalias
    shellexec
    group
    subque
    prepare
    validate
    execute
);

my $tmpdir  = getcwd . '/tmp';

-d $tmpdir || mkdir $tmpdir, 0777
or die "Failed mkdir '$tmpdir': $!";

unlink glob "$tmpdir/*";

plan tests => 1 + @methodz;

my $obj     = bless [], __PACKAGE__;

ok $obj->can( $_ ), "Object can '$_'"
for @methodz;

my $que = $obj->prepare
(
    sched   => 'foo:',
    rundir  => $tmpdir,,
    logdir  => $tmpdir,
);

ok "$que" eq "$obj", "Prepare with existing object";

unlink glob "$tmpdir/*";
rmdir $tmpdir;

__END__
