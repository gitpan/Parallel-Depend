
use strict;

use Test::More;

my $module  = 'Parallel::Depend';

my @methodz
= qw
(
    initial_queue
    active_queue
    active_attrib
    active_alias
    run_message
    prepare
    precheck
    validate
    unalias
    runjob
    shellexec
    queued
    runnable
    dequeue
    complete
    execute
);

plan tests  => 1 + @methodz;

use_ok $module;

ok $module->can( $_ ), "$module can '$_'"
for @methodz;

0

__END__
