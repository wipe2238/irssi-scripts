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

$VERSION = '0.3.2';
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
#	Adds forum with given id and url; forum_id is used later in all other /smf commands.
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
#	addboard [board_id]
#	addboard [board_id] [network] [channel] <prefix>
#		Adds a new board to watch
#		If network and channel are specified:
#			Network argument must be already existing chatnet in your settings.
#			If prefix is not given, script will send message in following format:
#				[BoardName] "ThreadName" by Author : http://Link/To/Topic
#			Otherwise, following format is used:
#				[Prefix : BoardName] "ThreadName" by Author : http://Link/To/Topic
#		NOTES:
#			- by default 5 minutes delay is set for each board
#			- when checking board for a first time, none of found threads is
#			  is displayed in added channel(s) or status window, to prevent from
#			  flooding channels
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
#	board [board_id] [subaction] <subaction_arguments>
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
#			is checked in 20s cycle, where it decides what boards to request from
#			SMF.
#
# /smf show <forum_id>
#	Displays summary of forum options; if forum_id is omitted, all forums are displayed.
#
# /smf dump <forum_id>
#	Display save table in raw format.
#	NOTE: Disabled if Data::Dumper package is not installed.
#
###
#
# SETTINGS
#
# smf_status (default: on)
#	Displays newly found threads in status window, even if given board produces no channel
#	output. Uses format without prefix (see /smf edit [forum_id] addboard).
#
# smf_timeout (default: 5)
#	Sets the maxim number of seconds script will wait for server response.
#
# NOTE: Debug output is visible in status window only.
#
# smf_debug_get (default: off)
#	Informs about every GET request before it's sent.
#
# smf_debug_get_errors (default: off)
#	Informs about errors spotted when sending GET request.
#
# smf_debug_moved_threads (default: off)
#	Informs when moved thread is found.
#
# smf_debug_old_threads (default: off)
#	Informs when old thread is found.
#
###
#
# SIGNALS
#
# smf ($forumName, $boardName, $title, $author, $link)
#	emitted when new thread is found
#
###
#
# v0.3.2
#	empty boards are now properly processed
#	fixed never-ending notifications about moved threads
#	fixed crash on invalid xml
#	fixed crash on boards with just one topic
#	fixed incorrent enforced delay on errors
#
# v0.3.1
#	addboard and delboard requires same set of arguments
#	smf_notify setting renamed to smf_status
#	added smf_timeout setting
#	added singal emitting on new threads
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

my %smf;

sub is_uint($)
{
	my( $val ) = @_;
	return( 0 ) if( !defined($val) );

	return( 0 ) if( !($val =~ /^[0-9]+$/) );
	return( 0 ) if( $val < 0 );

	return 1;
}

sub is_uint_1($)
{
	my( $val ) = @_;
	return( 0 ) if( !defined($val) );

	return( 0 ) if( !is_uint($val) );
	return( 0 ) if( $val < 1 );

	return( 1 );
}

sub is_chatnet($)
{
	my( $val ) = @_;
	return( 0 ) if( !defined($val) );

	return( 0 ) if( !defined(Irssi::chatnet_find($val)) );

	return( 1 );
}

sub is_forum($)
{
	my( $forum ) = @_;
	return( 0 ) if( !defined($forum) );

	return( 0 ) if( !exists($smf{$forum}) );

	return( 1 );
}

sub is_forum_stopped($)
{
	my( $forum ) = @_;
	return( 0 ) if( !defined($forum) );

	return( 0 ) if( !is_forum($forum) );
	return( 0 ) if( !exists($smf{$forum}{stopped}) );

	return( 1 );
}

sub is_forum_board($$)
{
	my( $forum, $board ) = @_;
	return( 0 ) if( !defined($forum) || !defined($board) );

	return( 0 ) if( !is_forum($forum) );
	return( 0 ) if( !is_uint_1($board) );
	return( 0 ) if( !exists($smf{$forum}{board}) );
	return( 0 ) if( !exists($smf{$forum}{board}{$board}) );

	return( 1 );
}

