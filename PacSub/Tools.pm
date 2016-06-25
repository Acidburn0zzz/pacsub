package PacSub::Tools;

use strict;
use warnings;

use Scalar::Util qw(weaken);
use POSIX qw(ENOENT);
use Fcntl qw(LOCK_EX LOCK_NB O_WRONLY O_CREAT);

use base 'Exporter';

our $CFG;
our $ACL;

our @EXPORT = qw(
	$CFG $ACL
	guard
	setfile
	getfile
	touch
	append_to_file
	modify_file
	wordcomplete
	findword
	glob_to_regex
	for_dir for_dir_re
	nonempty_lines
	nonempty_line_list
	getlock get_global_lock
	remove_from_id_list
	merge_stable_list
	forked
	timeout
	startswith
);

# scope guard sugar
sub guard(&) {
	my ($code) = @_;
	return bless { code => $code }, 'PacSub::Tools::ScopeGuard';
}

# for simple text files
sub getfile($) {
	my ($file) = @_;
	open(my $fh, '<', $file) or die "open($file): $!\n";
	my $data = do { local $/ = undef; <$fh> };
	close($fh);
	return $data;
}

# for simple text files
sub setfile_full($$$) {
	my ($file, $data, $mode) = @_;
	open(my $fh, $mode, $file) or die "open($file): $!\n";
	print {$fh} $data;
	close($fh);
}

# set the contents of a simple text file
sub setfile($$) {
	my ($file, $data) = @_;
	setfile_full($file, $data, '>');
}

sub touch($) {
	my ($file) = @_;
	my $fd = POSIX::open($file, O_WRONLY | O_CREAT);
	return 0 if $fd < 0;
	POSIX::close($fd);
	return 1;
}

# append simple text to a file
sub append_to_file($$) {
	my ($file, $data) = @_;
	setfile_full($file, $data, '>>');
}

sub startswith($$) {
	my ($a, $b) = @_;
	return 0 if length($a) < length($b);
	return substr($a, 0, length($b)) eq $b;
}

sub find_section($$) {
	my ($section, $lines) = @_;

	my $begin_marker = "${section}BEGIN";
	my $end_marker = "${section}END";

	my $begin;
	my $linenum = 0;
	for my $line (@$lines) {
		if (!defined($begin)) {
			$begin = $linenum if startswith($line, $begin_marker);
		} elsif (startswith($line, $end_marker)) {
			return ($begin, $linenum);
		}
		++$linenum;
	}
	return (scalar(@$lines), scalar(@$lines));
}

# modify a comment marked section of a file
sub modify_file($$$) {
	my ($file, $section, $data) = @_;
	chomp $data;
	my $fulldata = "${section}BEGIN\n$data\n${section}END\n";
	if (open(my $fh, '<', $file)) {
		my @lines = <$fh>;
		close($fh);
		my ($from, $to) = find_section($section, \@lines);
		splice @lines, $from, $to-$from+1, $fulldata;
		$data = join('', @lines);
	} else {
		$data = $fulldata;
	}
	setfile($file, $data);
}

# takes a partial word and finds all words this one is a prefix of
sub wordcomplete($@) {
	my ($word, @list) = @_;
	my @matches;
	my $len = length($word);
	for (@list) {
		next if length($_) < $len;
		push @matches, $_ if $word eq substr($_, 0, $len);
	}
	return @matches;
}

# Like completeword, but only matches a single unambiguous word.
# Returns undef if the word wasn't found or multiple words match.
sub findword($@) {
	my ($word, @list) = @_;
	my @matches = wordcomplete($word, @list);
	return scalar(@matches) == 1 ? $matches[0] : undef;
}

# Turn a non-recursive file glob into a regular expression. This includes
# support for making '**' match recursive directories, '+' to be like '?*'
# and '++' to be the recursive version of '?*'.
sub glob_to_regex($) {
	my ($glob) = @_;

	my $re = '^';

	my $escaping = 0;
	my $grouping = 0;
	my $asterisk = undef;
	for my $c ($glob =~ /(.)/gs) {
		if ($asterisk) {
			if ($c eq '*' || $c eq '+') {
				$re .= ".$asterisk"
			}
			else {
				$re .= "[^/]$asterisk";
			}
			$asterisk = undef;
		}

		if ($c eq '.' ||
		    $c eq '(' || $c eq ')' || $c eq '|' ||
		    $c eq '^' || $c eq '$' ||
		    $c eq '@' || $c eq '%')
		{
			$re .= "\\$c";
		}
		elsif ($c eq '*' || $c eq '+') {
			$asterisk = $c;
		}
		elsif ($c eq '?') {
			$re .= $escaping ? "\\?" : '.';
		}
		elsif ($c eq '{') {
			$re .= $escaping ? "\\{" : '(?:';
			++$grouping unless $escaping;
		}
		elsif ($grouping && $c eq '}') {
			$re .= $escaping ? "\\}" : '(?:';
			--$grouping unless $escaping;
			$grouping = 0 if $grouping < 0;
		}
		elsif ($grouping && $c eq ',') {
			$re .= '|';
		}
		elsif ($c eq "\\") {
			if ($escaping) {
				$re .= "\\\\";
			} else {
				$escaping = 1;
			}
		}
		else {
			$re .= $c;
		}
		$escaping = 0;
	}
	$re .= "[^/]$asterisk" if $asterisk;
	$re .= '$';
	return qr/$re/;
}

