package PacSub::AccessControl;

use strict;
use warnings;

use Fcntl qw(LOCK_SH LOCK_EX LOCK_UN O_CREAT O_RDONLY);

use PacSub::Tools;

sub init() {
	$ACL = __PACKAGE__->new() if !$ACL;
}

sub new($;$) {
	my ($class, $skiplock) = @_;

	my $deny = {};
	my $allow = {};
	my $fh;
	my $revision = 0;

	my $path = $CFG->path('/acl');
	if (open($fh, '<', $path)) {
		if (!$skiplock) {
			timeout { flock($fh, LOCK_SH) } 10;
		}

		# eg:
		# deny foo:rw:/repo/core
		# allow blub:rwcd:/repo/core
		# allow amzo:rwcd:/repo/*

		while (defined(my $line = <$fh>)) {
			next if $line =~ /^\s*(?:#|$)/;
			chomp $line;

			if ($line =~ /^revision\s+(\d+)$/) {
				$revision = $1;
				next;
			}

			if ($line !~ /^\s*(allow|deny)\s+([^:\s]+):([^:\s]+):(\S+)\s*$/) {
				die "invalid acl entry: $line\n";
			}
			my ($type, $subject, $predicate, $object) = ($1, $2, $3, $4);
			if ($type eq 'allow') {
				__add($allow, $subject, $predicate, $object);
			} elsif ($type eq 'deny') {
				__add($deny, $subject, $predicate, $object);
			} else {
				die "invalid acl type: $type\n";
			}
		}
	} else {
		undef $fh;
	}

	return bless {
		path => $path,
		allow => $allow,
		deny => $deny,
		fh => $fh, # keep the lock
		revision => $revision,
	}, $class;
}

sub __add($$$$) {
	my ($rules, $subject, $predicate, $object) = @_;
	my $s = ($rules->{$subject} //= {
		re => glob_to_regex($subject),
		entries => {},
	})->{entries};
	my $o = ($s->{$object} //= {
		re => glob_to_regex($object),
		entries => {},
	})->{entries};
	$o->{$_} = 1 for ($predicate =~ /(.)/g);
}

sub __remove($$$$) {
	my ($rules, $subject, $predicate, $object) = @_;
	my $s = $rules->{$subject};
	return if !$s;
	$s = $s->{entries};
	my $o = $s->{$object};
	return if !$o;
	$o = $o->{entries};
	delete $o->{$_} for ($predicate =~ /(.)/g);
}

sub remove_subjects($$) {
	my ($self, $name) = @_;
	__remove_subjects($self->{deny}, $name);
	__remove_subjects($self->{allow}, $name);
}

sub __remove_subjects($$) {
	my ($rules, $name) = @_;
	delete $rules->{$name};
}

sub remove_objects($$) {
	my ($self, $name) = @_;
	__remove_objects_from($self->{deny}, $name);
	__remove_objects_from($self->{allow}, $name);
}

sub __remove_objects_from($$) {
	my ($rules, $name) = @_;
	delete $rules->{$_}->{entries}->{$name} for keys %$rules;
}

sub for_rules(&$) {
	my ($code, $rules) = @_;
	for my $subject (sort keys %$rules) {
		my $s = $rules->{$subject}->{entries};
		for my $object (sort keys %$s) {
			my $o = $s->{$object}->{entries};
			my $preds = '';
			for my $p (sort keys %$o) {
				$preds .= $p if $o->{$p};
			}
			next if !length($preds);
			$code->($subject, $preds, $object);
		}
	}
}

sub make_list($$) {
	my ($prefix, $rules) = @_;
	my @list;
	for_rules { push @list, [$prefix, @_] } $rules;
	return @list;
}

sub write_to($$$) {
	my ($prefix, $rules, $fh) = @_;
	for_rules {
		print({$fh} "$prefix ".join(':', @_)."\n");
	} $rules;
}

sub save_to($$) {
	my ($self, $path) = @_;
	open(my $fh, '>', $path) or die "open($path): $!\n";
	write_to('deny ', $self->{deny}, $fh);
	write_to('allow ', $self->{allow}, $fh);
	close($fh);
}

sub relock($$) {
	my ($self, $kind) = @_;
	my $fh = $self->{fh};
	if ($fh) {
		flock($fh, LOCK_UN);
	} else {
		sysopen($fh, $self->{path}, O_CREAT | O_RDONLY)
			or die "open($self->{path}): $!\n";
		$self->{fh} = $fh;
	}
	timeout { flock($fh, $kind) } 10;
}

sub check_revision($) {
	my ($self) = @_;
	my $compare = __PACKAGE__->new(1);
	die "file changed during operation\n"
		if ($compare->{revision} != $self->{revision})
}

sub save($) {
	my ($self) = @_;
	$self->relock(LOCK_EX);
	$self->check_revision();
	save_to($self, $self->{path});
	$self->relock(LOCK_SH);
}

sub allow($$$$) {
	my ($self, $subject, $predicate, $object) = @_;
	__add($self->{allow}, $subject, $predicate, $object);
}

sub deny($$$$) {
	my ($self, $subject, $predicate, $object) = @_;
	__add($self->{deny}, $subject, $predicate, $object);
}

sub remove($$$$) {
	my ($self, $type, $subject, $predicate, $object) = @_;
	__remove($self->{$type}, $subject, $predicate, $object);
}

sub list($$) {
	my ($self, $subject) = @_;
	return (make_list('deny', $self->{deny}),
	        make_list('allow', $self->{allow}));
}

sub check($$$;$) {
	my ($self, $subject, $predicate, $object);
	if (3 == @_) {
		$subject = $CFG->{user};
		($self, $predicate, $object) = @_;
	} elsif (4 == @_) {
		($self, $subject, $predicate, $object) = @_;
	}

	die "permission denied: $subject $predicate $object\n"
		if !$self->can($subject, $predicate, $object);
}

sub __contains($$$$) {
	my ($rules, $subject, $predicate, $object) = @_;
	for my $si (keys %$rules) {
		my $s = $rules->{$si};
		next if $subject !~ $s->{re};
		my $objects = $s->{entries};
		OBJ: for my $oi (keys %$objects) {
			my $o = $objects->{$oi};
			next if $object !~ $o->{re};
			my $predicates = $o->{entries};
			return 1 if $predicates->{'*'};
			for ($predicate =~ /(.)/g) {
				last OBJ if !$predicates->{$_};
			}
			# If one entry matches fully we're good
			return 1;
		}
	}
}

sub can($$$;$) {
	my ($self, $subject, $predicate, $object);
	if (3 == @_) {
		$subject = $CFG->{user};
		($self, $predicate, $object) = @_;
	} elsif (4 == @_) {
		($self, $subject, $predicate, $object) = @_;
	}

	# admin user can do everything
	return 1 if $subject eq $CFG->{'admin-user'};

	# user can do everything to /user/$self/** except for 'a' (administration)
	if ($predicate !~ /a/) {
		return 1 if startswith($object, "/user/$subject/");
	}

	return 0 if __contains($self->{deny}, $subject, $predicate, $object);
	return __contains($self->{allow}, $subject, $predicate, $object);
}

1;
