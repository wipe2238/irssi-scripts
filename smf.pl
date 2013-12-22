###
#
# SimpleMachines Forum monitor
#
# Wipe/Rotators
#
###

use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use Irssi;
use Irssi::Irc;

use HTML::Entities;
use LWP;
use Storable;
use XML::Simple;

$VERSION = '0.2';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'smf',
	'description' => 'SimpleMachines Forum monitor',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
	'commands'    => 'smf',
	'modules'     => 'HTML::Entities LWP Storable XML::Simple (Data::Dumper)',
	'license'     => 'GPL',
);

###
#
# v0.2
#	reverted to non-threading model
#	more informations about what script is doing
#	save table reorganization
#
# v0.1
#	initial version
#
###

use vars qw($have_dumper);
$have_dumper = 0;
eval "use Data::Dumper;";
$have_dumper = 1 if not($@);

my $timer;
my %smf;

sub board_name($$)
{
	my( $id, $board ) = @_;

	return( $board ) if( !exists($smf{$id}{board}{$board}) );
	if( exists($smf{$id}{board}{$board}{name}) && $smf{$id}{board}{$board}{name} ne "" )
		{ return( sprintf( "%d (%s)", $board, $smf{$id}{board}{$board}{name} )); }
	return( $board );
}

sub smf_log($;@)
{
	my( $format, @args ) = @_;
	my $text = sprintf( $format, @args );
	print( CLIENTCRAP sprintf( "-\x02%s\x02- %s", $IRSSI{name}, $text ));
}

sub smf_info($$;@)
{
	my( $id, $format, @args ) = @_;
	my $text = sprintf( $format, @args );
	print( CLIENTCRAP sprintf( "-\x02%s\x02:\x02%s\x02- %s", $IRSSI{name}, $id, $text ));
}

sub smf_check()
{
	foreach my $id ( sort { $a cmp $b } keys( %smf ))
	{
		next if( exists($smf{$id}{stopped}) );

		if( !exists($smf{$id}{url}) || !defined($smf{$id}{url}) )
		{
			smf_info( $id, "URL not defined, stopping" );
			$smf{$id}{stopped} = 1;
			next;
		}

		if( !exists($smf{$id}{board}) )
		{
			smf_info( $id, "No boards added, stopping" );
			$smf{$id}{stopped} = 1;
			next;
		}

		if( !defined($smf{$id}{delay}) || $smf{$id}{delay} <= 0 )
		{
			smf_info( $id, "Delay not set, setting to default (5 minutes)" );
			$smf{$id}{delay} = 5;
		}

		next if( time < $smf{$id}{checked} + ($smf{$id}{delay}*60) );
		smf_get( $id );
		$smf{$id}{checked} = time;
		smf_save();
	}
}

###

