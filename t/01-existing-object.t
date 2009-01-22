package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use FindBin qw( $Bin );

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

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my @expect =
(
    "$tmpdir/run/$base-foo.pid",
    "$tmpdir/log/$base-foo.out",
    "$tmpdir/log/$base-foo.err",
);

-d $tmpdir || mkdir $tmpdir, 0777
or die "Failed mkdir '$tmpdir': $!";

unlink glob "$tmpdir/*/*";

plan tests => 2 + @methodz + 2 * @expect;

my $obj     = bless [], __PACKAGE__;

ok $obj->can( $_ ), "Object can '$_'"
for @methodz;

my $mgr = $obj->prepare
(
    sched   => 'foo:',
    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",
);

ok "$mgr" eq "$obj", "Prepare with existing object";

sub foo
{
    # pub something into the out and err files.
    # return false to keep execute happy.

    print STDOUT $$;
    print STDERR $$;

    return
}

ok ! $mgr->execute, 'Execute returns false';

for( @expect )
{
    ok -e  , "Found: $_";
    ok -s _, "Non-empty: $_";
}

unlink glob "$tmpdir/*/*";
rmdir  glob "$tmpdir/*";
rmdir $tmpdir;

__END__
