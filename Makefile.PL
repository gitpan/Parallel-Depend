use v5.10.0;
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile
(
	NAME	=> "Parallel::Depend",

    VERSION	=> '4.02',

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

        autodie                 => 0,
        strict                  => 0,
        subs                    => 0,
        vars                    => 0,

        Benchmark               => 0,
        Carp                    => 0,
        Cwd                     => 0,
        Data::Dumper            => 0,
        Date::Format            => 0,
        File::Basename          => 0,
        File::Spec::Functions   => 0,
        FindBin                 => 0,
        IO::File                => 0,
        List::Util              => 0,
        Scalar::Util            => 0,
        Storable                => 0,
        Symbol                  => 0,

        # these aren't core, the versions matter.

        MIME::Lite      => 3.0,
	},
);
