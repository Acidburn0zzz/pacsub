package PacSub::CLI;

use strict;
use warnings;

use PacSub::Tools;
use PacSub::Config;
use PacSub::Repo;

use base 'Exporter';
our @EXPORT = qw(
mkhelp
subcommand
argdone
);

my @cmdpath;
my $current_list;
my $argdone = 0;

sub argdone() {
	$argdone = 1;
}

sub init(@) {
	my (@args) = @_;
	($CFG, my $cmd, @args) = PacSub::Config->new(@args);
	return ($cmd, @args);
}

sub run($$@) {
	my ($cmdlist, $cmd, @args) = @_;

	my $rc = eval { command($cmdlist, $cmd, @args) };
	if (my $err = $@) {
		print STDERR $err;
		error(\*STDERR, $current_list) if !$argdone;
		return $rc || 1;
	}
	return $rc // 0;
}

sub command($$@) {
	my ($cmdlist, $partial_cmd, @args) = @_;
	$argdone = 0;

	$current_list = $cmdlist;

	if (!defined($partial_cmd)) {
		die "missing command\n";
	}

	my $cmd = findword($partial_cmd, keys %$cmdlist);
	die "unknown command: $partial_cmd\n" if !defined($cmd);

	my $def = $cmdlist->{$cmd};
	push @cmdpath, $cmd;

	if (my $perms = $def->{perms}) {
		my $old_argdone = $argdone;
		$argdone = 1;
		for my $p (@$perms) {
			my ($predicate, $object) = @$p;
			$ACL->check($predicate, $object);
		}
		$argdone = $old_argdone;
	}

	my $rv = $def->{code}->(@args);
	# if it returned success (shell true == 0) we need to run post hooks
	if ($rv == 0) {
		if (my $posthooks = $def->{posthooks}) {
			for my $hook (@$posthooks) {
				$hook->();
			}
		}
	}
	return $rv;
}

sub error($$) {
	my ($fh, $cmdlist) = @_;
	my $path = join(' ', @cmdpath);
	$path .= ' ' if $path;
	print {$fh} "usage: $0 ${path}<command> [arguments...]\n";
	showhelp($fh, $cmdlist);
}

sub showhelp($$) {
	my ($fh, $cmdlist) = @_;
	#print({$fh} "available commands:\n");
	for my $cmd (sort keys %$cmdlist) {
		my $desc = $cmdlist->{$cmd};
		if (defined(my $args = $desc->{arghelp})) {
			$cmd .= " $args";
		}
		printf({$fh} "  %-26s %s\n", $cmd, $desc->{help});
	}
}

sub mkhelp($) {
	my ($cmdlist) = @_;

	my $helpcode = sub {
		my ($fh) = @_;
		$fh //= \*STDERR;
		showhelp($fh // \*STDERR, $cmdlist);
	};

	return (help => {
		help => 'show this help message',
		code => $helpcode,
	});
}

sub subcommand($$$) {
	my ($name, $cmdlist, $help) = @_;
	return ($name => {
		help => $help,
		arghelp => '<command>',
		code => sub {
			my ($cmd, @args) = @_;
			return command($cmdlist, $cmd, @args);
		},
	});
}

1;
