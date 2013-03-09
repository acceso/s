#!/usr/bin/perl

# by Jose, 2012, 2013

use warnings;
use strict;

use v5.10;


use Data::Dumper;
use FindBin qw( $Bin );
use Getopt::Std;

BEGIN { push( @INC, "${Bin}", "${Bin}/lib" ); };

use Net::OpenSSH;
use Expect;



# A bit messy, but it should work:
sub
read_config
{
	my $file = shift;

	# default options:
	my $h = {
		hostlist	=> "${Bin}/hostlist",
		sockbase	=> "$ENV{HOME}/.libnet-openssh-perl",
		xtermtitle	=> 0,
		keysdir		=> "${Bin}/keys",
		ssh_verbose	=> 0,
		ssh_debug	=> 0,
		ssh_debug_extra	=> 0,
		expect_debug	=> 0,
		shell		=> 'bash',
		su_command	=> "su -l",
		shell_init	=> '',
 		profile_file	=> "${Bin}/bash_profile",
		history_file	=> "${Bin}/bash_history",
		tty_restore	=> "sane -brkint -imaxbel iutf8",
		scripts_dir	=> "${Bin}/scripts",

	};

	my @runaway = ( );

	open my $f, "< " . $file or return $h;

	while( my $l = <$f> ) {
		chomp $l;

		while( $l =~ /\\$/ ) {
			$l .= <$f>;
			chomp $l;
		}

		if( @runaway ) {
			my $quotation = substr( $runaway[1], 0, 1 );
			if( $l =~ /^(.*)${quotation}\s*$/ ) {
				push @runaway, $1;

				$runaway[1] = substr $runaway[1], 1;

				my $var = shift @runaway;
				$h->{$var} = join "", @runaway;
				@runaway = ( );
			} else {
				push @runaway, $l . "\n";
				next;
			}
		} else {
			next if $l =~ /^\s*(#|$)/;

			my( $var, $val ) = split /\s*=\s*/, $l, 2;

			if( $val =~ /^(["'])/ ) {
				if( $val =~ /^$1(.*)$1$/ ) {
					$val = qq/"${1}"/
				} else {
					push @runaway, $var, $val . "\n";
					next;
				}
			} else {
				# If the command has double quotes inside, this will fail
				# but if we use single quotes there is no interpolation...
				$val = qq/"${val}"/;
			}

			my $finalval;

			if( $val =~ /^"(false|0|no|off)"$/ ) {
				$finalval = '';
			} else {
				$finalval = eval $val or die "Invalid value in config file: " . $@;
			}

			$h->{$var} = $finalval;

		}

	}

	close $f;

	#print Dumper $h;

	return $h;
}



sub
get_ssh_hosts
{
	my $file = shift;
	my $name = shift;

	my $using_regexp = 0;

	if( $name =~ /^\/(.*)\/$/ ) {
		$using_regexp = 1;
		$name = qr/${1}/;
	}

	open my $hl, "<", $file
		or die "Can't open hosts file: $!";

	my @hostlist = ( );
	my @global_context = ( );

	while( <$hl> ) {
		next if /(^\s*(#|$))/;
		chomp;

		my @h_entry = split /\s*,\s*/;

		my $h_alias = shift @h_entry;

		if( $h_alias =~ /^GLOBAL$/ ) {
			@global_context = @h_entry;
			next;
		}

		if( $using_regexp ) {
			next unless $h_alias =~ $name;
		} else {
			next unless $h_alias eq $name;
		}

		push @hostlist, {
			alias		=> $h_alias,
			user		=> $h_entry[0] || $global_context[0] || "",
			hostname	=> ( $h_entry[1] || $global_context[1] || "" ) . 
						$h_alias .
						( $h_entry[2] || $global_context[2] || "" ),
		};

	}

	close $hl;

	return @hostlist;

}



sub
get_ssh_opts
{
	my( $config, $host ) = @_;

	my %opts = (
		user			=> $host->{user},
		default_ssh_opts	=> [
			# Allow agent forwarding
			"-A",
			# Send keepalives
			-o	=> "ServerAliveInterval=60",
			-o	=> "ServerAliveCountMax=6",
			# TODO: doesn't work with master/slave ssh, see function process_escapes() in:
			# http://www.openbsd.org/cgi-bin/cvsweb/src/usr.bin/ssh/clientloop.c?rev=HEAD;content-type=text%2Fplain
			#-e => '~',
		],
		ctl_path		=> $config->{sockbase} . "/master-" . $host->{user} . '@' . $host->{hostname} . ":22",
		async			=> 1,
	);
	$opts{external_master} = 1 if -r $opts{ctl_path};

	if( $config->{ssh_verbose} ) {
		if( $config->{ssh_verbose} =~ /\d+/ ) {
			push $opts{default_ssh_opts}, "-" . "v" x $config->{ssh_verbose};
		} else {
			push $opts{default_ssh_opts}, "-vvv";
		}
	}

	my $keyfile = $config->{keysdir} . "/" . $host->{user};

	if( -r $keyfile ) {
		$opts{key_path} = $keyfile;
	} elsif( -r $keyfile . ".priv" ) {
		$opts{key_path} = $keyfile . ".priv";
	}

	return \%opts;

}



sub
ssh_launch_master
{
	my( $config, $host, $opts ) = @_;

	$opts->{master_opts} = [
		"-A",	# Allow agent forwarding (needed in both master and slave).
		"-f",	# -f: forks the client, note Net::OpenSSH doens't like this very much.
		"-n",	# -n: prevents reading from stdin.
		-c 	=> "blowfish-cbc", # Speed things up.
		-o 	=> "ControlPersist=1800", # Disconnect idle sessions.
	];

	if( $config->{ssh_verbose_master} ) {
		if( $config->{ssh_verbose_master} =~ /\d+/ ) {
			push $opts->{master_opts}, "-" . "v" x $config->{ssh_verbose_master};
		} else {
			push $opts->{master_opts}, "-vvv";
		}
	}

	my $ssh = Net::OpenSSH->new( $host->{hostname}, %$opts );
	$ssh->error and do {
		warn "Couldn't establish master SSH connection: " . $ssh->error;
		return;
	};

	delete $opts->{master_opts};

	$ssh->wait_for_master( );

	return;

}



# TODO:
sub
get_supass
{
	my( $host ) = @_;

	return "ejem";
}



sub
expect_init
{
	my $config = shift;
	my $pty = shift;

	my $expect = Expect->init( $pty );

	if( $config->{expect_debug} ) {
		if( $config->{expect_debug} =~ /\d+/ ) {
			$expect->debug( $config->{expect_debug} );
		} else {
			$expect->debug( 2 );
		}

		$expect->exp_internal( 1 );
	}

	$expect->slave->stty( qw(-echo) );
	$expect->slave->clone_winsize_from( \*STDIN );

	return $expect;
}



sub
file2expect
{
	my $expect = shift;
	my $file = shift;
	my $prefix = shift || "";
	my $quote = shift || 0;

	unless( -r $file ) {
		warn "Can't open profile file " . $file . ": " . $!;
		return;
	}

	open my $f, '<', $file
		or die "Can't open ${file}: $!";

	while( <$f> ) {
		chomp;
		next unless $_;
		next if /^\s*#/;
		if( $quote ) {
			$expect->send( qq(${prefix}"$_"\n) );
		} else {
			$expect->send( "${prefix}$_\n" );
		}
	}

	close $f;

}



my $config = read_config "${Bin}/config";


my %cmdopts;

getopts( 's:n', \%cmdopts );


my $h_name = $ARGV[0] || die "Need a regular expression or host.";



mkdir $config->{sockbase} or die "Can't create socket directory."
	unless -d $config->{sockbase};



foreach my $host ( get_ssh_hosts( $config->{hostlist}, $h_name ) ) { 

	if( $cmdopts{n} ) {
		print $host->{alias} . " " . $host->{hostname} . "\n";
		#print Dumper $host;
		next;
	}

	# Set xterm title:
	print "\033]0;ssh: " . $host->{hostname} . "\007" if $config->{xtermtitle};


	my $opts = get_ssh_opts $config, $host;


	$Net::OpenSSH::debug |= 16 if $config->{ssh_debug};
	$Net::OpenSSH::debug = -1 if $config->{ssh_debug_extra};


	unless( $opts->{external_master} ) {
		ssh_launch_master( $config, $host, $opts );
		$opts->{external_master} = 1;
	}


	my $ssh = Net::OpenSSH->new( $host->{hostname}, %$opts );
	$ssh->error and do {
		warn "Couldn't establish SSH connection: " . $ssh->error;
		next;
	};


	my @ssh_cmd = ( );

	if( $host->{user} eq "root" ) {
		push @ssh_cmd, "stty -echo ; PS1='' " . $config->{shell};
	} else {
		push @ssh_cmd, split( /\s+/, $config->{su_command} ), "-c", "PS1='' " . $config->{shell};
	}

	my( $pty, $pid ) = $ssh->open2pty( @ssh_cmd );


	my $expect = expect_init $config, $pty;


	$SIG{WINCH} = \&winch;
	sub winch {
		$expect->slave->clone_winsize_from( \*STDIN );
		kill WINCH => $expect->pid if $expect->pid;
		$SIG{WINCH} = \&winch;
	};


	if( $host->{user} ne "root" ) {
		$expect->expect( 2,
			[ qr/^Password: / => sub { shift->send( get_supass( $host ) . "\n" ); } ],
			) or do { warn "Expect timeout."; next; }
	} else {
		$expect->stty( qw(raw) );
	}

	if( $config->{shell_init} ) {
		$config->{shell_init} .= "\n" unless $config->{shell_init} =~ /\n$/m;
		$expect->send( $config->{shell_init} );
	}


	file2expect $expect, $config->{profile_file}, " " if $config->{profile_file};


	if( $cmdopts{s} ) {
		my $scriptfile;

		if( -r $cmdopts{s} ) {
			$scriptfile = $cmdopts{s};
		} else {
			$scriptfile = $config->{scripts_dir} . "/" . $cmdopts{s};
			die "Can't find script " . $cmdopts{s} unless -r $scriptfile;
		}

		file2expect $expect, $scriptfile;

		$expect->send( "exit\n" );

	} else {
		file2expect $expect, $config->{history_file}, " history -s ", 1 if $config->{history_file};
	}


	$expect->send( ' export PS1="' . $host->{alias} . ' \\w # "; stty ' . $config->{tty_restore} . "\n" );

	$expect->interact();


	$ssh->error and do { warn "error: " . $ssh->error; next; };

}




