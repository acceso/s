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



sub
default_options
{

	return {
		hostlist	=> "${Bin}/hostlist",
		sockbase	=> "$ENV{HOME}/.libnet-openssh-perl",
		xtermtitle	=> 0,
		keysdir		=> "${Bin}/keys",
		ssh_verbose	=> 0,
		ssh_debug	=> 0,
		ssh_debug_extra	=> 0,
		expect_debug	=> 0,
		shell		=> 'bash --norc',
		su_command	=> "su -l",
		su_pass_mod	=> '',
		su_pass_default	=> '',
		shell_init	=> '',
 		profile_file	=> "${Bin}/bash_profile",
 		profile_file_s	=> "${Bin}/bash_profile_noninteractive",
 		profile_host	=> "${Bin}/profiles/%s",
 		profile_host_regex => 0,
		history_file	=> "${Bin}/bash_history",
 		history_host	=> "${Bin}/history/%s",
 		history_host_regex => 0,
		ps1		=> '\u@\h:\w\$ ',
		tty_restore	=> "sane -brkint -imaxbel iutf8",
		scripts_dir	=> "${Bin}/scripts",
		scripts_begin	=> "",
		scripts_end	=> "exit",
	};

}



# A bit messy, but it should work:
sub
read_config
{
	my $h = shift; 
	my $file = shift;

	my @runaway = ( );

	open my $f, "< ", $file or return $h;

	while( my $l = <$f> ) {
		chomp $l;

		while( $l =~ /\\$/ ) {
			$l .= <$f>;
			chomp $l;
		}

		my $var;
		my $val;

		if( @runaway ) {
			my $quotation = substr( $runaway[1], 0, 1 );
			if( $l =~ /^(.*${quotation})\s*$/ ) {
				push @runaway, $1;

				$var = shift @runaway;
				$val = join "", @runaway;

				@runaway = ( );
			} else {
				push @runaway, $l . "\n";
				next;
			}
		} else {
			next if $l =~ /^\s*(#|$)/;

			( $var, $val ) = split /\s*=\s*/, $l, 2;
		}

		if( $val =~ /^["']/ ) {
			if( $val =~ /\A"((?:.*|\n)*)"\z/m ) {
				$val = qq/"${1}"/;
			} elsif( $val =~ /\A'((?:.*|\n)*)'\z/m ) {
				$val = qq/'${1}'/;
			} else {
				push @runaway, $var, $val . "\n";
				next;
			}
		} else {
			# Use double quotes for unquoted strings:
			$val = qq/"${val}"/;
		}

		my $finalval;

		if( $val =~ /^["']?(false|0|no|off)?["']?$/ ) {
			$finalval = '';
		} elsif ( $val =~ /^["']?\/(.*)\/["']?/ ) {
			$finalval = $1;
		} else {
			#print $val, "\n" if $val and $val =~ /[^\\]\$/;
			$finalval = eval $val or die "Invalid value in config file: " . $@;
			#print $finalval, "\n\n" if $val and $val =~ /[^\\]\$/;
		}

		$h->{$var} = $finalval;

	}

	close $f;

	#print Dumper $h;

	return $h;
}



sub
get_ssh_hosts
{
	my $file = shift;
	my @names = @_;

	my $hl;
	open $hl, "<", $file . ".custom" or do {
		open $hl, "<", $file or die "Can't open hosts file: $!";
	};

	my @names_exp = ( );
	foreach( @names ) {
		if( $_ =~ /^\/(.*)\/$/ ) {
			push @names_exp, qr/${1}/;
		} else {
			push @names_exp, $_;
		}
	}

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

		next unless $h_alias ~~ @names_exp;

		my @extra = ( );
		if( $h_entry[4] ) {
			@extra = @h_entry[4 .. $#h_entry];
		} elsif( $global_context[4] ) {
			@extra = @global_context[4 .. $#global_context];
		}

		push @hostlist, {
			alias		=> $h_alias,
			user		=> $h_entry[0] || $global_context[0] || "",
			hostname	=> ( $h_entry[1] || $global_context[1] || "" ) . 
						$h_alias .
						( $h_entry[2] || $global_context[2] || "" ),
			mod_pass	=> $h_entry[3] || "",
			extra		=> [ @extra ],
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



sub
get_supass_mod
{
	my( $config, $host ) = @_;

	return $config->{su_pass_default} || "" unless $config->{su_pass_mod};

	my $modname = $config->{su_pass_mod};

	eval "require " . $modname;

	print $@ if $@;

	return $modname->get_supass( $config, $host );

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
		#warn "Can't open profile file " . $file . ": " . $!;
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

	return;
}



my $config = default_options;

read_config $config, "${Bin}/config";
read_config $config, "${Bin}/config.custom";



my %cmdopts;

getopts( 's:n', \%cmdopts );


@ARGV || die "Need regular expression/s or host/s.";



mkdir $config->{sockbase} or die "Can't create socket directory."
	unless -d $config->{sockbase};



foreach my $host ( get_ssh_hosts( $config->{hostlist}, @ARGV ) ) { 

	my $interactive_session = 1;

	if( $cmdopts{n} ) {
		print $host->{alias} . " " . $host->{hostname} . "\n";
		#print Dumper $host;
		next;
	}

	$interactive_session = 0 if $cmdopts{s};

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
		# Non-interactive sessions don't have a tty:
		push @ssh_cmd, ( $interactive_session ? "stty -echo ; " : "" ) . "PS1='' " . $config->{shell};
	} else {
		push @ssh_cmd, split( /\s+/, $config->{su_command} ), "-c", "PS1='' " . $config->{shell};
	}


	my( $pty, $pid ) = $ssh->open2pty( $interactive_session ? { } : { tty  => 0, }, @ssh_cmd );


	my $expect = expect_init $config, $pty;


	$SIG{WINCH} = \&winch;
	sub winch {
		$expect->slave->clone_winsize_from( \*STDIN );
		kill WINCH => $expect->pid if $expect->pid;
		$SIG{WINCH} = \&winch;
		return;
	};


	if( $host->{user} ne "root" ) {
		$expect->expect( 2,
			[ qr/^Password: / => sub { shift->send( get_supass_mod( $config, $host ) . "\n" ); } ],
			) or do { warn "Expect timeout."; next; }
	} else {
		$expect->stty( qw(raw) ) if $interactive_session;
	}

	if( $config->{shell_init} ) {
		$config->{shell_init} .= "\n" unless $config->{shell_init} =~ /\n$/m;
		$expect->send( "unset PS1; " . $config->{shell_init} );
	}


	file2expect $expect, $config->{profile_file}, " " if $config->{profile_file};

	if( $config->{profile_host} ) {
		my $profile_file = sprintf $config->{profile_host}, $host->{alias};
		file2expect $expect, $profile_file, " " if -r $profile_file;

		if( $config->{profile_host_regex} ) {
			# Filters the files that match the expression:
			foreach( grep qr/($config->{profile_host_regex})/, glob sprintf $config->{profile_host}, '*' ) {
				# Avoid running the file that we ran previously:
				next if $_ eq $profile_file;

				file2expect $expect, $_, " " if -r $_;
			}
		}
	}

	if( $cmdopts{s} ) {
		my $scriptfile;

		if( -r $cmdopts{s} ) {
			$scriptfile = $cmdopts{s};
		} else {
			$scriptfile = $config->{scripts_dir} . "/" . $cmdopts{s};
			die "Can't find script " . $cmdopts{s} unless -r $scriptfile;
		}

		file2expect $expect, $config->{profile_file_s}, " " if $config->{profile_file_s};

		$expect->send( $config->{scripts_begin} . "\n" ) if $config->{scripts_begin};

		file2expect $expect, $scriptfile;

		$expect->send( $config->{scripts_end} . "\n" ) if $config->{scripts_end};

	} else {
		file2expect $expect, $config->{history_file}, " history -s ", 1 if $config->{history_file};
		if( $config->{history_host} ) {
			my $history_file = sprintf $config->{history_host}, $host->{alias};
			file2expect $expect, $history_file, " history -s ", 1 if -r $history_file;

			if( $config->{history_host_regexp} ) {
				# Filters the files that match the expression:
				foreach( grep qr/($config->{history_host_regexp})/, glob sprintf $config->{history_host}, '*' ) {
					# Avoid running the file that we ran previously:
					next if $_ eq $history_file;

					file2expect $expect, $_, " history -s ", 1 if -r $_;
				}
			}

		}
	}


	$expect->send( " export PS1='" . $config->{ps1} . "'; stty " . $config->{tty_restore} . "\n" );

	$expect->interact();


	$ssh->error and do { warn "error: " . $ssh->error; next; };

}