sub smf_get($)
{
	use strict;
	use warnings;

	my( $id ) = @_;

	return if( !exists($smf{$id}{url}) );

	my $cfg_url = $smf{$id}{url};
	$cfg_url =~ s![\/]*$!!;

	return if( !scalar(keys( $smf{$id}{board} )));

	my $url = sprintf( '%s/?action=.xml&type=smf&sa=news&boards=%s%s',
		$cfg_url,
		join( ',', keys($smf{$id}{board} )),
		$smf{$id}{limit} > 0 ? sprintf( "&limit=%d", $smf{$id}{limit} ) : ""
	);

#	smf_info( $id, "GET %s", $url );

	my $ua = LWP::UserAgent->new;
	$ua->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));

	my $request = HTTP::Request->new( GET => $url );
	my $response = $ua->request( $request );

	if( !$response->is_success )
	{
		smf_info( $id, "HTML error \x02%d\x02 : \x02%s\x02",
			$response->code, $response->message );
		return;
	}

	my $xml = XMLin( $response->content );
	if( !exists($xml->{article}) )
	{
		smf_info( $id, "INVALID XML : missing XML->{article}" );
		return;
	}

	my $skipped = 0;
	foreach my $thread ( sort{ $a <=> $b } keys( $xml->{article} ))
	{
		my $board = $xml->{article}{$thread}{board}{id};
		my $boardName = $xml->{article}{$thread}{board}{name};
		$boardName =~ s!^[\t\ ]*!!;
		$boardName =~ s![\t\ ]*$!!;
		$boardName = decode_entities( $boardName );

		next if( !$board || !$boardName );

		# always update board name
		if( ($smf{$id}{board}{$board}{name} || "") ne $boardName )
		{
			smf_info( $id, "Board \x02%s\x02 name changed to \x02%s\x02",
				board_name( $id, $board ), $boardName );
			$smf{$id}{board}{$board}{name} = $boardName;
			smf_save();
		}

		my $subject = $xml->{article}{$thread}{subject};
		$subject =~ s!^[\t\ ]*!!;
		$subject =~ s![\t\ ]*$!!;
		$subject = decode_entities( $subject );

		my $poster = $xml->{article}{$thread}{poster}{name};
		$poster =~ s!^[\t\ ]*!!;
		$poster =~ s![\t\ ]*$!!;
		$poster = decode_entities( $poster );

		my $link = $xml->{article}{$thread}{link};
		$link =~ s!^[\t\ ]*!!;
		$link =~ s![\t\ ]*$!!;

		next if( !$subject || !$poster || !$link );

		# what's going on here?
		if( !($link =~ /^$smf{$id}{url}/) )
		{
			smf_log( $id, "Invalid link : \x02%s\x02 vs \x02%s\x02",
				$link, $smf{$id}{url} );
			next;
		}

		# skip known threads
		if( exists($smf{$id}{board}{$board}{thread}{$thread}) )
		{
			$smf{$id}{board}{$board}{thread}{$thread} = 1;
			next;
		}

		next if( $subject =~ /^MOVED\:/ );

		foreach my $network( sort{$a cmp $b} keys( $smf{$id}{board}{$board}{irc}) )
		{
			my @msg;
			my $server = Irssi::server_find_chatnet( $network );
			next if( !defined($server) );
			foreach my $chan ( $server->channels() )
			{
				my $channel = lc($chan->{name});
				next if( !exists( $smf{$id}{board}{$board}{irc}{$network}{$channel}) );
				my $prefix = $smf{$id}{board}{$board}{irc}{$network}{$channel} || "";
				my $text = sprintf( "\x02[\x02%s%s\x02]\x02 \"%s\" by %s \x02:\x02 %s",
					$prefix ne "" ? "$prefix \x02:\x02 " : "",
					$boardName, $subject, $poster, $link
				);
				push( @msg, "msg $channel $text" );
			}

			# board checked for a first time
			if( exists($smf{$id}{board}{$board}{first_time}) )
				{ $skipped += scalar(@msg); }

			# already known board
			else
			{
				foreach my $msg ( @msg )
				{
					$server->command( $msg );
					smf_info( $id, "%s", $msg );
				}
			}
		}
		$smf{$id}{board}{$board}{thread}{$thread} = $board;
	}
	if( $skipped > 0 )
	{
		smf_info( $id, "Skipped %d message%s",
			$skipped, $skipped != 1 ? "s" : "" );
	}

	# clear list of ignored boards
	foreach my $board ( sort{ $a <=> $b} keys( $smf{$id}{board} ))
	{
		if( exists($smf{$id}{board}{$board}{first_time}) )
		{
			smf_info( $id, "Board \x02%s\x02 no longer ignored",
				board_name( $id, $board ));
			delete($smf{$id}{board}{$board}{first_time});
		}
	}
	smf_save();
}

sub smf_save
{
	my $file = Irssi::get_irssi_dir() . '/smf.dat';
	if( -w $file || ! -x $file )
		{ store( \%smf, $file ); }
}

sub smf_load
{
	my $file = Irssi::get_irssi_dir() . '/smf.dat';
	if( -r $file )
		{ %smf = %{retrieve( $file )}; }
}

