###
#
# FOnline servers status
#
# Wipe/Rotators
#
###

use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use Irssi;

use JSON;
use LWP;

$VERSION = '0.3';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'fonline',
	'description' => 'FOnline servers status',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
#	'commands'    => 'fonline',
	'modules'     => 'JSON LWP UNIVERSAL',
	'license'     => 'GPL',
);

###
#
# SETTINGS
#
# fonline_status_json
#	Path or address of status.json generated on fodev.net
#
# fonline_cooldown_default (default: 30)
#	Cooldown for [!fonline], in seconds
#
# fonline_cooldown_list (defualt: 900)
#	Cooldown for [!fonline list], in seconds
#
###
#
# PUBLIC COMMANDS
#
# !fonline
#	Status of all (online) FOnline servers
#
# !fonline list
#	
#
###
#
# v0.3
#
#	support for new format
#
# v0.2.2
#	hilights on official channels
#	allows to block requests from specific users
#	no cooldown is set if used by script owner
#
# v0.2.1
#	configuration moved to irssi settings
#	servers status can be read from file or url
#	[!fonline]
#		does not display empty servers (just a total numer of them)
#		display players percentage
#
# v0.2
#	added [!fonline list]
#
# v0.1
#	initial version
#
####

my %cooldown;
my $sub_prefix = 'msg';

my %channels = (
	'forestnet' => {
		# official channels
		'#ashesofphoenix'	=> [ 'phoenix' ],
		'#fo2'			=> [ 'fonline2' ],
		'#fode'			=> [ 'fode' ],
		'#reloaded'		=> [ 'reloaded' ],
		# unofficial channels
		'#sq'			=> [ 'fonline2', 'reloaded' ]
	}
);

my %blocked = (
	'forestnet' => {
		'stration' => 1
	}
);

sub fonline_log($;@)
{
	my( $format, @args ) = @_;

	my $text = sprintf( $format, @args );
	print( CLIENTCRAP sprintf( "-\x02%s\x02- %s", $IRSSI{name}, $text ));
}

sub fonline_cooldown($$)
{
	my( $type, $time ) = @_;

	my $sub = UNIVERSAL::can( __PACKAGE__, sprintf( "%s_%s", $sub_prefix, $type ));
	if( !defined($sub) )
	{
		fonline_log( "Invalid function : %s", $type );
		return;
	}

	Irssi::settings_add_int(
		$IRSSI{name},
		sprintf( "%s_cooldown_%s", $IRSSI{name}, $type ),
		$time
	);
}

sub get_json($)
{
	my( $fileurl ) = @_;
	my $json = undef;

	if( $fileurl =~ /^http\:\/\// || $fileurl =~ /^https\:\/\// )
	{
		my $ua = LWP::UserAgent->new;
		$ua->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));

		my $request = HTTP::Request->new( GET => $fileurl );
		my $response = $ua->request( $request );

		if( !$response->is_success )
			{ fonline_log( "HTML error \x02%d\x02 : \x02%s\x02", $response->code, $response->message ); }
		else
			{ $json = eval{ decode_json( $response->content ); }; }
	}
	else
	{
		if( ! -r $fileurl )
		{
			fonline_log( "File not readable: %s", $fileurl );
			return;
		}

		if( open( my $file, '<', $fileurl ))
		{
			local $/;
			my $json_txt = <$file>;
			close( $file );
			$json = eval{ decode_json( $json_txt ); };
		}
	}

	return( $json );
}

sub get_config_status_json()
{
	my( $config, $status ) = ( undef, undef );

	my $config_json = Irssi::settings_get_str( $IRSSI{name} . '_config_json' );
	my $status_json = Irssi::settings_get_str( $IRSSI{name} . '_status_json' );

	if( !defined($config_json) || $config_json eq "" )
	{
		fonline_log( "Invalid setting [%s_config_json]", $IRSSI{name} );
		return;
	}
	if( !defined($status_json) || $status_json eq "" )
	{
		fonline_log( "Invalid setting [%s_status_json]", $IRSSI{name} );
		return;
	}

	$config = get_json( $config_json );
	$status = get_json( $status_json );

	return( $config, $status );
}

