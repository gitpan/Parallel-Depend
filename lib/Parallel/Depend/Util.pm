########################################################################
# Parallel::Depend::Util shared utilities.
# these include logging, notification, and standard output formats.
########################################################################

########################################################################
# housekeeping
########################################################################

package Parallel::Depend::Util;

use v5.10.0;
use strict;
use subs qw( log_format );

our $VERSION=1.02;

use Carp;
use Data::Dumper;
use File::Basename;
use MIME::Lite;
use Symbol;

use File::Spec::Functions   qw( splitpath catpath splitdir catdir );

use Cwd             qw( abs_path );
use FindBin         qw( $Bin );
use Date::Format    qw( time2str );
use List::Util      qw( reduce );
use Scalar::Util    qw( blessed );

# avoid listing log_fatal, etc, as sources for errors.

push @::CARP_NOT, __PACKAGE__;

########################################################################
# package variables 
########################################################################

########################################################################
# exported subs
########################################################################

# deal with use. basic issue is to pollute the caller's
# namespace with our subs.

our @exportz
= qw
(
    log_format
    log_output
    log_message
    log_error
    log_warning
    log_fatal
    send_mail
    progress_mail
    nastygram
    localpath
    gendir
    genpath
    checkdir
);

sub import
{
    my $package = shift;
    my $caller  = caller;

    my $exportz
    = do
    {
        my $ref = qualify_to_ref 'exportz', $package;

        *{ $ref }{ ARRAY };
    }
    or die "Bogus import: $package has no exports";

    for( @_ ? @_ : @$exportz )
    {
        when( @$exportz )
        {
            my $ref = qualify_to_ref $_, $caller;

            if( *{ $ref }{ CODE } )
            {
                warn "Skip existing '$_' in $caller";
            }
            else
            {
                *$ref   = $package->can( $_ );
            }
        }

        default
        {
            croak "Bogus import: '$_' ($caller) not exported";
        }
    }
}

########################################################################
# package variables
########################################################################

our $defaultz = {};

########################################################################
# logging
########################################################################

# standardize log messages format.
# message arives in @_.

*log_format
= do
{
    my $tz      = $ENV{TZ} || '';
    my $time    = '';
    my $msgseq  = 0;

    sub
    {
        local $Data::Dumper::Purity           = 1;
        local $Data::Dumper::Terse            = 1;
        local $Data::Dumper::Indent           = 1;
        local $Data::Dumper::Deepcopy         = 0;
        local $Data::Dumper::Quotekeys        = 0;

        # handle accidentally treating this as a method.

        blessed $_[0] and shift;

        # i.e., iso8601

        my $time    = time2str '%Y.%m.%dT%TZ', time, 'GMT';

        my $header = join ' ', $$, ++$msgseq, $time;

        $header .= "\t" . shift
        unless ref $_[0];

        # prefixing lines with a newline reduces
        # the number of "floading" lines on the
        # display and reduces intermingling of 
        # messages.

        if( @_ )
        {
            join "\n", '',
            map
            {
                ref $_ ? Dumper $_ : $_
            }
            ( $header, @_, '' )
        }
        else
        {
            $header . "\n"
        }
    }
};

sub log_output
{
    my $fh  = shift;

    print $fh &log_format;

    return
}

sub log_message { print STDOUT  &log_format }
sub log_error   { print STDERR  &log_format }

sub log_warning { carp          &log_format }
sub log_fatal   { confess       &log_format }

########################################################################
# email notification
########################################################################

########################################################################
# this actually sends the mail.
# it provides sane defaults for the minimal headers.

