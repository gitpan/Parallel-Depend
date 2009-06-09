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

    map { ++$a } ( 1 .. 10 );

};

my @pathz = 
map
{
    (
        "$tmpdir/log/$base.outer._.inner._.$_.out",
        "$tmpdir/log/$base.outer._.inner._.$_.err",
        "$tmpdir/run/$base.outer._.inner._.$_.run",
    )
}
@subz;

sub nil {}

sub outer
{
    my $mgr = shift;

    $mgr->ad_hoc
    (
        'verbose    ~ 2',
        'inner      ~ ad_hoc',
        'inner      :',
    );

    return
}

sub inner
{
    my $mgr = shift;

    my $seq = '000';

    my @sched
    = map
    {
        ++$seq;

        (
            "$_ ~ verbose 0",
            "$_ = nil",
            "$_ :",
        )
    }
    @subz;

    $mgr->ad_hoc( \@sched );

    return
}

plan tests => scalar @pathz;

# avoid cruft files.

unlink @pathz;

-e and BAIL_OUT "Cruft file: $_"
for @pathz;

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    nofork  => 1,
    force   => 1,
    verbose => 2,

    debug   => $ENV{ DEBUG },

    sched   =>
    q
    {
        outer    ~ ad_hoc
        outer    ~ verbose 2

        outer   :
    },
);

$mgr->execute;

ok -e, "Existing: $_" for @pathz;

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__
