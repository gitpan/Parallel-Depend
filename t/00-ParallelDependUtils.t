
use strict;
use Test::More;

use Cwd             qw( getcwd );

my @utilz =
qw
(
    log_message
    log_error
    log_format

    handle_que_args

    send_mail
    nastygram

    localpath
    checkdir

    slurp
    splat
);

my $module  = 'Parallel::Depend::Utilities';

plan tests  => 1 + 2 * @utilz;

use_ok $module, "$module' is usable";

ok $module->can( $_ ), "$module can '$_'"
for @utilz;

ok __PACKAGE__->can( $_ ), "Exported: '$_'"
for @utilz;

__END__
