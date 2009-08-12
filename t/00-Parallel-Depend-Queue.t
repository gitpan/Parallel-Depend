
use strict;

use Test::More;
use FindBin qw( $Bin );

my $module  = 'Parallel::Depend::Queue';
my $tmpdir  = $Bin . '/../tmp';

# methods in Parallel::Depend.

my @methodz
= qw
(
    construct
    new
    init
    merge_attrib
    set_job_attrib
);

my @keyz
= qw
(
    _alias
    _attrib

    after
    before
    files
    prefix
    skip
);

plan tests  => 5 + @keyz + @methodz;

use_ok $module;

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

# simple structure: make sure it's all there
# after the thing gets constructed.

my $que
= eval
{
    $module->new
    (
        qw( fee fie foe fum ),

        rundir  => "$tmpdir/run",
        logdir  => "$tmpdir/log",

        nofork  => 1,
        force   => 1,
        verbose => 2,
        debug   => 1,
    )
}
or BAIL_OUT "Queue const fails: $@";

ok exists $que->{ $_ }, "Que has '$_'"
for @keyz;

my $attrz   = $que->{ _attrib }{ '' };

ok 'fee' ~~ $attrz, "Found attribute 'fee'";
ok 'foe' ~~ $attrz, "Found attribute 'foe'";

ok 'fie' eq $attrz->{ fee }, "Attribute fee is 'fie' ($attrz->{ fee })";
ok 'fum' eq $attrz->{ foe }, "Attribute foe is 'fum' ($attrz->{ foe })";

0

__END__
