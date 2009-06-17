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
        "$tmpdir/log/$base.test._.$_.out",
        "$tmpdir/log/$base.test._.$_.err",
        "$tmpdir/run/$base.test._.$_.run",
    )
}
@subz;

my @ad_hoc = 
(
    'verbose % 2',
    map
    {
        (
            "$_ = nil",
            "$_ :",
        )
    }
    @subz
);

sub nil {}

sub test
{
    my $mgr = shift;

    $mgr->ad_hoc( \@ad_hoc );

    my $que     = $mgr->queue;
    my $beforz  = $que->{ before };
    my $afterz  = $que->{ after  };

    $afterz->{ 'test', '_' } == $afterz->{ '', 'test' }
    or BAIL_OUT 'ad_hoc job failed inherit parent after';

    exists $beforz->{ '', 'sanity' }{ 'test', '_' },
    or BAIL_OUT 'sanity failed depend on ad_hoc job';

    return
}

plan tests => scalar @pathz;

# avoid cruft files.

unlink @pathz;

-e and BAIL_OUT "Crufty: $_"
for @pathz;

my $obj     = eval { bless \(my $a = 'foobar'), __PACKAGE__ }
or BAIL_OUT "Failed object creation: $@";

my $mgr
= eval
{
    $obj->prepare
    (
        rundir  => "$tmpdir/run",
        logdir  => "$tmpdir/log",

        nofork  => 1,
        force   => 1,

        verbose => $ENV{ VERBOSE } // 1,
        debug   => $ENV{ DEBUG }   // 0,

        sched   =>
        q
        {
            # check that the sanity job depends
            # on and is enabled by test's ad_hoc
            # group.

            test ~ ad_hoc

            sanity  = PHONY

            sanity  : test
        },
    )
}
or BAIL_OUT "Failed preparation: $@";

$mgr->execute;

ok -e, "Found: $_" for @pathz;

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__