sub cmd_smf
{
	my( $args, $server, $window ) = @_;

	$args =~ s!^[\t\ ]*!!;
	$args =~ s![\t\ ]*$!!;

	Irssi::command_runsub( 'smf',$args, $server, $window );
}

sub cmd_smf_add
{
	my( $args, $server, $window ) = @_;

	my( $id, $url ) = split( ' ', $args );

	if( !defined($id) || $id eq "" )
	{
		smf_log( "Error: missing identifier" );
		return;
	}

	if( !defined($url) || $url eq "" )
	{
		smf_log( "Error: missing url" );
		return;
	}

	if( !($url =~ /^http\:\/\// || $url =~ /^https\:\/\//) )
	{
		smf_log( "Error: invalid url [%s]", $url );
		return;
	}

	my $new = {
		'stopped' => 1,
		'url'     => $url,
		'delay'   => 5,
		'limit'   => 10,
		'checked' => 0
	};

	$smf{$id} = $new;

	smf_log( "Added forum \x02%s\x02 with address \x02%s\x02", $id, $url );
	smf_save();
}

sub cmd_smf_del
{
	my( $args, $server, $window ) = @_;

	if( !defined($smf{$args}) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $args );
		return;
	}
	my $url = $smf{$args}{url} || '???';

	delete( $smf{$args} );

	smf_log( "Removed forum \x02%s\x02 with url \x02%s\x02", $args, $url );
	smf_save();
}

sub cmd_smf_edit
{
	my( $args, $server, $window ) = @_;

	my( $id, $action, @vals ) = split( /\ /, $args );

	if( !defined($id) )
	{
		smf_log( "Error: missing forum identifier" );
		return;
	}
	elsif( !defined($smf{$id}) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $id );
		return;
	}

	if( !defined($action) )
	{
		smf_log( "Error: missing property" );
		return;
	}

	$action = lc($action);

	if( $action eq "addboard" )
	{
		my $error = undef;
		if( scalar(@vals) < 3 )
		    { $error = "missing arguments"; }
		elsif( !defined($vals[0]) )
		    { $error = "missing board id"; }
		elsif( !($vals[0] =~ /^[0-9]+$/) )
		    { $error = "board id must be a number"; }
		elsif( !defined(Irssi::chatnet_find($vals[1])) )
		    { $error = "unknown chatnet \x02$vals[1]\x02"; }
		elsif( !($vals[2] =~ /^\#/) )
		    { $error = "invalid channel \x02$vals[2]\x02"; }
		if( defined($error) )
		{
		    smf_log( "Error: %s : %s", $action, $error );
		    return;
		}

		my $prefix = "";
		if( scalar(@vals) >= 4 )
		    { $prefix = join( ' ', @vals[3..scalar(@vals)-1] ); }
		@vals = map{ lc } @vals;
		my( $board, $network, $channel ) = @vals;

		smf_info( $id, "Added board \x02%s\x02 to network \x02%s\x02 and channel \x02%s\x02%s",
			board_name( $id, $board ), $network, $channel,
			$prefix ne "" ? " (prefix: \x02$prefix\x02)" : ""
		);

		# don't mark board as unchecked if it's already added
		if( !exists($smf{$id}{board}{$board}) )
		{
			smf_info( $id, "Marking board \x02%s\x02 as ignored (temporary)",
				board_name( $id, $board ));
			$smf{$id}{board}{$board}{first_time} = 1;
		}
		$smf{$id}{board}{$board}{irc}{$network}{$channel} = $prefix;
	}
	elsif( $action eq "delboard" )
	{
		my $error = undef;
		@vals = map{ lc } @vals;
		if( scalar(@vals) < 1 )
		    { $error = "missing arguments"; }
		elsif( !defined($vals[0]) )
		    { $error = "missing board id"; }
		elsif( !($vals[0] =~ /^[0-9]+$/) )
		    { $error = "board id must be a number ($vals[0])" }
		elsif( !defined($smf{$id}{board}{$vals[0]}) )
		    { $error = "unknown board [$vals[0]]"; }
		elsif( scalar(@vals) > 1 && scalar(@vals) < 3 )
		    { $error = "missing arguments (for channel removing)"; }
		elsif( scalar(@vals) >= 3 && !exists($smf{$id}{board}{$vals[0]}{irc}{$vals[1]}) )
		    { $error = "invalid chatnet [$vals[1]]"; }
		elsif( scalar(@vals) >= 3 && !exists($smf{$id}{board}{$vals[0]}{irc}{$vals[1]}{$vals[2]}) )
		    { $error = "invalid channel [$vals[2]]"; }

		if( defined($error) )
		{
			smf_log( "Error: %s : %s", $action, $error );
			return;
		}

		my( $board, $network, $channel ) = @vals;
		if( scalar(@vals) >= 3 )
		{

			smf_info( $id, "Removed channel \x02%s\x02 from network \x02%s\x02 for board \x02%s\x02",
				$channel, $network, board_name( $id, $board ));

			delete($smf{$id}{board}{$board}{irc}{$network}{$channel});

			if( !scalar(keys($smf{$id}{board}{$board}{irc}{$network})) )
			{
				smf_info( $id, "Removed network \x02%s\x02 for board \x02%s\x02",
					$network, board_name( $id, $board ));
				delete($smf{$id}{board}{$board}{irc}{$network});
			}

			if( !scalar(keys($smf{$id}{board}{$board}{irc})) )
			{
				smf_log( $id, "No channels defined for board \x02%s\x",
					board_name( $id, $board ));
				delete($smf{$id}{board}{$board}{irc});
			}
		}
		else
		{
			smf_info( $id, "Removed board \x02%s\x02", board_name( $id, $board ));
			delete($smf{$id}{board}{$board});
		}

		if( !scalar(keys($smf{$id}{board})) )
		{
			smf_info( $id, "No more boards left" );
			delete($smf{$id}{board});
		}
	}
	elsif( $action eq "delay" )
	{
		my $error = undef;
		if( scalar(@vals) < 1 )
		    { $error = "missing arguments"; }
		elsif( !defined($vals[0]) )
		    { $error = "missing delay time"; }
		elsif( !($vals[0] =~ /^[0-9]+$/) )
		    { $error = "delay time must be a number ($vals[0])" }
		if( defined($error) )
		{
			smf_log( "Error: %s : %s", $action, $error );
			return;
		}

		smf_info( $id, "Delay set to \x02%d\x02 minute%s",
			$vals[0], $vals[0] != 1 ? "s" : "" );
		$smf{$id}{delay} = int($vals[0]);
	}
	elsif( $action eq "limit" )
	{
		my $error = undef;
		if( scalar(@vals) < 1 )
			{ $error = "missing arguments"; }
		elsif( !defined($vals[0]) )
			{ $error = "missing threads limit"; }
		elsif( !($vals[0] =~ /^[0-9]+$/) )
			{ $error = "threads limit must be a number ($vals[0])" }
		elsif( int($vals[0]) < 0 )
			{ $error = "threads limit must be >= 0"; }
		if( defined($error) )
		{
			smf_log( "Error: %s : %s", $action, $error );
			return;
		}

		smf_info( $id, "Threads limit set to \x02%d\x02%s",
			$vals[0], $vals[0] == 0 ? " (will use default forum values)" :"" );
		$smf{$id}{limit} = int($vals[0]);
	}

	else
	{
		smf_log( "Error: unknown action [%s]", $action );
		return;
	}
	smf_save();
}

sub cmd_smf_show
{
	my( $args, $server, $window ) = @_;

	sub show
	{
		my $id = shift;
		if( defined($smf{$id}{stopped}) )
			{ smf_info( $id, "STOPPED" ); }
		smf_info( $id, "URL:     ".$smf{$id}{url} );
		smf_info( $id, "Delay:   %d minute%s",
			$smf{$id}{delay}, $smf{$id}{delay} != 1 ? "s" : "" );
		if( $smf{$id}{limit} > 0 )
		{
			smf_info( $id, "Limit:   %d thread%s",
				$smf{$id}{limit}, $smf{$id}{limit} != 1 ? "s" : "" );
		}
		if( exists($smf{$id}{checked}) && $smf{$id}{checked} > 0 )
		{
			my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$id}{checked});
			smf_info( $id, "Last check: %d.%02d.%d, %02d:%02d:%02d",
				$mday, $mon+1, $year+1900, $hour, $min, $sec );
			($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$id}{checked}+($smf{$id}{delay}*60));
			smf_info( $id, "Next check: %d.%02d.%d, %02d:%02d:%02d",
				$mday, $mon+1, $year+1900, $hour, $min, $sec );
		}
		return if( !exists($smf{$id}{board}) );

		foreach my $board ( sort{$a <=> $b} keys( $smf{$id}{board} ))
		{
			smf_info( $id, "Board %s:", board_name( $id, $board ));
			foreach my $network ( sort{$a cmp $b} keys( %{ $smf{$id}{board}{$board}{irc} }))
			{
				my @channels;
				foreach my $channel ( sort{$a cmp $b} keys( $smf{$id}{board}{$board}{irc}{$network} ))
				{
					my $prefix = $smf{$id}{board}{$board}{irc}{$network}{$channel};
					push( @channels, $prefix eq "" ? $channel : "$channel (prefix: $prefix)" );
				}
				smf_info( $id, "  %s : %s",
					$network, join( ", ", @channels ));
			}
		}
	}

	if( !defined($args) || $args eq "" )
	{
		foreach my $id( sort{$a cmp $b} keys( %smf ))
		{
			show( $id );
		}
	}
	else
	{
		my( $id ) = split( /\ /, $args );
		if( !defined($smf{$id}) )
		{
			smf_log( "Error: unknown forum \x02%s\x02", $id );
			return;
		}
		show( $id );
	}
}