sub is_forum_chatnet($$$)
{
	my( $forum, $board, $chatnet ) = @_;
	return( 0 ) if( !defined($forum) || !defined($board) || !defined($chatnet) );

	return( 0 ) if( !is_forum_board($forum,$board) );
	return( 0 ) if( !exists($smf{$forum}{board}{$board}{irc}) );
	return( 0 ) if( !exists($smf{$forum}{board}{$board}{irc}{$chatnet}) );

	return( 1 );
}

sub is_forum_channel($$$$)
{
	my( $forum, $board, $chatnet, $channel ) = @_;
	return( 0 ) if( !defined($forum) || !defined($board) || !defined($chatnet) || !defined($channel) );

	return( 0 ) if( !is_forum_chatnet($forum,$board,$chatnet) );
	return( 0 ) if( !exists($smf{$forum}{board}{$board}{irc}{$chatnet}{$channel}) );

	return( 1 );
}

sub board_name($$)
{
	my( $forum, $board ) = @_;
	return( '???' ) if( !defined($forum) || !defined($board) );

	return( $board ) if( !is_forum_board($forum,$board) );
	if( defined($smf{$forum}{board}{$board}{name}) && $smf{$forum}{board}{$board}{name} ne "" )
		{ $board = sprintf( "%d (%s)", $board, $smf{$forum}{board}{$board}{name} ); }

	return( $board );
}

sub chatnet_name($)
{
	my( $network ) = @_;
	return( '???' ) if( !defined($network) );

	my $chatnet = Irssi::chatnet_find($network);
	if( defined($chatnet) )
		{ $network = $chatnet->{name}; }

	return( $network );
}

sub channel_name($$)
{
	my( $network, $channel ) = @_;

	my $server = Irssi::server_find_chatnet($network);
	if( defined($server) )
	{
		my $chan = $server->channel_find($channel);
		if( defined($chan) )
			{ $channel = $chan->{name}; }
	}

	return( $channel );
}

sub smf_log($;@)
{
	my( $format, @args ) = @_;
	my $text = sprintf( $format, @args );
	print( CLIENTCRAP sprintf( "-\x02%s\x02- %s", $IRSSI{name}, $text ));
}

sub smf_info($$;@)
{
	my( $forum, $format, @args ) = @_;
	my $text = sprintf( $format, @args );
	print( CLIENTCRAP sprintf( "-\x02%s\x02:\x02%s\x02- %s", $IRSSI{name}, $forum, $text ));
}

sub smf_check()
{
	foreach my $forum ( sort { $a cmp $b } keys( %smf ))
	{
		next if( is_forum_stopped($forum) );

		if( !exists($smf{$forum}{url}) || !defined($smf{$forum}{url}) )
		{
			smf_info( $forum, "URL not defined, stopping" );
			$smf{$forum}{stopped} = 1;
			next;
		}

		if( !exists($smf{$forum}{board}) || !scalar(keys( $smf{$forum}{board})) )
		{
			smf_info( $forum, "No boards added, stopping" );
			$smf{$forum}{stopped} = 1;
			next;
		}

		smf_get( $forum );
	}
}

###