sub say_own
{
	my( $server, $msg, $channel ) = @_;
#	say_check( $server, $msg, "", $channel, Irssi::settings_get_bool( $IRSSI{name} . '_override_cooldown' ));
	say_check( $server, $msg, "", $channel, 1 );
}

sub say_other
{
	my( $server, $msg, $nick, $address, $channel ) = @_;
	say_check( $server, $msg, $nick, $channel, 0 );
}

sub say_check
{
	my( $server, $msg, $nick, $channel, $override ) = @_;

	if( $msg =~ /^[\t\ ]*\!fonline[\t\ ]*([A-Za-z]*)[\t\ ]*([A-Za-z\t\ ]*)$/ )
	{
		my $type = $1;
		my $args = $2; # TODO: pass to sub
		if( !defined($type) || $type eq "" )
			{ $type = "default"; }
		else
			{ $type = lc($type); }

		# check blocked users
		my $net = lc($server->{chatnet});
		my $block = lc($nick);
		if( exists($blocked{$net}{$block}) )
		{
			fonline_log( "Skipped request by %s at %s", $nick, $channel );
			return;
		}

		# find a function
		my $sub = UNIVERSAL::can( __PACKAGE__, sprintf( "%s_%s", $sub_prefix, $type ));
		return if( !defined($sub) );

		# check cooldown
		my $cooldown = Irssi::settings_get_int(
			sprintf( "%s_cooldown_%s", $IRSSI{name}, $type ));

		if( defined($cooldown) && $cooldown > 0 && exists($cooldown{$type}{$channel}) )
		{
			if( !$override && time < $cooldown{$type}{$channel}+$cooldown )
			{
				my $wait = ($cooldown{$type}{$channel}+$cooldown)-time;
				fonline_log( "[%s: %s], %d second%s left%s",
					$type, $channel, $wait, $wait != 1 ? "s" : "",
					$nick ne "" ? " (requested by $nick)" : "" );
				return;
			}
		}

		# get config and status data
		my( $config, $status ) = get_config_status_json();
		if( !defined($config) || !exists($config->{fonline}{config}) )
			{ return; }
		if( !defined($status) || !exists($status->{fonline}{status}) )
			{ return; }

		# pass data to function
		&$sub( $server, $channel, $nick, $config, $status, $override );

		if( !$override )
		{
			# set cooldown
			$cooldown{$type}{$channel} = time;
		}
	}
}

sub msg_default # !fonline
{
	my( $server, $channel, $nick, $config, $status, $override ) = @_;

	return if( !defined($config) || !exists($config->{fonline}{config}) );
	return if( !defined($status) || !exists($status->{fonline}{status}) );

	$config = $config->{fonline}{config};
	$status = $status->{fonline}{status};

	if( $status->{servers} > 0 )
	{
		my( $text, $empty, $first ) = ( "", 0, 1 );

		my %tags;
		foreach my $network ( keys( %channels ))
		{
			my $net = lc($network);
			if( $net eq lc($server->{chatnet}) )
			{
				my $chan = lc($channel);
				if( exists($channels{$net}{$chan}) )
				{
					%tags = map { $_ => 1 } @{ $channels{$net}{$chan} };
				}
			}
		}

		foreach my $key ( sort{ $config->{server}{$a}{name} cmp $config->{server}{$b}{name} } keys %{ $config->{server} } )
		{
			my $bold = 0;
			$bold = 1 if( exists($tags{$key}) );

			next if( !exists($status->{server}{$key}) );

			if( $status->{server}{$key}{checked} > 0 &&
				$status->{server}{$key}{uptime} > 0 )
			{
				if( $status->{server}{$key}{players} > 0 )
				{
					$text .= sprintf( "%s%s%s: %d (%.1f%%)%s",
						$first ? "" : ", ",
						$bold ? "\x02" : "",
						$config->{server}{$key}{name},
						$status->{server}{$key}{players},
						(100*$status->{server}{$key}{players})/$status->{players},
						$bold ? "\x02" : ""
					);
					$first = 0;
				}
				else
					{ $empty++; }
			}
		}

		$text = sprintf( "%sServer%s: %d%s, Player%s: %d [%s]",
			$nick ne "" ? "\x02$nick\x02: " : "",
			$status->{servers} > 1 ? "s" : "", $status->{servers},
			$empty > 0 ? " ($empty empty)" : "",
			$status->{players} > 1 ? "s" : "", $status->{players},
			$text
		);

		if( $nick ne "" )
		{
			fonline_log( "Request by %s at %s", $nick, $channel );
		}
		$server->command( sprintf( "msg %s %s", $channel, $text ));
	}
	else
	{
		$server->command( sprintf( "msg %s %sNo (known) FOnline servers online",
			$channel, $nick ne "" ? "$nick: " : "" ));
	}
}

