########################################################################
# Parallel::Depend::Util shared utilities.
# these include logging, notification, and standard output formats.
########################################################################

########################################################################
# housekeeping
########################################################################

package Parallel::Depend::Util;

use strict;
use warnings;
use feature qw( :5.10 );

our $VERSION=1.01;

use Carp;
use Data::Dumper;
use File::Basename;
use Symbol;

use FindBin         qw( $Bin );
use Date::Format    qw( time2str );
use Scalar::Util    qw( blessed );

########################################################################
# exported subs
########################################################################

# deal with use. basic issue is to pollute the caller's
# namespace with our subs.

*import
= do
{
    # stuff the subroutine names into the callers
    # package space.

    my @defaultz
    = qw
    (
        log_message
        log_fatal
        log_error
        log_warning
        log_format

        handle_que_args

        send_mail
        nastygram

        localpath
        checkdir

        slurp
        splat
    );

    my %exportz
    = map
    {
        my $sub = __PACKAGE__->can( $_ )
        or die __PACKAGE__ . "cannot $_";

        ( $_ => $sub )
    }
    @defaultz;

    sub
    {
        shift;  # discard this package.

        my $caller  = caller;

        for( @_ ? @_ : @defaultz )
        {
            when( %exportz )
            {
                my $ref = qualify_to_ref $_, $caller;

                if( *{ $ref }{ CODE } )
                {
                    warn "Skip existing '$_' in $caller";
                }
                else
                {
                    *$ref   = $exportz{ $_ };
                }
            }

            default
            {
                croak "Bogus import: '$_' ($caller) not exported";
            }
        }
    }
};

########################################################################
# package variables
########################################################################

our $defaultz = {};

########################################################################
# logging
########################################################################

# standardize log messages format.
# message arives in @_.

{ # isolate $msgseq, etc.

    my $tz      = $ENV{TZ} || '';
    my $time    = '';
    my $msgseq  = 0;

    sub log_format
    {
        local $Data::Dumper::Purity           = 1;
        local $Data::Dumper::Terse            = 1;
        local $Data::Dumper::Indent           = 1;
        local $Data::Dumper::Deepcopy         = 0;
        local $Data::Dumper::Quotekeys        = 0;

        my $caller
        = do
        {
            if( my $class = blessed $_[0] )
            {
                # use an object's class as the caller, 
                # discard the object.

                shift;

                $class
            }
            else
            {
                caller 2
            }
        };

        my $time    = time2str '%Y.%m.%d %H:%M:%S', time, 'GMT';

        my $header = join ' ', $$, ++$msgseq, $time, $caller;

        join "\n",
        map
        {
            ref $_ ? Dumper $_ : $_
        }
        ( $header, @_, '', '' )
    }

    sub log_warning { carp      &log_format }
    sub log_fatal   { confess   &log_format }

    # log to stderr, selected fh.

    sub log_error
    { 
        print STDERR &log_format;

        return
    }

    sub log_message
    {
        local $| = 1;
        local $\;

        print &log_format;

        return
    }
}

########################################################################
# email notification
########################################################################

########################################################################
# this actually sends the mail.
# it provides sane defaults for the minimal headers.

