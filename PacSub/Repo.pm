package PacSub::Repo;

use strict;
use warnings;

use File::Path;
use File::Copy;

use PacSub::Tools;

my $REPO_RE = qr/^[-a-z0-9_]+$/;
my $PACKAGE_RE = qr/^(.*)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar(\.\w+)?$/;

sub repopath(;$$) {
	my ($repo, $arch) = @_;
	my $path = $CFG->packages();
	if (defined($repo)) {
		$path .= "/$repo";
		$path .= "/os/$arch" if defined($arch);
	}
	return $path;
}

sub is_legal_name($) {
	my ($name) = @_;
	return $name =~ $REPO_RE;
}

sub dbpath($$) {
	my ($repo, $arch) = @_;
	return repopath($repo, $arch) . "/$repo.db";
}

sub match_package($) {
	my ($name) = @_;
	die "not a package name: $name\n" if $name !~ $PACKAGE_RE;
	return {
		name => $1,
		version => $2,
		rel => $3,
		arch => $4,
		compression => $5,
	};
}

# return a list of all available repositories
# (
#   {
#     name => $name,
#     path => $path,
#     archs => [architectures],
#   }
# )
sub list() {
	my $path = repopath();
	my @repos;
	for_dir_re($path, $REPO_RE, sub {
		my ($reponame) = @_;
		my $repopath = "$path/$reponame";
		my $data = {
			name => $_,
			path => $repopath,
		};
		eval {
			my @archs;
			# On error just skip this directory
			for_dir("$repopath/os", sub {
				push @archs, $_ if -e "$repopath/os/$_/$reponame.db";
			});
			if (@archs) {
				$data->{archs} = [sort @archs];
				push @repos, $data;
			}
		};
	});
	return @repos;
}

# create and initialize a new repository
sub create($@) {
	my ($repo, @archs) = @_;

	#my $global_repo_lock = getlock(repopath('.full.lock'));
	my $global_lock = get_global_lock();

	my $path = repopath($repo);
	my $ok = 1;
	for my $arch (@archs) {
		if (-d "$path/os/$arch") {
			print STDERR "$repo : $arch already exists\n";
			$ok = 0;
			next;
		}
		File::Path::make_path("$path/os/$arch");
		setfile("$path/os/$arch/$repo.db.tar.gz", '');
		symlink("$repo.db.tar.gz", "$path/os/$arch/$repo.db")
			or die "failed to create symlink for repo db $repo : $arch: $!\n";
	}
	return $ok;
}

# get a list of packages of a repository
# returns:
# (
#   {
#     repo => $repo,
#     name => $name,
#     version => $version,
#   }
# )
sub packages($$) {
	my ($repo, $arch) = @_;
	my $path = repopath($repo, $arch);
}

# usually we want to check them individually to get a list of bad ones
sub verify_files($@) {
	my ($sigfile, @files) = @_;
	my @bad;
	for my $file (@files) {
		push @bad, $file if !verify_multiple($sigfile, $file);
	}
	die "signature verification failed for:\n" . join("\n", @bad, '') if @bad;
}

# add package files to a repository
sub add_package_files($$@) {
	my ($repo, $arch, @package_files) = @_;
	my $path = repopath($repo, $arch);

	my $errors = 0;
	my @short_names;
	# verify filenames:
	for my $pkg (@package_files) {
		my $name = ($pkg =~ s|^.*/||r);
		my $package = match_package($name);
		my $pa = $package->{arch};
		if ($arch ne $pa) {
			++$errors;
			warn "architecture mismatch: package arch $pa != $arch\n";
		}
		if (!-e "$pkg.sig") {
			++$errors;
			warn "missing signature for: $name\n";
		}
		elsif (!PacSub::Gpg::verify_files("$pkg.sig", $pkg)) {
			++$errors;
			warn "signature check failed for: $name\n";
		}
		push @short_names, $name;
	}

	die "please fix the above problems before proceeding\n" if $errors;

	# FIXME: verify we're not downgrading

	# copy:
	my @cleanup;
	for my $pkg (@package_files) {
		my $name = ($pkg =~ s|^.*/||r);

		copy $pkg, "$path/$name"
			or die "failed to copy package file: $pkg: $!\n";
		push @cleanup, guard { unlink("$path/$name") };

		copy "$pkg.sig", "$path/$name.sig"
			or die "failed to copy signature file: $pkg.sig: $!\n";
		push @cleanup, guard { unlink("$path/$name.sig") };
	}

	# everything copied, attempt to add:
	forked {
		chdir($path) or die "chdir($path): $!\n";
		exec({'repo-add'} 'repo-add', "$repo.db.tar.gz", @short_names)
		or die "exec failed: $!\n";
	};

	# repository is in a consistent state, free the cleanup guards
	$_->release for @cleanup;

	# delete the old package files
	for my $pkg (@package_files) {
		unlink($pkg) or warn "failed to delete file: $pkg\n";
	}
}

# remove packages from a repository
sub remove_packages($$@) {
	my ($repo, $arch, @package_names) = @_;
	my $path = repopath($repo, $arch);
	my %pkghash = map { $_ => 1 } @package_names;
	forked {
		chdir($path) or die "chdir($path): $!\n";
		exec({'repo-remove'} 'repo-remove', "$repo.db.tar.gz", @package_names)
		or die "exec failed: $!\n";
	};
	for_dir($path, sub {{
		my ($file) = @_;
		next if $file !~ $PACKAGE_RE;
		next if !delete $pkghash{$1};
		unlink("$path/$file") or warn "unlink($file): $!\n";
		unlink("$path/$file.sig") or warn "unlink($file.sig): $!\n";
	}});
}

1;
