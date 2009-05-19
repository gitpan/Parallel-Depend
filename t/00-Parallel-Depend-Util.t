
package Testify;

use v5.10.0;
use strict;

use Test::More;

use Symbol  qw( qualify_to_ref );

my $module  = 'Parallel::Depend::Util';

plan tests  => 3;

use_ok $module;

# Check the public @Parallel::Depend::Util::exportz
# for a list of exported subs. 

my $exportz
= do
{
    my $ref = qualify_to_ref 'exportz', $module;

    *{ $ref }{ ARRAY }
}
or BAIL_OUT "No '\@exportz' in '$module'";

for my $pkg ( $module, __PACKAGE__ )
{
    my @missing
    = grep
    {
        $pkg->can( $_ ) ? '' : $_
    }
    @$exportz;

    local $" = ' ';

    @missing
    ? fail "$pkg cannot @missing"
    : pass "$pkg can @$exportz"
}

__END__
