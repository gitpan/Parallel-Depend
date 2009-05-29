package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use Test::More;

use Parallel::Depend::Util qw( log_message );

$ENV{ EXPENSIVE_TESTS }
or plan skip_all => 'EXPENSIVE_TESTS envoironment variable not set';

my $tmpdir  = $FindBin::Bin . '/../tmp';

my @sched
= do
{
    my $last    = '';
    my $i       = '0000';

    map
    {
        my $group   = $_;
        my $depend  = "$group : $last";
        $last       = $group;

        (
            $depend =>
            map
            {
                my $subgroup   = $_;

                (
                    "$group < $subgroup : >",
                    map
                    {
                        my $job = ++$i;

                        map
                        {
                        (
                            "$group < $subgroup < $job-$_ :             > >",
                            "$group < $subgroup < $job-$_ = frobnicate  > >", 
                        )
                        }
                        ( 'a' .. 'z' )
                    }
                    ( '000' .. '009' )
                )
            }
            ( '00' .. '09' )
        )
    }
    ( '0' .. '9' )
};

sub frobnicate
{
    my ( $mgr, $job ) = @_;

    print STDOUT $job, "\n";

    $job
}

my $obj     = bless \(my $a = 'foobar'), __PACKAGE__;

my $mgr = $obj->prepare
(
    sched   => \@sched,

    rundir  => "$tmpdir/run",
    logdir  => "$tmpdir/log",

    maxjobs => $ENV{ MAXJOB } || 8,

    force   => 1,
    verbose => $ENV{ VERBOSE } || 1,
    debug   => $ENV{ DEBUG   } || '',

    fork_ttys   => '',
    nofork      => '',
);

my $que = $mgr->queue;

my @pathz   = map { @$_ } values %{ $que->{ files } };

plan tests => 2 * @pathz;

$mgr->execute
and BAIL_OUT "Execution failed (non-zero return)";

for( @pathz )
{
    ok -e,          "Existing:  $_";

    /[.]err$/
    ? ok ! -s _,    "Zero-size: $_"
    : ok   -s _,    "Non-empty: $_"
}

# avoid leaving this much cruft on the filesystem.

unlink @pathz;

0

__END__
