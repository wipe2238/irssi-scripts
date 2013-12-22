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

$VERSION = '0.2.1';
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

sub get_json()
{
	my $json = undef;

	my $status_json = Irssi::settings_get_str( $IRSSI{name} . '_status_json' );
	if( !defined($status_json) || $status_json eq "" )
	{
		fonline_log( "Invalid setting [%s_status_json]" );
		return;
	}

	if( $status_json =~ /^http\:\/\// || $status_json =~ /^https\:\/\// )
	{
		my $ua = LWP::UserAgent->new;
		$ua->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));

		my $request = HTTP::Request->new( GET => $status_json );
		my $response = $ua->request( $request );

		if( !$response->is_success )
			{ fonline_log( "HTML error : %d : %s", $response->code, $response->message ); }
		else
			{ $json = decode_json( $response->content ); }
	}
	else
	{
		if( ! -r $status_json )
		{
			fonline_log( "File not readable: %s", $status_json );
			return;
		}

		if( open( JSON, '<', $status_json ))
		{
			my $json_txt;
			while( <JSON> )
			{
				$json_txt .= $_;
			}
			close( JSON );
			$json = decode_json( $json_txt );
		}
	}

	return( $json );
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

		# get status data
		my $json = get_json();
		if( !defined($json) || !exists($json->{fonline}) )
			{ return; }

		# pass data to function
		&$sub( $server, $channel, $nick, $json, $override );

		# set cooldown
		$cooldown{$type}{$channel} = time;
	}
}

sub msg_default # !fonline
{
	my( $server, $channel, $nick, $json, $override ) = @_;

	return if( !defined($json) || !exists($json->{fonline}) );

	if( $json->{fonline}{servers} > 0 )
	{
		my( $text, $empty, $first ) = ( "", 0, 1 );

		foreach my $key ( sort{ $json->{fonline}{server}{$a}{Name} cmp $json->{fonline}{server}{$b}{Name} } keys %{ $json->{fonline}{server} } )
		{
			if( $json->{fonline}{server}{$key}{Checked} > 0 &&
				$json->{fonline}{server}{$key}{Uptime} > 0 )
			{
				if( $json->{fonline}{server}{$key}{Players} > 0 )
				{
					$text .= sprintf( "%s%s: %d (%.1f%%)",
						$first ? "" : ", ",
						$json->{fonline}{server}{$key}{Name},
						$json->{fonline}{server}{$key}{Players},
						(100*$json->{fonline}{server}{$key}{Players})/$json->{fonline}{players}
					);
					$first = 0;
				}
				else
					{ $empty++; }
			}
		}

		$text = sprintf( "%sServer%s: %d%s, Player%s: %d [%s]",
			$nick ne "" ? "\x02$nick\x02: " : "",
			$json->{fonline}{servers} > 1 ? "s" : "", $json->{fonline}{servers},
			$empty > 0 ? " ($empty empty)" : "",
			$json->{fonline}{players} > 1 ? "s" : "", $json->{fonline}{players},
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
	my( $server, $channel, $nick, $json, $override ) = @_;

	return if( !defined($json) || !exists($json->{fonline}) );

	my( @known, @unknown );

	foreach my $key ( sort{ $json->{fonline}{server}{$a}{Name} cmp $json->{fonline}{server}{$b}{Name} } keys %{ $json->{fonline}{server} } )
	{
		# hidden servers
		if( lc($json->{fonline}{server}{$key}{Address}) eq "hidden" )
		{
			my $hidden = "hidden";

			if( $json->{fonline}{server}{$key}{Uptime} <= 0 )
				{ $hidden .= ", currently offline"; }

			push( @unknown, "\x02" . $json->{fonline}{server}{$key}{Name} . "\x02 ($hidden)" );
		}
		# normal servers
		elsif( $json->{fonline}{server}{$key}{Checked} > 0 )
		{
			my $text = sprintf( "\x02%s\x02 :: Address: \x02%s\x02 Port: \x02%d\x02",
				$json->{fonline}{server}{$key}{Name},
				$json->{fonline}{server}{$key}{Address},
				$json->{fonline}{server}{$key}{Port}
			);

			if( $json->{fonline}{server}{$key}{Uptime} < 0 )
			{
				$text .= " (currently offline)";
			}

			push( @known, $text );
		}
		# not checked servers / placeholders
		else
		{
			push( @unknown, "\x02" . $json->{fonline}{server}{$key}{Name} . "\x02" );
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
		$server->command( "msg $channel Servers without known address (planned, closed beta, etc.): " );
		$server->command( sprintf( "msg %s  %s", $channel, $text ));
	}

	my $total = scalar(@known)+scalar(@unknown);
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
Irssi::settings_add_str( $IRSSI{name}, $IRSSI{name} . '_status_json', 'http://rotators.fodev.net/wipe/status/data/status.json' );
fonline_cooldown( 'default', 30 );
fonline_cooldown( 'list',    60*15 );
fonline_cooldown( 'help',    60 );

Irssi::signal_add( 'message own_public', 'say_own' );
Irssi::signal_add( 'message public',     'say_other' );

#fonline_log( "Loaded" );
