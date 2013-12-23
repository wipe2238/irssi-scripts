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

$VERSION = '0.3';
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
# COMMANDS
#
# /smf add [forum_id] [forum_url]
#	Adds forum with given url.
#	NOTES:
#		- As some forums can be accessed via various addresses (for example
#		  http://SITE.com/forum/ and http://forum.SITE.com/ may point to same forum),
#		  make sure that you give the same url that forums returns in its feed.
#		  To check what address is returned, simply add "?action=.xml" to forum address
#		  and see what's inside <link> tags.
#		  Example: http://www.simplemachines.org/community/?action=.xml
#		- Each newly added forum is stopped by default.
#
# /smf del [forum_id]
#	Removes previously added forum.
#
# /smf start [forum_id]
#	Starts checking forum. If no boards has been added, it will be forced to stop.
#
# /smf stop [forum_id]
#	Stops checking forum.
#
# /smf edit [forum_id] [action] <action_arguments>
#
#	ACTIONS:
#
#	addboard [board_id] [network] [channel] <prefix>
#		Adds a new board to watch. Output will be sent to the channel you specify.
#		Network argument must be already existing chatnet in your settings.
#		If prefix is not given, script will send message in following format:
#			[BoardName] "ThreadName" by Author : http://Link/To/Topic
#		Otherwise, following format is used:
#			[Prefix : BoardName] "ThreadName" by Author : http://Link/To/Topic
#		NOTES:
#			- by default 5 minutes delay is set for each board
#			- when checking board for a first time, none of found threads is
#			  is displayed in added channel(s) or status window, to prevent from
#			  message spam
#
#	delboard [board_id]
#	delboard [board_id] [network] [channel]
#		Removes board settings, or only a single channel (if network and channel are
#		given) from output.
#
#	limit [threads]
#		Sets a maximum number of threads SMF will return. Useful when forums default
#		settings are too low to cover more than one board.
#
#	board [board_id] [subaction] <subaction arguments>
#		Allows to edit board-specific options.
#
#		SUBACTIONS:
#
#		ignore
#			Board will not be checked.
#
#		unignore
#			Board will be checked again.
#
#		delay [minutes]
#			Sets how often information about a board will be checked. Each forum
#			is checked in 20s cycle, where 
#
# /smf show <forum_id>
#	Displays summary of forum options; if forum_id is omitted, all forums are displayed.
#
# /smf dump <forum_id>
#	Display save table in raw format.
#
###
#
# SETTINGS
#
# smf_notify (default: on)
#	Displays newly found threads in status window, even if given board produces no channel
#	output. Uses format without prefix (see /smf edit [forum_id] addboard).
#
# smf_debug_get (default: off)
#	Informs about every GET request before it's sent.
#
# smf_debug_moved_threads (default: off)
#	Informs when moved thread is found.
#
# smf_debug_old_threads (default: off)
#	Informs when old thread is found.
#
###
#
# v0.3
#	delay setting can be set for each board
#	fixed detection of old/known threads
#	boards can be ignored now
#	added debug settings
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

		smf_get( $id );
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

	my @boards;

	# find boards which need processing
	foreach my $board ( keys( $smf{$id}{board} ))
	{
		next if( exists($smf{$id}{board}{$board}{ignore}) );

		next if( time < $smf{$id}{board}{$board}{checked} + ($smf{$id}{board}{$board}{delay}*60) );

		# "i am special!"
		if( exists($smf{$id}{board}{$board}{first_time}) )
		{
			@boards = ( $board );
			last;
		}

		push( @boards, $board );
	}

	return if( !scalar(@boards) );

	my $url = sprintf( '%s/?action=.xml&type=smf&sa=news&board%s=%s%s',
		$cfg_url,
		scalar(@boards) != 1 ? "s" : "",
		join( ',', sort{$a <=> $b} @boards ),
		$smf{$id}{limit} > 0 ? sprintf( "&limit=%d", $smf{$id}{limit} ) : ""
	);


	my $ua = LWP::UserAgent->new;
	$ua->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));

	my $request = HTTP::Request->new( GET => $url );

	if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_get' ))
	{
		$url =~ s!^$smf{$id}{url}!!;
		smf_info( $id, "GET \$URL/%s", $url );
	}

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

		$smf{$id}{board}{$board}{checked} = time;
		if( exists($smf{$id}{board}{$board}{rdelay}) )
		{
			# TODO
		}

		# board checked for a first time
		if( exists($smf{$id}{board}{$board}{first_time}) )
		{
			$smf{$id}{board}{$board}{thread}{$thread} = 1;
			$skipped++;
			next;
		}

		# skip moved threads, and let's hope forum users won't get funny ideas
		if( $subject =~ /^MOVED\:/ )
		{
			if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_moved_threads' ))
			{
				$subject =~ s!^MOVED\: !!;
				smf_info( $id, "Skipping moved thread \"%s\"", $subject );
				$skipped++;
			}
			$smf{$id}{board}{$board}{thread}{$thread} = 1;
			next;
		}

		# skip known threads
		if( exists($smf{$id}{board}{$board}{thread}{$thread}) )
		{
#			$skipped++;
			$smf{$id}{board}{$board}{thread}{$thread} = 1;
			next;
		}

		# skip threads with id lower than newest known thread
		if( exists($smf{$id}{board}{$board}{thread}) )
		{
			my $highest = (sort{$b <=> $a} keys($smf{$id}{board}{$board}{thread}))[0];

			if( $thread < $highest )
			{
				if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_old_threads' ))
				{
					smf_info( $id, "Skipping old thread \"%s\"", $subject );
					$skipped++;
				}
				$smf{$id}{board}{$board}{thread}{$thread} = 1;
				next;
			}
		}

		$smf{$id}{board}{$board}{thread}{$thread} = 1;

		if( Irssi::settings_get_bool( $IRSSI{name} . '_notify' ))
		{
			smf_info( $id, "\x02[\x02%s\x02]\x02 \"%s\" by %s \x02:\x02 %s",
				$boardName, $subject, $poster, $link );
		}

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

			foreach my $msg ( @msg )
			{
				$server->command( $msg );
			}
		}
	}
	if( $skipped > 0 )
	{
		smf_info( $id, "Skipped %d thread%s",
			$skipped, $skipped != 1 ? "s" : "" );
	}

	# clear list of ignored boards
	foreach my $board ( @boards )
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
	my $file = Irssi::get_irssi_dir() . '/' . $IRSSI{name} . '.dat';
	if( -w $file || ! -x $file )
		{ store( \%smf, $file ); }
}

