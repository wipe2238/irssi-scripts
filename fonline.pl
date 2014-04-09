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
use POSIX qw( floor strftime );

$VERSION = '0.3.1';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'fonline',
	'description' => 'FOnline servers status',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
#	'commands'    => 'fonline',
	'modules'     => 'JSON LWP POSIX UNIVERSAL',
	'license'     => 'GPL',
);

###
#
# SETTINGS
#
# fonline_data
#	Path or address of directory containing status data
#
# fonline_config_json
#	Main configuration file (without path/address)
#
# fonline_cooldown_status (default: 30)
#	Cooldown for [!fonline] and [!fonline status], in seconds
#
# fonline_cooldown_server (default: 30)
#	Cooldown for [!fonline server], [!status] and [!s], in seconds
#
# fonline_cooldown_info (default: 60)
#	Cooldown for [!fonline info], in seconds
#
# fonline_cooldown_list (defualt: 900)
#	Cooldown for [!fonline list], in seconds
#
# fonline_cooldown_help (default: 60)
#	Cooldown for [!fonline help], in seconds
#
# NOTE:
#	When script is running, each channel have own cooldown for requests
#
###
#
# PUBLIC COMMANDS
#
# !fonline
# !fonline status [option]
#	Status of all (online) FOnline servers
#	Options:
#		all	does not hide empty servers
#
# !fonline server <server_id>
# !status
# !s
#	Short status of single server
#	!s and !status shortcuts works only on channels defined in %status_channels
#
# !fonline info <server_id>
#	Basic informations about given server
#
# !fonline list
#	Lists all known servers
#
###
#
# v0.3.1
#
#	more integration with fodev-status
#	added [!fonline info]
#	added [!fonline server]
#	added fonline_data setting
#	changed meaning of fonline_config_json setting
#	removed fonline_status_json setting
#
# v0.3
#
#	support for new format
#	hilight number of players if it's equal or greater than 1000
#	default sub changed from 'default' to 'status'
#	added [!fonline status all] to list empty servers
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
		# script home channel
		'#sq'			=> [ 'fonline2', 'reloaded' ]
	}
);

