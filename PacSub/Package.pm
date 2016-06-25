package PacSub::Package;

use strict;
use warnings;

sub new($$$$) {
	my ($class, $repo, $package, $version) = @_;
	return bless {
		repo => $repo,
		name => $package,
		version => $version
	}, $class;
}

1;
