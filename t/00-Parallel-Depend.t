
use strict;

use Test::More;

my $module  = 'Parallel::Depend';

my @methodz
= qw
(
    mgr_que
    install_que
    remove_que
    failure
    queued
    ready
    depend
    dequeue
    complete
    precheck
    runjob
    unalias
    shellexec
    group
    subque
    construct
    new
    extract_attrib
    extract_alias
    extract_group
    extract_depend
    prepare
    validate
    execute
);

plan tests  => 1 + @methodz;

use_ok $module;

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

0

__END__