my %status_channels = (
	'forestnet' => {
		'#2238'			=> 'fo2238',
		'#ashesofphoenix'	=> 'phoenix',
		'#fo2'			=> 'fonline2'
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

# from https://github.com/rotators/fodev-status/blob/master/FOstatus.pm
sub config_path($$;%) 
{
	my( $config, $name, %args ) = @_;
	my $result = undef;

	if( defined($config) && exists($config->{files}) )
	{
		if( exists($config->{files}{$name}) )
		{
			$result = $config->{files}{$name};
			if( exists($config->{dirs}) )
			{
				foreach my $dir ( keys( $config->{dirs} ))
				{
					my $from = '{DIR:'.$dir.'}';
					my $to = $config->{dirs}{$dir};
					$result =~ s!$from!$to!g;
				}
			}
			if( scalar(keys(%args)) > 0 )
			{
				foreach my $key ( keys( %args ))
				{
					my $from = '{'.$key.'}';
					my $to = $args{$key};
					$result =~ s!$from!$to!g;
				}
			}
		}
	}

	return( $result );
}

sub get_json($;$)
{
	my( $fileurl, $id ) = @_;
	my $json = undef;

	if( $fileurl =~ /^http\:\/\// || $fileurl =~ /^https\:\/\// )
	{
		my $ua = LWP::UserAgent->new;
		$ua->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));
		$ua->timeout( 5 );

		my $request = HTTP::Request->new( GET => $fileurl );
		my $response = $ua->request( $request );

		if( !$response->is_success )
		{
			fonline_log( "HTML error [%s] \x02%d\x02 : \x02%s\x02",
				$fileurl, $response->code, $response->message );
		}
		else
			{ $json = eval{ decode_json( $response->content ); }; }
	}
	else
	{
		if( ! -r $fileurl )
		{
			fonline_log( "File not readable: %s", $fileurl );
			return( undef );
		}

		if( open( my $file, '<', $fileurl ))
		{
			local $/;
			my $json_txt = <$file>;
			close( $file );
			$json = eval{ decode_json( $json_txt ); };
		}
	}

	if( defined($json) && defined($id) )
	{
		return( undef ) if( !exists($json->{fonline}) );
		return( undef ) if( !exists($json->{fonline}{$id}) );
		$json = $json->{fonline}{$id};
	}

	return( $json );
}

sub get_json_by_id($$)
{
	my( $config, $id ) = ( @_ );

	return( undef ) if( !defined($config) || !defined($id) );

	my $data = Irssi::settings_get_str( $IRSSI{name} . '_data' );
	if( !defined($data) || $data eq "" )
	{
		fonline_log( "Invalid setting [%s_data]", $IRSSI{name} );
		return( undef );
	}

	my $json = undef;

	my $path = config_path( $config, $id );
	if( defined($path) )
	{
		$json = get_json( sprintf( "%s/%s", $data, $path ), $id );
	}

	return( $json );
}

sub get_config_status_json()
{
	my( $config, $status ) = ( undef, undef );

	my $data = Irssi::settings_get_str( $IRSSI{name} . '_data' );
	my $config_json = Irssi::settings_get_str( $IRSSI{name} . '_config_json' );

	if( !defined($data) || $data eq "" )
	{
		fonline_log( "Invalid setting [%s_data]", $IRSSI{name} );
		return;
	}

	if( !defined($config_json) || $config_json eq "" )
	{
		fonline_log( "Invalid setting [%s_config_json]", $IRSSI{name} );
		return;
	}

	$config = get_json( sprintf( "%s/%s", $data, $config_json ), 'config' );
	if( defined($config) )
		{ $status = get_json_by_id( $config, 'status' ); }

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

	# support !s and !status by editing incoming message
	if( $msg =~ /^[\t\ ]*\!s[\t\ ]*$/ || $msg =~ /^[\t\ ]*\!status[\t\ ]*$/ )
	{
		my $net = lc($server->{chatnet});
		my $chan = lc($channel);
		if( exists($status_channels{$net}{$chan}) )
			{ $msg = '!fonline server '.$status_channels{$net}{$chan}; }
	}

	if( $msg =~ /^[\t\ ]*\!fonline[\t\ ]*([A-Za-z]*)[\t\ ]*([A-Za-z0-9_\t\ ]*)$/ )
	{
		my $type = $1;
		my $args = $2;
		if( !defined($type) || $type eq "" )
			{ $type = "status"; }
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

		# check cooldown (if not triggered by self)
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
		return if( !defined($config) );
		return if( !defined($status) );

		# pass data to function
		my @arguments = split( /\t\ /, $args );
		&$sub( $server, $channel, $nick, $config, $status, $override, @arguments );

		# set cooldown (if not triggered by self)
		if( !$override )
		{
			$cooldown{$type}{$channel} = time;
		}
	}
}

sub msg_status
{
	my( $server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	my $all = 0;
	if( scalar(@arguments) )
	{
		$all = ($arguments[0] eq 'all');
	}

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
			next if( !exists($status->{server}{$key}) );

			my $bold = 0;
			$bold = 1 if( exists($tags{$key}) );

			if( $status->{server}{$key}{checked} > 0 &&
				$status->{server}{$key}{uptime} > 0 )
			{
				if( $all || $status->{server}{$key}{players} > 0 )
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

		$text = sprintf( "%sServer%s: %d%s, Player%s: %s%d%s [%s]",
			$nick ne "" ? "\x02$nick\x02: " : "",
			$status->{servers} > 1 ? "s" : "", $status->{servers},
			$empty > 0 ? " ($empty empty)" : "",
			$status->{players} > 1 ? "s" : "",
			$status->{players} >= 1000 ? "\x02" : "",
			$status->{players},
			$status->{players} >= 1000 ? "\x02" : "",
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

sub msg_server
{
	my( $server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	return if( !scalar(@arguments) );

	my $key = $arguments[0];
	return if( !exists($config->{server}{$key}) );

	my $average = get_json_by_id( $config, 'average_short' );
	$average = $average->{server}{$key} if( defined($average) );

	my $lifetime = get_json_by_id( $config, 'lifetime' );
	$lifetime = $lifetime->{server}{$key} if( defined($lifetime) );

	sub sec2time($;$)
	{
		my( $seconds, $limit ) = @_;
		my @text;
		foreach my $extract (
			[ 'year',	60 * 60 * 24 * 7 * 4 * 12 ],
			[ 'month',	60 * 60 * 24 * 7 * 4 ],
			[ 'week',	60 * 60 * 24 * 7 ],
			[ 'day',	60 * 60 * 24 ],
			[ 'hour',	60 * 60 ],
			[ 'minute',	60 ],
#			[ 'second',	1 ]
		)
		{
			my $need = @{$extract}[1];
			
			if( $seconds >= $need )
			{
				my $result = floor( $seconds / $need );
				$seconds -= $result * $need;
				if( !$limit || scalar(@text) < $limit )
				{
					push( @text, sprintf( "%d %s%s",
						$result, @{$extract}[0], $result > 1 ? 's' : '' ));
				}
			}
		}
		my $stext = undef;
		if( scalar(@text) == 0 )
			{ $stext = 'some seconds'; }
		elsif( scalar(@text) > 1 )
		{
			my $last = pop( @text );
			$stext = join( ', ', @text );
			$stext .= sprintf( " and %s", $last );
		}
		else
			{ $stext = $text[0] };

		return( $stext );
	}

	my $text = 'Server is ';
	if( exists($status->{server}{$key}) && $status->{server}{$key}{uptime} >= 0 )
	{
		my $since;
		if( $status->{server}{$key}{uptime} < 86400 )
			{ $since = sec2time( $status->{server}{$key}{uptime}, 2 ); }
		else
		{
			$since =  strftime( "%d %B %Y",
				localtime( time() - $status->{server}{$key}{uptime} ));
		}

		$text .= sprintf( "\x02online\x02 since %s; players: \x02%d\x02",
			$since, $status->{server}{$key}{players} );

		$text .= sprintf( " \x02[\x02%s:%s\x02]\x02",
			$config->{server}{$key}{host},
			$config->{server}{$key}{port} );
	}
	elsif( exists($config->{server}{$key}{closed}) && $config->{server}{$key}{closed} )
	{
		$text .= "\x02closed\x02";

		if( defined($lifetime) )
		{
			my $now = strftime( "%d %B %Y", localtime(time) );
			my $seen = strftime( "%d %B %Y", localtime($lifetime->{seen} ));
			$text .= sprintf( " since %s", $seen )
				if( $now ne $seen );
		}
	}
	elsif( exists($config->{server}{$key}{singleplayer}) && $config->{server}{$key}{singleplayer} )
	{
		$text = sprintf( "\x02%s\x02 is a singleplayer game; ", $config->{server}{$key}{name} );
		foreach my $option ( 'website', 'link' )
		{
			if( exists($config->{server}{$key}{$option}) )
			{
				$text .= sprintf( " see \x02%s\x02 for details", $config->{server}{$key}{$option} );
				last;
			}
		}
	}
	else
	{
		$text .= "\x02offline\x02";
		my $off = int(0);
		if( defined($status->{server}{$key}{seen}) && $status->{server}{$key}{seen} > 0 )
			{ $off = time() - $status->{server}{$key}{seen}; } # 24h

		if( $off > 0 && $off < 86400 ) # 24h
			{ $text .= sprintf( " since %s", sec2time( $off )); }
		elsif( defined($lifetime) )
		{
			my $now = strftime( "%d %B %Y", localtime(time) );
			my $seen = strftime( "%d %B %Y", localtime($lifetime->{seen} ));
			$text .= sprintf( " since %s", $seen )
				if( $now ne $seen );
		}
	}

	$text = sprintf( "\x02%s\x02: %s", $nick, $text ) if( $nick ne "" );
	$server->command( sprintf( "msg %s %s", $channel, $text ));	
}

sub msg_info
{
	my( $irc_server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	return if( !scalar(@arguments) );
	my $fid = $arguments[0];
	return if( !exists($config->{server}{$fid}) );
	my $server = $config->{server}{$fid};
	my $closed = (exists($server->{closed}) && $server->{closed});
	my $singleplayer = (exists($server->{singleplayer}) && $server->{singleplayer});

	my $lifetime = get_json_by_id( $config, 'lifetime' );
	$lifetime = $lifetime->{server}{$fid} if( defined($lifetime) );

	my @text;

	if( $singleplayer )
		{ push( @text, sprintf( "\x02%s\x02 (singleplayer)", $server->{name} )); }
	elsif( !$singleplayer && defined($lifetime) )
	{
		my $tracked = sprintf( "%s",
			strftime( "%d %B %Y", localtime($lifetime->{introduced}) ));

		if( $closed )
		{
			$tracked .= sprintf( " to %s",
				strftime( "%d %B %Y", localtime($lifetime->{seen}) ));
		}

		push( @text, sprintf( "\x02%s\x02 (tracked since %s)", $server->{name}, $tracked ));
	}
	else
		{ push( @text, sprintf( "\x02%s\x02", $server->{name} )); }

	if( !$singleplayer )
	{
		my $txt = "\x02Status\x02:      ";
		if( $closed )
			{ $txt .= 'Closed'; }
		elsif( exists($status->{server}{$fid}) && $status->{server}{$fid}{uptime} >= 0 )
		{
			# TODO: since
			$txt .= sprintf( "Online (players: %s)",
				$status->{server}{$fid}{players} > 0
					? $status->{server}{$fid}{players}
					: 'none' );
		}
		else
		{
			$txt .= 'Offline';
			if( exists($lifetime->{seen}) )
			{
				my $now = strftime( "%d %B %Y", localtime(time) );
				my $seen = strftime( "%d %B %Y", localtime($lifetime->{seen} ));
				$txt .= sprintf( " since %s", $seen )
					if( $now ne $seen );
			}
		}

		push( @text, $txt );
	}

	if( !$singleplayer && !$closed &&
		exists($server->{host}) && exists($server->{port}) &&
		uc($server->{host}) ne 'UNKNOWN' &&
		$server->{port} > 1024 && $server->{port} < 65535 )
	{
		push( @text, sprintf( "\x02Address\x02:     %s : %s",
			$server->{host}, $server->{port} ));
	}

	foreach my $option ( 'website', 'link' )
	{
		if( exists($server->{$option}) )
		{
			push( @text, sprintf( "\x02%s\x02:%s%s",
				ucfirst($option),
				' ' x (12-length($option)),
				$server->{$option} ));
			last;
		}
	}

	if( exists($server->{source}) )
	{
		push( @text, sprintf( "\x02Source\x02:      %s", $server->{source} ));
	}

	if( exists($server->{irc}) && substr( $server->{irc}, 0, 1 ) eq '#' )
	{
		push( @text, sprintf( "\x02IRC channel\x02: %s @ ForestNet%s",
			$server->{irc},
			lc($server->{irc}) eq lc($channel) ? ' (you already found it, woohoo!)' : ''
		));
	}

	foreach my $txt ( @text )
	{
		next if( !defined($txt) || !length($txt) );
		$irc_server->command( sprintf( "msg %s %s", $channel, $txt ));
	}
}

sub msg_list
{
	my( $server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	my( @known, @unknown, @closed, @single );

	foreach my $key ( sort{ $config->{server}{$a}{name} cmp $config->{server}{$b}{name} } keys %{ $config->{server} } )
	{
		if( $config->{server}{$key}{closed} )
		{
			push( @closed, "\x02" . $config->{server}{$key}{name} . "\x02" );
		}
		elsif( $config->{server}{$key}{singleplayer} )
		{
			push( @single, "\x02" . $config->{server}{$key}{name} . "\x02" );
		}
		elsif( ($status->{server}{$key}{checked} || -1) > 0 )
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
		$server->command( "msg $channel Servers without known address (planned, closed beta, etc.):" );
		$server->command( sprintf( "msg %s  %s", $channel, join( ', ', @unknown )));
	}


	if( scalar(@closed) > 0 )
	{
		$server->command( "msg $channel Closed servers:" );
		$server->command( sprintf( "msg %s  %s", $channel, join( ', ', @closed )));
	}

	if( scalar(@single) > 0 )
	{
		$server->command( "msg $channel Singleplayer games:" );
		$server->command( sprintf( "msg %s  %s", $channel, join( ', ', @single )));
	}

	my $total = scalar(@known)+scalar(@unknown)+scalar(@closed)+scalar(@single);
	$server->command( sprintf( "msg %s Total: %d", $channel, $total ));
}

sub msg_records
{
	my( $server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	my $max_players = get_json_by_id( $config, 'max_players' );
	return if( !$max_players || !exists($max_players->{server}) );

	my( $total, $idx, $ignored, @messages ) = ( 0, 0, 0 );
	foreach my $key ( sort{$max_players->{server}{$b}{players} <=> $max_players->{server}{$a}{players}} keys( $max_players->{server} ))
	{
		$total++;
		my $players = $max_players->{server}{$key}{players};
		if( $players < 150 )
		{
			$ignored++;
			next;
		}
		push( @messages, sprintf( "\x02#%d\x02 : %d : %s (%s)",
			++$idx, $players,
			$config->{server}{$key}{name},
			strftime( "%d %B %Y", localtime($max_players->{server}{$key}{timestamp}) )
		));
	}
	if( scalar(@messages) > 0 )
	{
		$server->command( sprintf( "msg %s %sDisplaying %d%s server%s",
			$channel,
			$nick ne "" ? sprintf( "\x02%s\x02: ", $nick ) : '',
			$total-$ignored,
			$ignored > 0 ? sprintf( "/%d", $total ) : '',
			$total-$ignored != 1 ? 's' : ''
		));

		foreach my $msg ( @messages )
		{
			$server->command( sprintf( "msg %s %s", $channel, $msg ));
		}
	}
}

sub msg_help
{
	my( $server, $channel, $nick, $config, $status, $override, @arguments ) = @_;

	return if( $nick eq "" );

	$server->command( sprintf( "msg %s %s: Soon.", $channel, $nick ));
}

#Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_override_cooldown', 0 );
Irssi::settings_add_str( $IRSSI{name}, $IRSSI{name} . '_data', 'http://fodev.net/status/data' );
Irssi::settings_add_str( $IRSSI{name}, $IRSSI{name} . '_config_json', 'config.json' );
fonline_cooldown( 'status',  30 );
fonline_cooldown( 'server',  30 );
fonline_cooldown( 'info',    60 );
fonline_cooldown( 'list',    60*15 );
fonline_cooldown( 'records', 60 );
fonline_cooldown( 'help',    60 );

Irssi::signal_add( 'message own_public', 'say_own' );
Irssi::signal_add( 'message public',     'say_other' );

#fonline_log( "Loaded" );