sub smf_load
{
	my $file = Irssi::get_irssi_dir() . '/' . $IRSSI{name} . '.dat';
	if( -r $file )
		{ %smf = %{retrieve( $file )}; }

	# v0.2 compatibility
	foreach my $id ( sort{$a cmp $b} keys( %smf ))
	{
		my $update = 0;
		my( $checked, $delay ) = ( 0, 5 );
		if( exists($smf{$id}{checked}) )
		{
			$checked = $smf{$id}{checked};
			delete($smf{$id}{checked});
			$update = 1;
		}
		if( exists($smf{$id}{delay}) )
		{
			$delay = $smf{$id}{delay};
			delete($smf{$id}{delay});
			$update = 1;
		}
		foreach my $board ( sort{$a <=> $b} keys( $smf{$id}{board} ))
		{
			if( !exists($smf{$id}{board}{$board}{checked} ))
			{
				$smf{$id}{board}{$board}{checked} = $checked;
				$update = 1;
			}
			if( !exists($smf{$id}{board}{$board}{delay} ))
			{
				$smf{$id}{board}{$board}{delay} = $delay;
				$update = 1;
			}
		}
		smf_info( $id, "Updated configuration to v0.3 version" ) if( $update );
	}
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

		# don't override setup of already added boards
		if( !exists($smf{$id}{board}{$board}) )
		{
			$smf{$id}{board}{$board}{checked} = 0;
			$smf{$id}{board}{$board}{delay} = 5;
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
				smf_info( $id, "No channels defined for board \x02%s\x",
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
	elsif( $action eq "board" )
	{
		my $error = undef;
		if( scalar(@vals) < 2 )
			{ $error = "missing arguments"; }
		elsif( !defined($vals[0]) )
			{ $error = "missing board id"; }
		elsif( !($vals[0] =~ /^[0-9]+$/) )
			{ $error = "board id must be a number ($vals[0])"; }
		elsif( !exists($smf{$id}{board}{$vals[0]}) )
			{ $error = "unknown board \x02$vals[0]\x02"; }
		if( defined($error) )
		{
			smf_log( "Error: %s : %s", $action, $error );
			return;
		}
		my $board = $vals[0];
		$action = lc($vals[1]);
		if( defined($vals[2]) )
			{ @vals = @vals[2..scalar(@vals)-1]; }
		else
			{ @vals = (); }

		if( $action eq "ignore" )
		{
			smf_info( $id, "Marking board \x02%s\x02 as ignored",
				board_name( $id, $board ));
			$smf{$id}{board}{$board}{ignore} = 1;
		}
		elsif( $action eq "unignore" )
		{
			smf_info( $id, "Board \x02%s\x02 no longer ignored",
				board_name( $id, $board ));
			delete($smf{$id}{board}{$board}{ignore});
		}
		if( $action eq "delay" )
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

			smf_info( $id, "Delay for board \x02%s\x02 set to \x02%d\x02 minute%s",
				board_name( $id, $board ),
				$vals[0], $vals[0] != 1 ? "s" : "" );
			$smf{$id}{board}{$board}{delay} = int($vals[0]);
		}
		else
		{
			smf_log( "Error: unknown board action [%s]", $action );
			return;
		}
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
			{ smf_info( $id, "\x02STOPPED\x02" ); }
		smf_info( $id, "URL:     \x02%s\x02", $smf{$id}{url} );
			
		if( $smf{$id}{limit} > 0 )
		{
			smf_info( $id, "Limit:   \x02%d\x02 thread%s",
				$smf{$id}{limit}, $smf{$id}{limit} != 1 ? "s" : "" );
		}
		return if( !exists($smf{$id}{board}) );

		foreach my $board ( sort{$a <=> $b} keys( $smf{$id}{board} ))
		{
			smf_info( $id, "Board %s:", board_name( $id, $board ));
			if( exists($smf{$id}{board}{$board}{ignore}) )
				{ smf_info( $id, "  \x02IGNORED\x02" ); }
			smf_info( $id, "  Delay:   \x02%d\x02 minute%s",
				$smf{$id}{board}{$board}{delay},
				$smf{$id}{board}{$board}{delay} != 1 ? "s" : "" );
			if( $smf{$id}{board}{$board}{checked} > 0 )
			{
				my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$id}{board}{$board}{checked});
				smf_info( $id, "  Last check: %d.%02d.%d, %02d:%02d:%02d",
					$mday, $mon+1, $year+1900, $hour, $min, $sec );
				($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$id}{board}{$board}{checked}+($smf{$id}{board}{$board}{delay}*60));
				smf_info( $id, "  Next check: %d.%02d.%d, %02d:%02d:%02d",
					$mday, $mon+1, $year+1900, $hour, $min, $sec );
			}

			foreach my $network ( sort{$a cmp $b} keys( %{ $smf{$id}{board}{$board}{irc} }))
			{
				my @channels;
				foreach my $channel ( sort{$a cmp $b} keys( $smf{$id}{board}{$board}{irc}{$network} ))
				{
					my $prefix = $smf{$id}{board}{$board}{irc}{$network}{$channel};
					push( @channels, $prefix eq ""
						? "\x02$channel\x02"
						: "\x02$channel\x02 (prefix: \x02$prefix\x02)"
					);
				}
				smf_info( $id, "  \x02%s\x02 : %s",
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

Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_notify', 1 );

Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_debug_get', 0 );
Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_debug_moved_threads', 0 );
Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_debug_old_threads', 0 );

Irssi::command_bind( 'smf', \&cmd_smf );
Irssi::command_bind( 'smf add', \&cmd_smf_add );
Irssi::command_bind( 'smf del', \&cmd_smf_del );
Irssi::command_bind( 'smf edit', \&cmd_smf_edit );
Irssi::command_bind( 'smf show', \&cmd_smf_show );
Irssi::command_bind( 'smf start', \&cmd_smf_start );
Irssi::command_bind( 'smf stop', \&cmd_smf_stop );

if( $have_dumper )
	{ Irssi::command_bind( 'smf dump', \&cmd_smf_dump ); }

smf_load();
$timer = Irssi::timeout_add( 1000*20, 'smf_check', undef );

#smf_log( "Loaded" );
