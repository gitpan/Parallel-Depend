package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use FindBin qw( $Bin );

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my @subz    
= do
{
    my $a   = 'z';

    map { ++$a } ( 1 .. 2 );

};

my @pathz
= map
{
    (
        "$tmpdir/log/$base.superjob._.$_.out",
        "$tmpdir/log/$base.superjob._.$_.err",
        "$tmpdir/run/$base.superjob._.$_.run",
    )
}
@subz;

sub prior
{
    # none of the paths should exist at this point: 
    # they have not been added to the scheule yet.

    ok ! -e, "Missing: $_"
    for @pathz;

    return
}

sub after
{
    # at this point everything handled via precheck
    # should exist.

    ok -s, "Non-empty: $_"
    for @pathz;

    return
}

sub superjob
{
    my $mgr = shift;

    my @sched
    = map
    {
        (
            "$_ = subjob",
            "$_ :",
        )
    }
    @subz;

    $mgr->ad_hoc( \@sched );

    return
}

sub subjob
{
    my ( $mgr, $job ) = @_;

    print STDOUT "Subjob: $job";
    print STDERR "Subjob: $job";

    return
}

plan tests => 2 * @pathz;

# avoid cruft files.

unlink @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    nofork  => 1,
    force   => 1,
    verbose => 2,

    debug   => '',

    sched   =>
    q
    {
        superjob    : prior
        after       : superjob
    },
);

$mgr->execute;

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__