sub send_mail
{
    my %mailargz = ref $_[0] ? %{$_[0]} : @_;

    unless( $mailargz{To} )
    {
        $mailargz{To} = (getpwuid $>)[0] . '@localhost';

        log_error "Bogus send_mail: defaulting email to '$mailargz{To}'";
    }

    $mailargz{To} = join ',', @{ $mailargz{To} }
    if ref $mailargz{To};

    # other things can reasonably be defaulted...

    $mailargz{'X-Parallel::Depend'} ||= "Generic";

    $mailargz{From} ||=
    do
    {
        my $user = (getpwuid $>)[0];
        chomp ( my $host = qx(hostname) );

        join '@', $user, $host
    };

    $mailargz{'Reply-to'} ||= $mailargz{From};

    $mailargz{Subject} ||= "Email from $mailargz{From}";

    $mailargz{Subject} =~ s/^/[Unknown-Notify]/
    unless $mailargz{Subject} =~ /^\[/;

    $mailargz{Data} ||= 'This is an automatic notification';

    # mail is flakey enough that this needs to log
    # any failurs. also saves people from complaing
    # that the mail wasn't delivered: at least we
    # know why from this end...

    eval { MIME::Lite->new( %mailargz )->send };

    log_error "Failed sending email: $@" if( $@ );

    # caller gets back the subject and name list.

    "$mailargz{Subject} -> $mailargz{To}"
}

########################################################################
# que_mail is for sending email from w/in the schedule.
# it is intended to handle automated progress notification.
# use send_mail with a more specific message in order to
# transmit error/recovery information.

sub progress_mail
{
    my $que = shift
    or croak "Bogus progress_mail: missing que object";

    my $job = shift
    or croak "Bogus notify: missing job argument";

    my $config  = $que->{user}->moduleconfig
    or die "$$: Bogus notify: que missing user data.";

    my $quename = $config->{quename} || 'Unknown';

    my $names = $config->{notify}{$job}
    or die "$$: Bogus notify: no '$job' name list configured.";

    my $fromid = $config->{mail_from}
    or die "$$: Bogus notify: no 'mail_from' entry configured.";

    my %mailargz =
    (
    # use to detect test email in mail rules.
    # setting the rules to detect specific programs
    # makes it easeir to segregate based on what is
    # being tested.

    'X-Parallel::Depend'      => "$quename-$job",

    # set from command line w/ default.

    To              => $names,
    'Reply-to'      => $fromid,
    From            => $fromid,

    Subject         => "[$quename-Progress] $job",

    Data            => 'This is an automated progress message.',
    );

    # caller gets back result of sending the mail.

    send_mail %mailargz
}

########################################################################
# log & email fatal messages.
#
# Note:  this cannot die until the end in order to guarantee
# that the log entries and email are sent. it has to be
# entirely tolerant of bogus configs and arguments.

sub nastygram
{
    # log the stuff first, this guarantees
    # that at least something will be recorded.

    log_error "Roadkill:", @_;

    # without a que object, use the global defaults
    # to find things instead.

    my $global = $defaultz->{global};

    my $config = $defaultz->{$global}
    or warn "Bogus config: missing global 'Parallel::Depend' entry";

    my $quename = $config->{quename} || 'Unknown';

    my $fatal = "$quename-Fatal";

    my $notify = $config->{notify}
    or warn "Bogus config:  global missing 'notify' entry";

    my $subject = shift || 'Bad news, boss...';

    $subject =~ s/^/[$fatal]/ unless $subject =~ /^\[/;

    my $message = &log_format;

    my $mailargz =
    {
        'X-Parallel_Depend'    => $fatal,

        To      => $notify->{fatal} || 'schedule_depend@localhost',

        From    => $config->{mail_from} || 'schedule_depend@localhost',

        Subject => $subject,

        Data    => $message,
    };

    # die with the message subject and notify list.
    # this will be the last line of the job's .err file.

    die send_mail $mailargz;
}

########################################################################
# directory operations
########################################################################

# various standard file paths based on $Bin.
# empty arg's gives $Bin with a trailing '/'.
#
# note that the directory can be anything, including
# subdir's or file basenames.
#
# make non-absolute paths relative to $Bin instead
# of the current working directory.
#
# creating the file is unlikely to succeed
# unless the directory already exists...

sub localpath
{
    my $global = $defaultz->{global} ||= {};

    # make a local copy of the last argument; replace
    # symbolic names from the defaults with real
    # basenames. making the copy avoids modifying
    # another argument in place via @_.

    @_ and my $name = $_[-1];

    # default directory is '../var/tmp'.

    unshift @_, '../var/tmp' unless grep m{/}, @_;

    my $path = join '/', ( @_ ? @_ : '' );

    $path = "$Bin/$path" unless $path =~ m{^/};

    # this is a hack and should be configured via
    # values in the default config. that or this
    # should use parsefile to default the extension
    # if none is given.

    $path .= '.dump' if ! -e $path && -e "$path.dump";

    # caller gets back the path, which may not
    # exist, yet.

    $path
}

# validate/create a directory.
# default mods are 02775.

sub gendir
{
    abs_path
    reduce
    {
        $a  = catdir $a, $b;

        -e $a || mkdir $a, 02755
        or confess "Failed mkdir: $a, $!", \@_;

        $a
    }
    splitdir catdir @_
}

sub genpath
{
    my ( $vol, $dir, $base ) = splitpath $_[0];

    catpath $vol, ( gendir $dir ), $base
}

sub checkdir
{
    -e or gendir $_ for @_;

    return
}

########################################################################
# keep require happy

1

__END__

=head1 TITLE

Parallel::Depend::Util

Kitchen-sink module for configuratin, logging, whatever...

=head1 SYNOPSIS

	use Parallel::Depend::Util;

	# generate path relative to the #!'s $Bin directory.
	# these can be abs-pathed without regard to the
	# current working directory. The last path element
	# is looked up in $defaulz->{global}{basename} allowing
	# for simpler shared path names.

	my $path = localpath @path_components, $token;
	my $path = localpath @path_components, 'basename';

	# sanity check a set of paths.

	checkdir @dirlist;

	# send email, to can also be an array referent.
	# from defaults to current user at whatever
	# 'hostname' returns.

	send_mail
		To         => 'someone@someplace',
		From       => 'me@here',
		Subject    => 'Message subject',
		Data       => 'Message body',

		'X-Parallel::Depend' => 'Progress'
	;

	# defaults from $que->{user}->moduleconfig.

	progress_mail @message;

	nastygram @message;



=head1 DESCRIPTION

Utility functions for queueing: message logging with standard
format, sending email, and generating/checking local file paths.

=over 4

=item Messages: log_format, log_message, log_error

The format adds a PID and timestamp, converts referents via
Data::Dumper, and returns the result as a string.

log_mesasge prints to STDOUT and returns clean (0),
log_error prints to STDERR and STDOUT, returning an
error status of -1.

=item Email-notification: send_mail, progress_mail, nastygram.

send_mail is a generic mail wrapper for MIME::Lite;
progress mail is useful for tracking long-running jobs
(basically log_message via email); nastygram will send
the email and then die with the error message (effectively
aborting a queue).

progress_mail and nastygram are que methods and take
their to and from values via $que->{user}->{moduleconfig}.

Progress mail is intended for monitorig long-running
jobs and sends messages to $config->{notify}{$job}:

	$defaults =
	{
		Foobar =>
		{
			queuename => 'Daily Frobnicate',

			notify =>
			{
				download_stuff =>
				[ qw( user1@somehost user2@anotherhost ) ],
			},
		},

		...
	}

	...

	sub que_job
	{
		...

		$que->progress_mail 'download_foobar';
	}

Will send a standard message with a subject of
"[$quename-Progress] $jobname" to the names configured
for that job.

nastygram notifies the configured list of a fatal run-time
error that is aborting queue execution. It sends out a
log_format-ed message and then dies with an error message.

	$defaultz =
	{
		Foobar =>
		{
			notify =>
			{
				job1 => 'user1@someplace',
				job2 => 'user2@someplace',

				fatal => [qw( user1@someplace user2@someplace )],
			},
		},
	},


	$que->nastygram 'Fatal: unable to carry the load', $loadref;


nastygram will call log_format on the arguments, prefix a
fatality message, and send the result to everyone listed in
the fatal list.


=item Local files: localpath, checkdir, slurp, splat.

localpath uses $config->{basename} to convert a path plus
basename-or-token to a path relative to $FindBin::Bin. Its
main use is in tokenizing the basenames of paths used in
multiple stages of a job. The code uses hash keys for the
paths which can then be more descriptive and changed in
standard places.

	$defaultz =>
	{
		Foboar =>
		{
			basenames =>
			{
				name2node => 'name-node-table.dump.gz',
			}
		},
	};

	...

	my $path = localpath '../var/tmp', 'name2node';

This is a subroutine and not a que method, it accesses
$Parallel::Depend::Execute::defaults->{global} directly
to find the hash of basename-tokens.

It is also specific to *NIX, since it uses a join '/'
to generate the final path.

If the input path does not begin with '/' then $FindBin::Bin
is prefixed to it. Note that this path may not yet exist
where localpath is called to generate a path for new output.
In those casese it will carp but still return the requested
path.

checkdir is used to santiy-check the log, run, and tmp
directories before execution. If the path(s) requested do
not exist then it attempts to create them with mods of
02775. If the directory does not exist or is not
read+executable+writable by the current user it dies with
a specific error message.

	checkir $indir, $outdir, $tmpdir;

	# if you are alive at this point then the directories
	# exist and are fully accessable.

slurp reads the output of Data::Dumper and evals it, returning
the result:

	$defaultz =>
	{
		Foobar =>
		{
			basename =>
			{
				name2id => '../var/tmp/entry2id.dump',
			},
		},
	};

	my $data = slurp localpath name2id;


Will reload and eval the output of Data::Dumper (or
anything else that can be eval-ed), returning the
result as a scalar (i.e., the eval is assigned to
a scalar).

If the eval failes slurp calls nastygram with a message
of the failed path.

splat writes out files in a way that is consistent with
sulrp reading them. Its main use is in avoiding Data::Dumper
in cases where the block of data is to large to effectively
convert to sourceable text. If it is passed an array or
if the number of hash keys is greater than 1000, splat will
write data out as a tab-separated-values ('.tsv') file.

Note: slurp and splat default to using ".dump" as the
extension for Data::Dumper-ed content, ".tsv" for tab
separated. splat may modify the path given in basenames
to accomodate the format actually written; slurp looks
for both ".tsv" and ".dump" extensions.

=back

=head1 AUTHOR

Steven Lembark, Workhorse Computing <lembark@wrkhors.com>

=head1 See Also

Parallel::Depend

=head1 Copyright

(C) 2001-2002 Steven Lembark, Workhorse Computing

This code is released under the same terms as Perl istelf. Please
see the Perl-5.8 distribution (or later) for a full description.

In any case, this code is release as-is, with no implied warranty
of fitness for a particular purpose or warranty of merchantability.