sub send_mail
{
    use MIME::Lite;

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

    $DB::single = 1 if $que->debug;

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

    my $message = log_format @_;

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
# generic argument handler. this can be called from anything queued
# to get back the que or config objects:
#
#   my ( $config ) = &handle_que_args;
#
# or
#
#   my ( $que, $config ) = &handle_que_args;
########################################################################

sub handle_que_args
{
    # catch: the debugger adds a level onto the stack,
    # which can make things a bit flakey here.
    # fix is to walk up the caller tree until something
    # isn't in Parallel::Depend.

    my $pkg = (caller 0)[0];
    my $sub = (caller 1)[3];

    my $que = shift
    or croak "Bogus $sub: missing queue object";

    log_message "Entering: $sub", \@_;

    my $config = $que->moduleconfig( $pkg )
    or croak "Bogus $sub: no configuration information";

    $DB::single = 1 if $que->debug;

    ( $que, $config )
};


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

sub checkdir
{
    for my $path ( @_ )
    {
        -e $path || mkdir $path, 02775
            or die "Roadkill: unable to find/create $path";

        # at this point the directory should exist
        # and be accessable. since it may have been
        # created on the last step at least one more
        # file test operator has to give the path to
        # force a stat.

        -e $path    or die "Roadkill: non-executable: $path";
        -d _        or die "Roadkill: non-directory: $path";
        -x _        or die "Roadkill: non-executable: $path";
        -w _        or die "Roadkill: non-writeable: $path";
        -r _        or die "Roadkill: non-readable: $path";
    }
}


########################################################################
# un-dump data.
#
# read dumper Dumper output back into a scalar.
# caller gets back the result of string-eval of
# the file contents.
#
# adding '.dump' allows passing in sql keys
# used in unload as basenames.

sub slurp
{
    my $path = shift
    or croak "Bogus slurp: missing path";

    # check the standard alternates from splat if
    # the path passed in does not exist.

    unless( -e $path )
    {
        $path = join '', ( fileparse $path, qr{\.\w+} )[1,0];

        -e $path . $_ and $path .= $_ for( qw(.dump .tsv) );
    }

    -e $path    or nastygram "Missing $path";
    -r _        or nastygram "Unreadable $path";
    -s _        or nastygram "Empty $path";

    open my $fh, '<', $path
    or nastygram "$path: $!";

    local $/;

    defined ( my $item = <$fh> )
    or nastygram "Failed read on non-empty: $path";

    # if the result can be eval-ed into a defined value
    # then hand that back. otherwise split it on newlines
    # split the contents on tabs and hand back an array-
    # of-arrays ref.

    if( my $result = eval $item )
    {
        $result
    }
    else
    {
        my @data = map { [ split /\t/ ] } split "\n", $item;

        \@data
    }
}

# write out data in a format that can be slurped.
# main issue is ensuring that the extensions match.

sub splat_fh
{
    my $name = shift
    or die "Bogus splat_fh: missing name";

    # this might usefully be false.

    defined ( my $ext = shift )
    or die "Bogus splat_fh: missing extension";

    my $path = localpath $name;

    my ( $base, $dir ) = (fileparse $path, qr{\.\w+} )[0,1];

    $path = join '', $dir, $base, $ext;

    log_message "Opening $name -> $path";

    open my $fh, '>', $path
    or die "$path: $!";

    $fh
}

sub splat
{
    my $name = shift
    or croak "Bogus write_dump: missing name";

    my $data = shift
    or croak "Bogus write_dump: missing data referent";

    if( defined eval { scalar @$data } )
    {
        local $\ = "\n";
        local $, = "\t";

        my $fh = splat_fh $name, '.tsv';

        my $test = $data->[0];

        if( defined eval { @$test } )
        {
            print $fh @$_ for @$data;
        }
        else
        {
            print $fh "$_" for @$data;
        }
    }
    elsif( defined eval { scalar %$data } )
    {
        if( keys %$data < 1000 )
        {
            local $Data::Dumper::Purity           = 1;
            local $Data::Dumper::Terse            = 1;
            local $Data::Dumper::Indent           = 1;
            local $Data::Dumper::Deepcopy         = 0;
            local $Data::Dumper::Quotekeys        = 0;

            my $fh = splat_fh $name, '.dump';

            print $fh Dumper $data
        }
        else
        {
            local $\ = "\n";
            local $, = "\t";

            my $fh = splat_fh $name, '.tsv';

            # print arrays out tab separated.
            # other than that assume whatever
            # is there will be a simple value
            # or something that can successfully
            # stringify itself.

            my $test = (values %$data)[0];

            if( defined eval{ @$test } )
            {
                print $fh $a, @$b
                while( ($a,$b) = each %$data );
            }
            else
            {
                print $fh $a, "$b"
                while( ($a,$b) = each %$data );
            }
        }
    }
    else
    {
        # not an array or hash: assume Dumper knows
        # how to deal with it...

        local $Data::Dumper::Purity           = 1;
        local $Data::Dumper::Terse            = 1;
        local $Data::Dumper::Indent           = 1;
        local $Data::Dumper::Deepcopy         = 0;
        local $Data::Dumper::Quotekeys        = 0;

        my $fh = splat_fh $name, '.dump';

        print $fh Dumper $data;
    }

    # not much to hand  back

    0
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

Parallel::Depend Parallel::Depend::Execute Parallel::Depend::Config

=head1 Copyright

(C) 2001-2002 Steven Lembark, Workhorse Computing

This code is released under the same terms as Perl istelf. Please
see the Perl-5.8 distribution (or later) for a full description.

In any case, this code is release as-is, with no implied warranty
of fitness for a particular purpose or warranty of merchantability.