sub smf_get($)
{
	use strict;
	use warnings;

	my( $forum ) = @_;

	my $cfg_url = $smf{$forum}{url};
	$cfg_url =~ s![\/]*$!!;

	my @boards;

	# find boards which need processing
	foreach my $board ( keys( $smf{$forum}{board} ))
	{
		next if( exists($smf{$forum}{board}{$board}{ignore}) );

		next if( time < $smf{$forum}{board}{$board}{checked} + ($smf{$forum}{board}{$board}{delay}*60) );

		# "i am special!"
		if( exists($smf{$forum}{board}{$board}{first_time}) )
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
		$smf{$forum}{limit} > 0 ? sprintf( "&limit=%d", $smf{$forum}{limit} ) : ""
	);


	my $agent = LWP::UserAgent->new;
	$agent->agent( sprintf( "irssi::%s/%s", $IRSSI{name}, $VERSION ));

	# if there was an error previously, use a low timeout
	my $timeout = 2;
	if( !exists($smf{$forum}{is_error}) )
		{ $timeout = Irssi::settings_get_int( $IRSSI{name} . '_timeout' ); }

	$agent->timeout( $timeout );

	my $request = HTTP::Request->new( GET => $url );

	if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_get' ))
	{
		$url =~ s!^$smf{$forum}{url}!!;
		smf_info( $forum, "GET \$URL/%s", $url );
	}

	my $response = $agent->request( $request );
	my $content_type = lc($response->content_type());

	my $error = undef;
	my $error_tolerance = 3; # should it be in settings?
	if( !$response->is_success )
	{
		$error = sprintf( "HTML error \x02%d\x02 : \x02%s\x02",
			$response->code, $response->message );
	}

	# make sure we received proper response type, or XML::Parser will crash the script;
	# happens when we get regular html page (for example when adding non-existing board or
	# http server returns error page)

	elsif( lc($content_type) ne 'text/xml' )
	{
		$error = sprintf( "ERROR: Invalid content type (expected \x02text/xml\x02, got \x02%s\x02)",
			$content_type );
	}

	my $xml = undef;
	if( !defined( $error ))
	{
		# XML::Parser again...
		$xml = eval { XMLin( $response->content ); };
		if( $@ )
		{
			my $message = $@;
			$error = sprintf( "XML ERROR : \x02%s\x02", $message );
		}
	}

	if( defined($error) )
	{
		# display no more than X error reports in a row per forum

		if( !exists($smf{$forum}{is_error}) )
			{ $smf{$forum}{is_error} = 0; }
		$smf{$forum}{is_error}++;

		if( $smf{$forum}{is_error} <= $error_tolerance && Irssi::settings_get_bool( $IRSSI{name} . '_debug_get_errors' ))
			{ smf_info( $forum, $error ); }

		if( $smf{$forum}{is_error} >= $error_tolerance )
		{
			if( $smf{$forum}{is_error} == $error_tolerance && Irssi::settings_get_bool( $IRSSI{name} . '_debug_get_errors' ))
				{ smf_info( $forum, "Too many errors - disabling reports, enforcing 5 minutes delay" ); }

			foreach my $board ( @boards )
			{
				# TODO: better way
				$smf{$forum}{board}{$board}{checked} = (time() + ($smf{$forum}{board}{$board}{delay}*60)) - (60*5);
			}
		}

		smf_save(); # skip?
		return;
	}

	if( exists($smf{$forum}{is_error}) )
	{
		if( $smf{$forum}{is_error} >= $error_tolerance && Irssi::settings_get_bool( $IRSSI{name} . '_debug_get_errors' ))
			{ smf_info( $forum, "Enabling HTML errors reports" ); }

		delete( $smf{$forum}{is_error} );
	}

	# hotfix for empty boards
	if( !exists($xml->{article}) )
	{
		$xml->{article} = {} ;
	}
	# hotfix for boards with only one topic
	elsif( exists($xml->{article}{id}) && exists($xml->{article}{board}) && exists($xml->{article}{subject}) && exists($xml->{article}{poster}) && exists($xml->{article}{link}) )
	{
		my $article = $xml->{article};
		my $thread = int($xml->{article}{id});

		delete( $xml->{article} );

		$xml->{article}{$thread} = $article;
	}
	# else OK?

	my $skipped = 0;
	foreach my $thread ( sort{ $a <=> $b } keys( $xml->{article} ))
	{
		next if( !exists($xml->{article}{$thread}{board}) );
		next if( !exists($xml->{article}{$thread}{board}{id}) );
		next if( !exists($xml->{article}{$thread}{board}{name}) );

		my $board = $xml->{article}{$thread}{board}{id};
		my $boardName = $xml->{article}{$thread}{board}{name};
		$boardName =~ s!^[\t\ ]*!!;
		$boardName =~ s![\t\ ]*$!!;
		$boardName = decode_entities( $boardName );

		next if( !$board || !$boardName );

		# always update board name
		if( ($smf{$forum}{board}{$board}{name} || "") ne $boardName )
		{
			smf_info( $forum, "Board \x02%s\x02 name changed to \x02%s\x02",
				board_name( $forum, $board ), $boardName );
			$smf{$forum}{board}{$board}{name} = $boardName;
			smf_save();
		}

		my $subject = $xml->{article}{$thread}{subject};
		$subject =~ s!^[\t\ ]*!!;
		$subject =~ s![\t\ ]*$!!;
		$subject = Irssi::strip_codes( decode_entities( $subject ));

		my $poster = $xml->{article}{$thread}{poster}{name};
		$poster =~ s!^[\t\ ]*!!;
		$poster =~ s![\t\ ]*$!!;
		$poster = Irssi::strip_codes( decode_entities( $poster ));

		my $link = $xml->{article}{$thread}{link};
		$link =~ s!^[\t\ ]*!!;
		$link =~ s![\t\ ]*$!!;

		next if( !$subject || !$poster || !$link );

		# what's going on here?
		if( !($link =~ /^$smf{$forum}{url}/) )
		{
			smf_log( $forum, "Invalid link : \x02%s\x02 vs \x02%s\x02",
				$link, $smf{$forum}{url} );
			next;
		}

		# save board check time, must be done before threads skipping
		$smf{$forum}{board}{$board}{checked} = time;

		if( exists($smf{$forum}{board}{$board}{rdelay}) )
		{
			# TODO
		}

		# board checked for a first time,
		# do not generate any output to avoid channel flooding
		if( exists($smf{$forum}{board}{$board}{first_time}) )
		{
			$smf{$forum}{board}{$board}{thread}{$thread} = 1;
			$skipped++;
			next;
		}

		if( exists($smf{$forum}{board}{$board}{thread}) )
		{
			# skip known threads
			if( exists($smf{$forum}{board}{$board}{thread}{$thread}) )
			{
				# that's silly, but let it be in case we need to save/update
				# some thread data in future
				$smf{$forum}{board}{$board}{thread}{$thread} = 1;
				next;
			}

			# skip threads with id lower than newest known thread
			my $highest = (sort{$b <=> $a} keys($smf{$forum}{board}{$board}{thread}))[0];

			if( $thread < $highest )
			{
				if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_old_threads' ))
				{
					smf_info( $forum, "Skipping old thread \"%s\"", $subject );
					$skipped++;
				}
				$smf{$forum}{board}{$board}{thread}{$thread} = 1;
				next;
			}
		}

		# skip moved threads,
		# and let's hope forum users won't get funny ideas
		if( $subject =~ /^MOVED\:/ )
		{
			if( Irssi::settings_get_bool( $IRSSI{name} . '_debug_moved_threads' ))
			{
				$subject =~ s!^MOVED\: !!;
				smf_info( $forum, "Skipping moved thread \"%s\"", $subject );
				$skipped++;
			}
			$smf{$forum}{board}{$board}{thread}{$thread} = 1;
			next;
		}

		$smf{$forum}{board}{$board}{thread}{$thread} = 1;

		if( Irssi::settings_get_bool( $IRSSI{name} . '_status' ))
		{
			smf_info( $forum, "\x02[\x02%s\x02]\x02 \"%s\" by %s \x02:\x02 %s",
				$boardName, $subject, $poster, $link );
		}

		Irssi::signal_emit( "smf", $forum, $boardName, $subject, $poster, $link );

		next if( !exists($smf{$forum}{board}{$board}{irc}) );

		foreach my $network( sort{$a cmp $b} keys( $smf{$forum}{board}{$board}{irc}) )
		{
			my @msg;
			my $server = Irssi::server_find_chatnet( $network );
			next if( !defined($server) );
			foreach my $chan ( $server->channels() )
			{
				my $channel = lc($chan->{name});
				next if( !exists( $smf{$forum}{board}{$board}{irc}{$network}{$channel}) );
				my $prefix = $smf{$forum}{board}{$board}{irc}{$network}{$channel} || "";
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
		smf_info( $forum, "Skipped %d thread%s",
			$skipped, $skipped != 1 ? "s" : "" );
	}

	# clear list of ignored boards
	foreach my $board ( @boards )
	{
		if( exists($smf{$forum}{board}{$board}{first_time}) )
		{
			smf_info( $forum, "Board \x02%s\x02 no longer ignored",
				board_name( $forum, $board ));
			delete($smf{$forum}{board}{$board}{first_time});
		}
	}
	smf_save();
}

sub smf_save()
{
	my $file = Irssi::get_irssi_dir() . '/' . $IRSSI{name} . '.dat';
	if( -w $file || ! -x $file )
		{ store( \%smf, $file ); }
}

sub smf_load()
{
	my $file = Irssi::get_irssi_dir() . '/' . $IRSSI{name} . '.dat';
	if( -r $file )
		{ %smf = %{retrieve( $file )}; }

	# v0.2 compatibility
	foreach my $forum ( sort{$a cmp $b} keys( %smf ))
	{
		my $update = 0;
		my( $checked, $delay ) = ( 0, 5 );
		if( exists($smf{$forum}{checked}) )
		{
			$checked = $smf{$forum}{checked};
			delete($smf{$forum}{checked});
			$update = 1;
		}
		if( exists($smf{$forum}{delay}) )
		{
			$delay = $smf{$forum}{delay};
			delete($smf{$forum}{delay});
			$update = 1;
		}
		foreach my $board ( sort{$a <=> $b} keys( $smf{$forum}{board} ))
		{
			if( !exists($smf{$forum}{board}{$board}{checked} ))
			{
				$smf{$forum}{board}{$board}{checked} = $checked;
				$update = 1;
			}
			if( !exists($smf{$forum}{board}{$board}{delay} ))
			{
				$smf{$forum}{board}{$board}{delay} = $delay;
				$update = 1;
			}
		}
		smf_info( $forum, "Updated configuration to v0.3 version" ) if( $update );
	}
}

sub cmd_smf($$$)
{
	my( $args, $server, $window ) = @_;

	$args =~ s!^[\t\ ]*!!;
	$args =~ s![\t\ ]*$!!;

	Irssi::command_runsub( 'smf',$args, $server, $window );
}

sub cmd_smf_add($$$)
{
	my( $args, $server, $window ) = @_;

	my( $forum, $url ) = split( ' ', $args );

	if( !defined($forum) || $forum eq "" )
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

	$smf{$forum} = $new;

	smf_log( "Added forum \x02%s\x02 with address \x02%s\x02", $forum, $url );
	smf_save();
}

sub cmd_smf_del($$$)
{
	my( $args, $server, $window ) = @_;

	if( !is_forum($args) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $args );
		return;
	}
	my $url = $smf{$args}{url} || '???';

	delete( $smf{$args} );

	smf_log( "Removed forum \x02%s\x02 with url \x02%s\x02", $args, $url );
	smf_save();
}

sub cmd_smf_edit($$$)
{
	my( $args, $server, $window ) = @_;

	my( $forum, $action, @vals ) = split( /\ /, $args );

	if( !defined($forum) )
	{
		smf_log( "Error: missing forum identifier" );
		return;
	}
	elsif( !is_forum($forum) )
	{
		smf_log( "Error: forum \x02%s\x02 does not exists", $forum );
		return;
	}

	if( !defined($action) )
	{
		smf_log( "Error: missing action" );
		return;
	}

	$action = lc($action);

	if( $action eq "addboard" )
	{
		my $error = undef;
		if( scalar(@vals) < 1 )
		    { $error = "missing arguments"; }
		elsif( !is_uint_1($vals[0]) )
		    { $error = "board id must be a number greater than 0"; }
		elsif( scalar(@vals) > 1 && scalar(@vals) < 3 )
			{ $error = "missing arguments (for channel adding)"; }
		elsif( scalar(@vals) == 1 )
		{
			if( is_forum_board($forum,$vals[0]) )
				{ $error = "Board \x02$vals[0]\x02 already added"; }
		}
		elsif( scalar(@vals) >= 3 )
		{
			if( !is_chatnet($vals[1]) )
				{ $error = "unknown chatnet \x02$vals[1]\x02"; }
			elsif( !($vals[2] =~ /^\#/) )
				{ $error = "invalid channel \x02$vals[2]\x02"; }
		}

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

		# don't override setup of already added boards
		if( !is_forum_board($forum,$board) )
		{
			$smf{$forum}{board}{$board}{checked} = 0;
			$smf{$forum}{board}{$board}{delay} = 5;
			$smf{$forum}{board}{$board}{first_time} = 1;

			smf_info( $forum, "Marking board \x02%s\x02 as ignored (temporary)",
				board_name( $forum, $board ));
		}

		if( defined($network) && defined($channel) )
		{
			smf_info( $forum, "Added board \x02%s\x02 with output to \x02%s\x02 on \x02%s\x02%s",
				board_name( $forum, $board ),
				channel_name($network,$channel),
				chatnet_name($network),
				$prefix ne "" ? " (prefix: \x02$prefix\x02)" : ""
			);
			$smf{$forum}{board}{$board}{irc}{$network}{$channel} = $prefix;
		}
		else
		{
			smf_info( $forum, "Added board \x02%s\x02",
				board_name( $forum, $board ));
		}
	}
	elsif( $action eq "delboard" )
	{
		my $error = undef;
		@vals = map{ lc } @vals;
		if( scalar(@vals) < 1 )
			{ $error = "missing arguments"; }
		elsif( !is_forum_board($forum,$vals[0]) )
			{ $error = "unknown board \x02$vals[0]\x02"; }
		elsif( scalar(@vals) > 1 && scalar(@vals) < 3 )
			{ $error = "missing arguments (for channel removing)"; }
		elsif( scalar(@vals) >= 3 )
		{
			if( !is_forum_chatnet($forum,$vals[0],$vals[1]) )
				{ $error = "invalid chatnet \x02$vals[1]\x02"; }
			elsif( !is_forum_channel($forum,$vals[0],$vals[1],$vals[2]) )
				{ $error = "invalid channel \x02$vals[2]\x02"; }
		}
		if( defined($error) )
		{
			smf_log( "Error: %s : %s", $action, $error );
			return;
		}

		my( $board, $network, $channel ) = @vals;
		if( scalar(@vals) >= 3 )
		{
			smf_info( $forum, "Removed channel \x02%s\x02 from network \x02%s\x02 for board \x02%s\x02",
				channel_name($network,$channel),
				chatnet_name($network),
				board_name( $forum, $board )
			);

			delete($smf{$forum}{board}{$board}{irc}{$network}{$channel});

			if( !scalar(keys($smf{$forum}{board}{$board}{irc}{$network})) )
			{
				smf_info( $forum, "Removed network \x02%s\x02 for board \x02%s\x02",
					chatnet_name( $network ), board_name( $forum, $board ));
				delete($smf{$forum}{board}{$board}{irc}{$network});
			}

			if( !scalar(keys($smf{$forum}{board}{$board}{irc})) )
			{
				smf_info( $forum, "No channels defined for board \x02%s\x",
					board_name( $forum, $board ));
				delete($smf{$forum}{board}{$board}{irc});
			}
		}
		else
		{
			smf_info( $forum, "Removed board \x02%s\x02", board_name( $forum, $board ));
			delete($smf{$forum}{board}{$board});
		}

		if( !scalar(keys($smf{$forum}{board})) )
		{
			smf_info( $forum, "No more boards left" );
			delete($smf{$forum}{board});
		}
	}
	elsif( $action eq "board" )
	{
		my $error = undef;
		if( scalar(@vals) < 2 )
			{ $error = "missing arguments"; }
		elsif( !is_forum_board($forum,$vals[0]) )
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
			smf_info( $forum, "Marking board \x02%s\x02 as ignored",
				board_name( $forum, $board ));
			$smf{$forum}{board}{$board}{ignore} = 1;
		}
		elsif( $action eq "unignore" )
		{
			smf_info( $forum, "Board \x02%s\x02 no longer ignored",
				board_name( $forum, $board ));
			delete($smf{$forum}{board}{$board}{ignore});
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

			smf_info( $forum, "Delay for board \x02%s\x02 set to \x02%d\x02 minute%s",
				board_name( $forum, $board ),
				$vals[0], $vals[0] != 1 ? "s" : "" );
			$smf{$forum}{board}{$board}{delay} = int($vals[0]);
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

		smf_info( $forum, "Threads limit set to \x02%d\x02%s",
			$vals[0], $vals[0] == 0 ? " (will use default forum values)" :"" );
		$smf{$forum}{limit} = int($vals[0]);
	}
	else
	{
		smf_log( "Error: unknown action [%s]", $action );
		return;
	}
	smf_save();
}

sub cmd_smf_show($$$)
{
	my( $args, $server, $window ) = @_;

	sub show
	{
		my $forum = shift;
		if( is_forum_stopped($forum) )
			{ smf_info( $forum, "\x02STOPPED\x02" ); }
		if( exists($smf{$forum}{is_error}) )
			{ smf_info( $forum, "\x02ERRORS DETECTED\x02" ); }
		smf_info( $forum, "URL:          \x02%s\x02", $smf{$forum}{url} );
			
		if( $smf{$forum}{limit} > 0 )
		{
			smf_info( $forum, "Limit:        \x02%d\x02 thread%s",
				$smf{$forum}{limit}, $smf{$forum}{limit} != 1 ? "s" : "" );
		}
		return if( !exists($smf{$forum}{board}) );

		foreach my $board ( sort{$a <=> $b} keys( $smf{$forum}{board} ))
		{
			smf_info( $forum, "Board:        \x02%s\x02", board_name( $forum, $board ));
			if( exists($smf{$forum}{board}{$board}{ignore}) )
				{ smf_info( $forum, "  \x02IGNORED\x02" ); }
			smf_info( $forum, "  Delay:      \x02%d\x02 minute%s",
				$smf{$forum}{board}{$board}{delay},
				$smf{$forum}{board}{$board}{delay} != 1 ? "s" : "" );
			if( $smf{$forum}{board}{$board}{checked} > 0 )
			{
				my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$forum}{board}{$board}{checked});
				smf_info( $forum, "  Last check: %02d.%02d.%d, %02d:%02d:%02d",
					$mday, $mon+1, $year+1900, $hour, $min, $sec );
				($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$forum}{board}{$board}{checked}+($smf{$forum}{board}{$board}{delay}*60));
				smf_info( $forum, "  Next check: %02d.%02d.%d, %02d:%02d:%02d",
					$mday, $mon+1, $year+1900, $hour, $min, $sec );
			}

			next if( !exists($smf{$forum}{board}{$board}{irc}) );

			foreach my $network ( sort{$a cmp $b} keys( %{ $smf{$forum}{board}{$board}{irc} }))
			{
				my @channels;
				foreach my $channel ( sort{$a cmp $b} keys( $smf{$forum}{board}{$board}{irc}{$network} ))
				{
					my $push = sprintf( "\x02%s\x02", channel_name($network,$channel) );
					my $prefix = $smf{$forum}{board}{$board}{irc}{$network}{$channel};
					if( $prefix ne "" )
						{ $push .= sprintf( " (prefix: \x02%s\x02)", $prefix ); }
					push( @channels, $push ); 
				}
				smf_info( $forum, "  \x02%s\x02 : %s",
					chatnet_name($network), join( ", ", @channels ));
			}
		}
	}

	smf_log( "" );

	if( !defined($args) || $args eq "" )
	{
		foreach my $forum( sort{$a cmp $b} keys( %smf ))
		{
			show( $forum );
		}
	}
	else
	{
		my( $forum ) = split( /\ /, $args );
		if( !defined($smf{$forum}) )
		{
			smf_log( "Error: unknown forum \x02%s\x02", $forum );
			return;
		}
		show( $forum );
	}
}

sub cmd_smf_start($$$)
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

sub cmd_smf_stop($$$)
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

sub cmd_smf_dump($$$)
{
	my( $forum ) = @_;
	if( !defined($forum) || $forum eq "" )
		{ print CLIENTCRAP Dumper( %smf ); }
	else
		{ print CLIENTCRAP Dumper( $smf{$forum} ); }
}

Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_status', 1 );
Irssi::settings_add_int(  $IRSSI{name}, $IRSSI{name} . '_timeout', 5 );

Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_debug_get', 0 );
Irssi::settings_add_bool( $IRSSI{name}, $IRSSI{name} . '_debug_get_errors', 0 );
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
my $timer = Irssi::timeout_add( 1000*20, 'smf_check', undef );

my $signal_smf = { "smf" => [qw/string string string string string/] }; 
Irssi::signal_register( $signal_smf );
#smf_log( "Loaded" );
