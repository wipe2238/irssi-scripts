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

	if( $msg =~ /^[\t\ ]*\!([0-9]*)[kd]([0-9]+)[\t\ ]*([\*\/\+\-]?)[\t\ ]*([0-9]*)[\t\ ]*$/ )
	{
		my( $min, $num, $op, $opnum ) = ( $1, int($2), $3, $4 );

		$min = 1 if( $min eq "");
		$min = int($min);

		$opnum = 0 if( $opnum eq "" );
		$opnum = int($opnum);

		return if( $min < 1 || $num < 2 );

		my( $max, $result ) = ( $min * $num, random( $min, $min * $num ));
		
		my $extra = "";

		if( $op ne "" && $opnum > 0 )
		{
			my $round = "";
			$extra .= sprintf( " \x02(\x02%s%u%s%s%u",
				$result == $min || $result == $max ? "\x0304" : "",
				$result,
				$result == $min || $result == $max ? "\x03" : "",
				$op,
				$opnum
			);

			$result = $result * $opnum if( $op eq "*" );
			$result = $result / $opnum if( $op eq "/" );
			$result = $result + $opnum if( $op eq "+" );
			$result = $result - $opnum if( $op eq "-" );

			if( $result < $min )
			{
				$result = $min;
				$round = "minimal";
			}
			elsif( $result > $max )
			{
				$result = $max;
				$round = "maximal";
			}

			$extra .= sprintf( ", rounded to %s value", $round ) if( $round ne "" );
			$extra .= "\x02)\x02";
		}

		$server->command( sprintf( "msg %s %s%s%u%s%s",
			$channel,
			$nick ne "" ? sprintf( "\x02%s\x02: ", $nick ) : "",
			$result == $min || $result == $max ? "\x0304" : "",
			$result,
			$result == $min || $result == $max ? "\x03" : "",
			$extra
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
