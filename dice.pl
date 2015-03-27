use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use Irssi;

$VERSION = '0.1';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'dice',
	'description' => 'Simple dice command',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
	'license'     => 'GPL',
);

sub random
{
    my( $min, $max ) = @_;

    return( int( rand( $max - $min + 1 )) + $min );
}

sub dice
{
	my( $server, $msg, $channel, $nick ) = @_;

	# support !s and !status by editing incoming message
	if( $msg =~ /^[\t\ ]*\!([0-9]*)[kd]([0-9]+)*[\t\ ]*$/ )
	{
		my( $count, $num ) = ( $1, int($2) );
		$count = 1 if( $count eq "");
		$count = int($count);

		return if( $count <= 0 || $num <= 1 );

		my( $min, $max, $result ) = ( 0, 0, 0 );
		for( my $l = 0; $l < $count; $l++ )
		{
			$min++;
			$max += $num;
			$result += random( 1, $num );
		}

		$server->command( sprintf( "msg %s %s%s%d%s",
			$channel,
			$nick ne "" ? sprintf( "\x02%s\x02: ", $nick ) : "",
			$result == $min || $result == $max ? "\x0304" : "",
			$result,
			$result == $min || $result == $max ? "\x03" : ""
		));
	}
}

sub dice_own
{
	my( $server, $msg, $channel ) = @_;
	dice( $server, $msg, $channel, "" );
}

sub dice_other
{
	my( $server, $msg, $nick, $address, $channel ) = @_;
	dice( $server, $msg, $channel, $nick );
}

Irssi::signal_add( 'message own_public', 'dice_own' );
Irssi::signal_add( 'message public',     'dice_other' );