sub for_dir($&;$) {
	my ($path, $code, $noerr) = @_;
	opendir(my $dh, $path) or do {
		die "opendir($path): $!\n" unless $noerr;
		return;
	};
	while (defined(my $entry = readdir($dh))) {
		next if $entry eq '.' || $entry eq '..';
		eval {
			local $_ = $entry;
			$code->($entry)
		};
		if (my $err = $@) {
			closedir($dh);
			return if $err eq "break\n";
			die $err;
		}
	}
	closedir($dh);
}

sub for_dir_re($$&) {
	my ($path, $re, $code) = @_;
	for_dir($path, sub {
		$code->($_) if $_ =~ $re;
	});
}

sub nonempty_lines(&$) {
	my ($code, $file) = @_;
	open(my $fh, '<', $file) or do {
		die "open($file): $!\n" if $! != ENOENT;
		return;
	};
	while (defined(my $line = <$fh>)) {
		next if $line =~ /^\s*(?:#|$)/;
		chomp $line;
		eval {
			local $_ = $line;
			$code->($line);
		};
		if (my $err = $@) {
			last if $err eq "break\n";
			die $err;
		}
	}
	close($fh);
}

sub nonempty_line_list($) {
	my ($file) = @_;
	my @list;
	nonempty_lines {
		push @list, $_;
	} $file;
	return @list;
}

sub timeout(&$) {
	my ($code, $timeout) = @_;
	my $old_alarm = alarm(0);
	eval {
		local $SIG{ALRM} = sub { die "timeout\n"; };
		alarm($timeout);
		$code->();
		alarm(0);
	};
	my $err = $@;
	alarm($old_alarm);
	die $err if $err;
}

# recursive lock on a file with optional timeout
my $existing_locks = {};
sub getlock($;$) {
	my ($file, $timeout) = @_;

	if (my $old_lock = $existing_locks->{$file}) {
		return $old_lock;
	}

	my $nb = 0;
	if (defined($timeout) && $timeout == 0) {
		$nb = LOCK_NB;
	}

	open(my $fh, '>', $file) or die "open($file): $!\n";
	my $old_alarm = alarm(0) if defined($timeout);
	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm($timeout) if defined($timeout) && !$nb;
		flock($fh, LOCK_EX | $nb) or die "flock($file): $!\n";
		alarm(0) if defined($timeout);
	};
	my $err = $@;
	my $lock;
	if (!$err) {
		$lock = guard {
			#unlink($fh); dangerous
			close($fh);
			delete $existing_locks->{$file};
		};
		$existing_locks->{$file} = $lock;
		weaken($existing_locks->{$file});
	}
	alarm($old_alarm) if defined($old_alarm);
	die $err if $err;
	return $lock;
}

sub get_global_lock() {
	return getlock($CFG->path("/.global.lock"));
}

sub remove_from_id_list($@) {
	my ($list, @remove_list) = @_;

	my $id = 0;
	my %ids = map { $id++ => $_ } @$list;

	for my $k (@remove_list) {
		if ($k =~ /^\d+$/) {
			# numeric
			warn "no such id: $k\n" if !defined(delete $ids{$k});
		}
		else {
			my $found = 0;
			for $id (keys %ids) {
				if (index($ids{$id}, $k) != -1) {
					delete $ids{$id};
					$found = 1;
					last;
				}
			}
			warn "found entry matching $k\n" if !$found;
		}
	}

	# keep the order:
	return map { $ids{$_} } sort keys %ids;
}

sub merge_stable_list($@) {
	my ($list, @add_list) = @_;
	my %exists = map { $_ => 1 } @$list;
	for my $add (@add_list) {
		if (!$exists{$add}) {
			$exists{$add} = 1;
			push @$list, $add;
		}
	}
}

sub replacefd($$$) {
	my ($num, $file, $mode) = @_;
	my $fd = POSIX::open($file, $mode);
	if ($fd >= 0 && $fd != $num) {
		POSIX::dup2($fd, $num);
		POSIX::close($fd);
	}
}

sub forked(&;%) {
	my ($code, %opts) = @_;

	pipe my $except_r, my $except_w
		or die "pipe(): $!\n";

	my $pid = fork();
	die "fork failed: $!\n" if !defined($pid);
	if ($pid == 0) {
		close($except_r);

		if ($opts{nostdout}) {
			close STDOUT;
			replacefd(1, '/dev/null', O_WRONLY);
		}
		if ($opts{nostderr}) {
			close STDERR;
			replacefd(2, '/dev/null', O_WRONLY);
		}

		eval { $code->() };
		if (my $err = $@) {
			print {$except_w} $err;
			POSIX::_exit(1);
		}
		POSIX::_exit(0);
	}
	close($except_w);

	if (my $after = $opts{afterfork}) {
		$after->($pid);
	}

	my $except = do { local $/ = undef; <$except_r> };
	if (waitpid($pid, 0) != $pid) {
		die "interrupted\n";
	}
	if (defined($except) && length($except)) {
		chomp($except);
		die "$except\n";
	}
	return POSIX::WEXITSTATUS($?) if $opts{return};
	die "execution failed\n"
		if !POSIX::WIFEXITED($?) || POSIX::WEXITSTATUS($?) != 0;
}

package PacSub::Tools::ScopeGuard;

sub release {
	my ($self) = @_;
	delete $self->{code};
}

sub DESTROY {
	my ($self) = @_;
	if (defined(my $code = $self->{code})) {
		$code->();
	}
}

1;
