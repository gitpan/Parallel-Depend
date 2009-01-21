use 5.006;
use ExtUtils::MakeMaker;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile
(
	NAME	=> "Parallel::Depend",

    VERSION	=> '3.04',

	ABSTRACT	=>
'Parallel process startup with dependencies and restart.
Execute, Config, Utilities modules simplify generating
#! code for running queues including logging, email
notification, file read/write, and generation of absolute
paths relative to the execution directory paths via tokens .',

	AUTHOR     	=> 'Steven Lembark <lembark@wrkhors.com>',
	PREREQ_PM	=> 
	{
		# unlikely these aren't avaialble, but can't 
		# hurt to check... Symbol is core as of 5.8.

		Carp			=> 0,
		constant		=> 0,
		strict			=> 0,
		Symbol			=> 0,

		Data::Dumper	=> 0,
		File::Basename	=> 0,

		FindBin			=> 0,
        MIME::Lite      => 3.0,
	},
);