sub msg_list
{
	my( $server, $channel, $nick, $config, $status, $override ) = @_;

	return if( !defined($config) || !exists($config->{fonline}{config}) );
	return if( !defined($status) || !exists($status->{fonline}{status}) );

	$config = $config->{fonline}{config};
	$status = $status->{fonline}{status};

	my( @known, @unknown, @closed );

	foreach my $key ( sort{ $config->{server}{$a}{name} cmp $config->{server}{$b}{name} } keys %{ $config->{server} } )
	{
		if( $config->{server}{$key}{closed} )
		{
			push( @closed, "\x02" . $config->{server}{$key}{name} . "\x02" );
		}
		elsif( $status->{server}{$key}{checked} > 0 )
		{
			my $text = sprintf( "\x02%s\x02 :: Address: \x02%s\x02 Port: \x02%d\x02",
				$config->{server}{$key}{name},
				$config->{server}{$key}{host},
				$config->{server}{$key}{port}
			);

			if( $status->{server}{$key}{uptime} < 0 )
			{
				$text .= " (currently offline)";
			}

			push( @known, $text );
		}
		# not checked servers / placeholders
		else
		{
			push( @unknown, "\x02" . $config->{server}{$key}{name} . "\x02" );
		}
	}

	# print results

	if( scalar(@known) > 0 )
	{
		$server->command( "msg $channel Servers with known address:" );
		foreach my $text ( @known )
		{
			$server->command( sprintf( "msg %s  %s", $channel, $text ));
		}
	}

	if( scalar(@unknown) > 0 )
	{
		my $text = join( ', ', @unknown );
		$server->command( "msg $channel Servers without known address (planned, closed beta, etc.):" );
		$server->command( sprintf( "msg %s  %s", $channel, $text ));
	}

	if( scalar(@closed) > 0 )
	{
		my $text = join( ', ', @closed );
		$server->command( "msg $channel Closed servers:" );
		$server->command( sprintf( "msg %s  %s", $channel, $text ));
	}

	my $total = scalar(@known)+scalar(@unknown)+scalar(@closed);
	$server->command( sprintf( "msg %s Total: %d server%s",
		$channel, $total, $total != 1 ? "s" : "" ));
}

sub msg_help
{
	my( $server, $channel, $nick, $json, $override ) = @_;

	return if( $nick eq "" );

	$server->command( sprintf( "msg %s %s: Soon.", $channel, $nick ));
}

#Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_override_cooldown', 0 );
Irssi::settings_add_str( $IRSSI{name}, $IRSSI{name} . '_config_json', 'http://fodev.net/status/data/config.json' );
Irssi::settings_add_str( $IRSSI{name}, $IRSSI{name} . '_status_json', 'http://fodev.net/status/data/status.json' );
fonline_cooldown( 'default', 30 );
fonline_cooldown( 'list',    60*15 );
fonline_cooldown( 'help',    60 );

Irssi::signal_add( 'message own_public', 'say_own' );
Irssi::signal_add( 'message public',     'say_other' );

#fonline_log( "Loaded" );