sub cmd_smf_start
{
	my( $args, $server, $window ) = @_;

	if( !defined($args) || $args eq "" )
	{
		smf_log( "Error: missing forum identifier" );
		return;
	}
	elsif( !defined($smf{$args}) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $args );
		return;
	}

	smf_info( $args, "Started" );
	delete( $smf{$args}{stopped} );
	smf_save();
}

sub cmd_smf_stop
{
	my( $args, $server, $window ) = @_;

	if( !defined($args) || $args eq "" )
	{
		smf_log( "Error: missing forum identifier" );
		return;
	}
	elsif( !defined($smf{$args}) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $args );
		return;
	}

	smf_info( $args, "Stopped" );
	$smf{$args}{stopped} = 1;
	smf_save();
}

sub pre_unload() # used by scriptassist
{
	smf_log( "Saving..." );
	smf_save();
}

sub cmd_smf_dump
{
	my( $id ) = @_;
	if( !defined($id) || $id eq "" )
		{ print CLIENTCRAP Dumper( %smf ); }
	else
		{ print CLIENTCRAP Dumper( $smf{$id} ); }
}
if( $have_dumper )
	{ Irssi::command_bind( 'smf dump', \&cmd_smf_dump ); }

Irssi::command_bind( 'smf', \&cmd_smf );
Irssi::command_bind( 'smf add', \&cmd_smf_add );
Irssi::command_bind( 'smf del', \&cmd_smf_del );
Irssi::command_bind( 'smf edit', \&cmd_smf_edit );
Irssi::command_bind( 'smf show', \&cmd_smf_show );
Irssi::command_bind( 'smf start', \&cmd_smf_start );
Irssi::command_bind( 'smf stop', \&cmd_smf_stop );

Irssi::command_bind( 'smf save', \&smf_save );

smf_load();
$timer = Irssi::timeout_add( 1000*15, 'smf_check', undef );

#smf_log( "Loaded" );
