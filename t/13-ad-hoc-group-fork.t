package Testify;

use strict;
use base    qw( Parallel::Depend );

use File::Basename;
use IO::File;
use Test::More;

use FindBin qw( $Bin );

my $tmpdir  = $Bin . '/../tmp';
my $base    = basename $0, '.t';

my $path    = "$tmpdir/13-results.out";

my $results = IO::File->new( "> $path" )
or BAIL_OUT "> $path: $!";

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

    local $\    = "\n";
    local $,    = "\t";

    $results->printflush( "Non-existant: $_", ! -e )
    for @pathz;

    return
}

sub after
{
    # at this point everything handled via precheck
    # should exist.

    local $\    = "\n";
    local $,    = "\t";

    $results->printflush( "Non-empty: $_", -s )
    for @pathz;

    return
}

# generate a schedule with all of the jobs 
# running in parallel. each of them calls
# subjob with the job name.

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

    # fill the logs with something to 
    # check in after via -s.

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
    verbose => 1,

    debug   => '',

    sched   =>
    q
    {
        verbose     % 1

        superjob    ~ verbose 2
        superjob    ~ ad_hoc

        superjob    : prior
        after       : superjob
    },
);

$mgr->execute;

my @resultz
= do
{
    open $results, '<', $path
    or BAIL_OUT "< $path: $!";

    map { [ split /\t/ ] } <$results>
};

for( @resultz )
{
    my ( $message, $sanity ) = @$_;

    ok $sanity, $message;
}

# avoid leaving cruft on the filesystem

unlink @pathz;

0

__END__
