package PacSub::Config;

use strict;
use warnings;

use Text::Wrap;
use Text::ParseWords; # for --ssh

use Getopt::Long qw(GetOptionsFromArray
:config gnu_getopt no_ignore_case posix_default);

my $CONFIG = {
# Common parts
	config => {
		short => 'c',
		default => '~/.config/pacsub/config',
		description => 'configuration file to load defaults from',
	},

	arch => {
		short => 'A',
		default => 'x86_64',
		description => 'architecture',
	},

	user => {
		default => 'admin',
		short => 'u',
		description => 'The default user when executing pacsub-manage'
		              .' without a --user parameter.',
		arg => 'USER',
		once => 1, # can only be set once
	},
	'admin-user' => {
		default => 'admin',
		description => 'name of the administrator',
		nocli => 1, # cannot be set via command line
	},

	bsdtar => {
		default => 'bsdtar',
		description => 'name of the bsd-tar compatible executable',
		arg => 'FILE',
		nocli => 1,
	},

	ssh => {
		default => 0,
		description => 'use SSH_ORIGINAL_COMMAND as command',
		noconf => 1,
	},

## Client configuration
#	identity => {
#		short => 'i',
#		default => '',
#		description =>
#			'SSH key to use for authentication. Overrides the one'
#			.' configured for the host via .ssh/config.'
#	},
#	host => {
#		short => 'h',
#		default => 'pacbsd.org',
#		description =>
#			'Hostname to connect to. This may be a real hostname,'
#			.' or an entry configured via ~/.ssh/config.'
#	},

# Server configuration
	home => {
		nocli => 1,
		default => $ENV{HOME},
		arg => 'DIR',
		description =>
			'Base path containing the all the user related metadata.'
	},
	'authorized_keys-path' => {
		nocli => 1,
		default => '',
		description => 'path to the authorized keys file',
	},
	'package-root' => {
		nocli => 1,
		default => 'data',
		arg => 'DIR',
		description =>
			'Root path of the package repositories. This path should'
			.' contain subdirectories for pacman repositories'
			.' (core/, extra/, community/ and the like, in the usual'
			.' structure).'
			." If this is a relative path it'll be relative to the "
			." 'home' path."
	},
	'ssh-options' => {
		nocli => 1,
		default => 'no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty',
		description =>
			'Default ssh options to apply within the authorized_keys file',
	},
};

# Instantiate a configuration.
# classmethod
# @argv: command line parameters
# returns list:
#   $config
#   $command - the first non-option parameter
#   @argv - arguments following $command
sub new($@) {
	my ($class, @argv) = @_;

	my $self = bless({}, $class);

	my $override = {};
	my @config;

	my $once = sub {
		my ($arg) = @_;
		die "cannot override parameter $arg\n"
			if defined($override->{$arg});
	};

	# build getopt parameter description:
	my %args = map {
		my $optname = $_;
		my $desc = $CONFIG->{$optname};

		my $optstr = $optname;

		# set default
		$self->{$optname} = $desc->{default};

		if (defined(my $short = $desc->{short})) {
			$optstr .= "|$short";
		}

		my $setter;
		if ($optname eq 'config') {
			# special case: we load multiple configurations
			$setter = sub {
				push @config, glob($_[1]);
			};
		}
		elsif (defined(my $arg = $desc->{arg})) {
			$setter = sub {
				my $value = $_[1];
				if ($arg eq 'DIR' || $arg eq 'FILE') {
					$value = glob($value);
				}
				$override->{$optname} = $value;
			};
			$optstr .= '=s';
		} else {
			$setter = sub { $override->{$optname} = 1 };
		}

		my $real_setter = sub {
			$once->($optname);
			$setter->(@_);
		};
		$desc->{nocli} ? () : ($optstr => $real_setter)
	} keys %$CONFIG;

	GetOptionsFromArray(\@argv, %args);

	if (!@config) {
		my $defconf = glob($CONFIG->{config}->{default});
		@config = ($defconf) if -e $defconf;
	}

	for my $cfg (@config) {
		$self->load_config($cfg);
	}

	$self->{$_} = $override->{$_} for keys %$override;

	if ($self->{ssh}) {
		if (length(my $cmd = $ENV{SSH_ORIGINAL_COMMAND}//'')) {
			push @argv, parse_line(qr/\s/, 0, $cmd);
		}
	}

	return ($self, @argv);
}

sub load_config($$) {
	my ($self, $file) = @_;

	open(my $fh, '<', $file) or die "open($file): $!\n";

	while (defined(my $line = <$fh>)) {
		next if $line =~ /^\s*(?:#|$)/;

		if ($line !~ /^\s*([^=\s]+)\s*=\s*(\S+)\s*$/) {
			die "invalid configuration line: $line\n";
		}
		my ($key, $value) = ($1, $2);

		my $optdesc = $CONFIG->{$key};
		die "unknown configuraton option: $key\n" if !$optdesc;

		if (defined(my $arg = $optdesc->{arg})) {
			if ($arg eq 'FILE' || $arg eq 'DIR') {
				$value = glob($value);
			}
		}

		$self->{$key} = $value;
	}

	close($fh);
}

# get a path relative to the home directory
sub path($$) {
	my ($self, $path) = @_;
	return $self->{home}.$path;
}

sub packages($;$) {
	my ($self, $repo) = @_;
	if (defined($repo)) {
		return $self->packages() . "/$repo/os/$self->{arch}";
	}
	my $pkgroot = $self->{'package-root'};
	if ($pkgroot =~ m|^/|) {
		# absolute path
		return $pkgroot;
	} else {
		# relative path
		return $self->path("/$pkgroot");
	}
}

sub authorized_keys($) {
	my ($self) = @_;
	my $explicit = $self->{'authorized_keys-path'};
	return $explicit if length($explicit);
	return $self->{home} . '/.ssh/authorized_keys';
}

sub print($$) {
	my ($self, $fh) = @_;

	local($Text::Wrap::COLUMNS) = 69;

	my $nl = '';
	for my $key (sort keys %$CONFIG) {
		next if $key eq 'config';
		my $def = $CONFIG->{$key};
		next if $def->{noconf};

		my $desc = $def->{description};

		my $value = $self->{$key};

		my $text = '';
		$text .= '#' if $value eq $def->{default};
		$text .= "$key = $value";

		print {$fh} $nl, wrap('# ', '# ', $desc), "\n$text\n";
		$nl = "\n";
	}
}

1;
