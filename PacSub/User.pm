package PacSub::User;

use strict;
use warnings;
use Carp;

use Cwd;
use File::Path;

use PacSub::Tools;

my $USER_RE = qr/^[a-z][-a-zA-Z0-9_]+$/;

sub userpath(;$) {
	my ($user) = @_;
	my $path = $CFG->path('/users');
	$path .= "/$user" if defined($user);
	return $path;
}

sub is_legal_name($) {
	my ($name) = @_;
	return $name =~ $USER_RE;
}

# return a list of all available users
sub list($) {
	my ($skip_disabled) = @_;

	my $path = userpath();

	my @users;

	for_dir_re($path, $USER_RE, sub {
		my $disabled = (-e "$path/$_/disabled" ? 1 : 0);
		next if $skip_disabled && $disabled;
		push @users, [$_, $disabled];
	});

	return @users;
}

# create a new user
# classmethod
sub create($$) {
	my ($class, $name) = @_;

	my $global_lock = get_global_lock();

	my $path = userpath($name);
	die "user $name already exists\n"
		if -d $path;

	die "username $name is blocked\n"
		if -e $path;

	my $err = undef;
	my @paths = (
		$path,
		"$path/files"
	);
	File::Path::make_path(@paths, { error => \$err });
	croak "failed to create user $name: $err\n"
		if @$err;

	return $class->open($name);
}

# open an existing user
# classmethod
sub open($$;$) {
	my ($class, $name, $ignore_disabled) = @_;

	my $global_lock = get_global_lock();
	my $lock = getlock(userpath("$name.lock"));

	my $path = userpath($name);
	die "no such user: $name\n"
		if !-d $path;

	if (!$ignore_disabled && -e "$path/disabled") {
		my $message = getfile("$path/disabled");
		chomp $message;
		die "user $name is disabled: $message\n";
	}

	return bless {
		path => $path,
		name => $name,
		lock => $lock,
	}, $class;
}

sub remove($) {
	my ($class, $name) = @_;
	croak "$class usage error\n" if ref($name);
	my $global_lock = get_global_lock();
	# check for existence:
	my $user = $class->open($name, 1);
	# delete
	my $path = $user->{path};
	undef $user;
	File::Path::rmtree($path);
	$ACL->remove_subjects($name);
	$ACL->remove_objects($name);
	$ACL->save();
}

sub disabled($) {
	my ($self) = @_;
	return -e "$self->{path}/disabled";
}

sub set_disabled($$) {
	my ($self, $message) = @_;
	if (defined($message)) {
		setfile("$self->{path}/disabled", $message);
	} else {
		unlink("$self->{path}/disabled")
			or die "unlink: $!\n";
	}
}

sub ssh_keys($) {
	my ($self) = @_;
	my $keys = $self->{ssh_keys};
	if (!$keys) {
		$keys = $self->{ssh_keys} = [nonempty_line_list("$self->{path}/ssh")];
	}
	return @$keys;
}

sub add_ssh_keys($@) {
	my ($self, @add_keys) = @_;
	my @keys = $self->ssh_keys();
	merge_stable_list(\@keys, @add_keys);
	my $file = "$self->{path}/ssh";
	setfile($file, @keys ? (join("\n", @keys)."\n") : '');
}

sub remove_ssh_keys($@) {
	my ($self, @remove_list) = @_;
	my @keys = $self->ssh_keys();
	@keys = remove_from_id_list(\@keys, @remove_list);
	my $file = "$self->{path}/ssh";
	setfile($file, @keys ? (join("\n", @keys)."\n") : '');
}

sub update_ssh_authorized_keys() {
	my $global_lock = get_global_lock();

	my $ssh_opts = $CFG->{'ssh-options'};
	my $prog = Cwd::realpath($0);

	my $keydata = '';
	my @users = list(1);
	for my $ud (@users) {
		my $username = $ud->[0];
		my $user = __PACKAGE__->open($username);
		my @keys = $user->ssh_keys();
		my $line = "command=\"$prog --ssh --user=${username}\",$ssh_opts ";
		$keydata .= "${line}$_\n" for @keys;
	}
	
	my $file = $CFG->authorized_keys();
	my $dir = ($file =~ s|/[^/]+$||r);
	File::Path::mkpath($dir);
	modify_file($file, '# --- PacSub Access List :: ', $keydata);

}

sub gpg_keys($) {
	my ($self) = @_;
	my $keys = $self->{gpg_keys};
	if (!$keys) {
		$keys = $self->{gpg_keys} = [nonempty_line_list("$self->{path}/gpg")];
	}
	return @$keys;
}

sub add_gpg_keys($@) {
	my ($self, @key_ids) = @_;
	my @keys = $self->gpg_keys();
	merge_stable_list(\@keys, @key_ids);
	my $file = "$self->{path}/gpg";
	setfile($file, @keys ? (join("\n", @keys)."\n") : '');
}

sub remove_gpg_keys($@) {
	my ($self, @remove_list) = @_;
	my @keys = $self->gpg_keys();
	@keys = remove_from_id_list(\@keys, @remove_list);
	my $file = "$self->{path}/gpg";
	setfile($file, @keys ? (join("\n", @keys)."\n") : '');
}

sub list_files($) {
	my ($self) = @_;
	my @files;
	for_dir("$self->{path}/files", sub {{
		push @files, $_;
	}});
	return @files;
}

1;
