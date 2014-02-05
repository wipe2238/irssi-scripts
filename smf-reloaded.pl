###
#
# SimpleMachines Forum monitor
# #reloaded@ForestNet extension
#
# Wipe/Rotators
#
###

use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use Irssi;
use Irssi::Irc;

$VERSION = '0.1';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'smf-reloaded',
	'description' => 'SimpleMachines Forum monitor (#reloaded@ForestNet extension)',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
	'license'     => 'GPL',
);

sub smf_reloaded($$$$$)
{
	my($forum, $board, $title, $author, $link) = @_;

	my $server = Irssi::server_find_chatnet( 'forestnet' );
	return if( !defined($server) );

	my $channel = undef;
	foreach my $chan ( $server->channels() )
	{
		if( lc($chan->{name}) eq '#reloaded' )
		{
			$channel = $chan->{name};
			last;
		}
	}
	return if( !defined($channel) );

	my $lauthor = lc($author);
	my $ltitle  = lc($title);
	return if( lc($forum) ne 'reloaded' );
	return if( $lauthor ne 'kilgore' && $lauthor ne 'cubik2k' && $lauthor ne 'docan' );

	my $message = sprintf( "\x02[\x034%s\x03]\x02 \"%s\" by %s \x02\x034:\x03\x02 %s",
		$board, $title, $author, $link );

	if( lc($board) eq 'auctions' && $ltitle =~ /game master/ )
	{
		$server->command( "msg $channel $message" );
	}
}

Irssi::signal_add( 'smf', 'smf_reloaded' );
