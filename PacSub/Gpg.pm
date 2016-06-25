package PacSub::Gpg;

use strict;
use warnings;

use Carp;
use POSIX;

use PacSub::Tools;

my $GPG = 'gpg';
my @__GPG = qw(--batch --no-tty --with-colons);

sub GPG() {
	return ($GPG, "--home=".$CFG->path('/gnupg'), @__GPG);
}

sub runlines($$;%) {
	my ($cmd, $code, %opts) = @_;

	pipe my $outr, my $outw;

	my $pid = fork();
	die "fork failed: $!\n" if !defined($pid);

	if ($pid == 0) {
		close($outr);
		my $readfd = $opts{readfd} // 1;
		if (fileno($outw) != $readfd) {
			POSIX::dup2(fileno($outw), $readfd);
			close($outw);
		}
		if (my $fhin = $opts{fhin}) {
			POSIX::dup2(fileno($fhin), 0);
			close($fhin);
		}
		#print STDERR "Running: ".join(' ', @$cmd)."\n";
		exec({$cmd->[0]} @$cmd) or POSIX::_exit(-1);
	}
	if (my $fhin = $opts{fhin}) {
		close($fhin);
	}

	close($outw);

	while (defined(my $line = <$outr>)) {
		chomp $line;
		local $_ = $line;
		$code->($line);
	}

	die "interrupted\n" if waitpid($pid, 0) != $pid;
	return -1 if !POSIX::WIFEXITED($?);
	return POSIX::WEXITSTATUS($?);
}

sub pub_keys(;@) {
	my (@matching) = @_;

	my @keys;

	my $addpub = sub {
		my (@values) = @_;
		my $keyid = $values[3];
		my $len = length($keyid);
		if (@matching) {
			next if !grep {
				length($_) <= $len and
				$_ eq substr($keyid, length($keyid)-length($_))
			} @matching;
		}
		push @keys, {
			validity     => $values[0],
			length       => $values[1],
			algorithm    => $values[2],
			keyid        => $keyid,
			created      => $values[4],
			expires      => $values[5],
			capabilities => $values[10],
		};
	};

	my $adduid = sub {
		my (@values) = @_;
		push @{$keys[-1]->{uids}}, $values[8];
	};

	runlines([GPG(), '--list-public-keys'], sub {{
		my ($line) = @_;
		my ($type, @values) = split(/:/, $line);
		if ($type eq 'pub') {
			$addpub->(@values);
		} elsif ($type eq 'uid') {
			$adduid->(@values);
		}
	}}) == 0 or die "gpg error\n";
	return @keys;
}

sub recv_keys(@) {
	my (@keyids) = @_;
	runlines([GPG(), '--recv-keys', '--', @keyids], sub {{
		print("> $_\n");
	}}) == 0 or die "gpg error\n";
	return pub_keys(@keyids);
}

sub import_keys_fh($) {
	my ($fh) = @_;
	my @keys;
	runlines([GPG(), '--import'], sub {{
		if (/^gpg: key ([a-fA-F0-9]+):.*(?:imported|not changed)$/) {
			push @keys, $1;
		}
	}}, fdin => $fh, readfd => 2) == 0 or die "gpg error\n";
	return pub_keys(@keys);
}

sub verify_files($@) {
	my ($sigfile, @files) = @_;
	croak "files missing" if !@files;
	return 0 == forked {
		exec({$GPG} GPG(), '--verify', '--', $sigfile, @files)
		or die "failed to run gpg --verify\n";
	} nostderr => 1, return => 1;
}

1;
