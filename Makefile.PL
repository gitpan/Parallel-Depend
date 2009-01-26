use v5.10.0;
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile
(
	NAME	=> "Parallel::Depend",

    VERSION	=> '3.06',

	ABSTRACT	=> <<'END',
Parallel process startup with dependencies and restart.
Manager object can dispatch perl methods or functions,
shell, or code blocks from the schedule.
END

	AUTHOR     	=> 'Steven Lembark <lembark@wrkhors.com>',
	PREREQ_PM	=> 
	{
        # core modules: whatever came with perl
        # should be usable

        autodie         => 0,
        feature         => 0,
        strict          => 0,
        vars            => 0,
        warnings        => 0,

        Benchmark       => 0,
        Carp            => 0,
        Data::Dumper    => 0, 
        Date::Format    => 0,
        File::Basename  => 0,
        Scalar::Util    => 0,
        Storable        => 0,
        Symbol          => 0,

        # these aren't core, the versions matter.

        FindBin         => 1.37,
        MIME::Lite      => 3.0,
	},
);
