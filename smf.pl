#

use strict;
use warnings;
use vars qw($VERSION %IRSSI);

use threads;

use Irssi;
use Irssi::Irc;

use HTML::Entities;
use LWP;
use Storable;
use XML::Simple;

$VERSION = '0.1';
%IRSSI = (
	'authors'     => 'Wipe',
	'name'        => 'smf',
	'description' => 'SimpleMachines Forum monitor',
	'url'         => 'https://github.com/wipe2238/irssi-scripts/',
	'commands'    => 'smf',
	'modules'     => 'threads HTML::Entities LWP Storable XML::Simple',
	'license'     => 'GPL',
);

my $timer;

my %smf;

sub run_threads()
{
	foreach my $id ( sort { $a cmp $b } keys( %smf ))
	{
		next if( defined($smf{$id}{stopped}) );
		next if( !defined($smf{$id}{url}) );
		next if( !defined($smf{$id}{boards}) || !scalar(keys(%{$smf{$id}{boards}})) );

		if( !defined($smf{$id}{delay}) || $smf{$id}{delay} <= 0 )
			{ $smf{$id}{delay} = 5; }

		if( !defined($smf{$id}{_thread}) ) # start thread
		{
			my $func = 'smf_get';

			next if( time < $smf{$id}{checked} + ($smf{$id}{delay}*60) );

			if( !defined( UNIVERSAL::can( __PACKAGE__, $func )))
			{
				Irssi::print( "Error: invalid thread function<$func>" );
				next;
			}

			$smf{$id}{checked} = time;
			my $thread;
			{
				no warnings;
#				Irssi::print( "starting thread [$id]" );
				$thread = threads->new( $func, %{ $smf{$id} } );
			}
			if( !defined($thread) )
			{
				Irssi::print( "Error: thread not created [$id]" );
				next;
			}
			smf_save();
			$smf{$id}{_thread} = $thread;
		}
#		elsif( $smf{$id}{_thread}->is_running() )
#		{
#			Irssi::print( "still working [$id]" );
#		}
		elsif( $smf{$id}{_thread}->is_joinable() ) # end thread
		{
#			Irssi::print( "joining thread [$id]" );
			my $result = $smf{$id}{_thread}->join();
			delete($smf{$id}{_thread});

			if( !defined($result) )
			{
				Irssi::print( "Error: no results [$id]" );
				next;
			}
			if( defined( $result->{error} ))
			{
				Irssi::print( "Error: ".$result->{error}." [$id]" );
				next;
			}
			next if( !scalar(keys(%{$result})) );
			foreach my $thid ( sort{$a <=> $b} keys( %{$result} ))
			{
				# TODO: strip html (Ashes of Phoenix)

				# always update board name
				my $boardId = $result->{$thid}{board}{id};
				my $boardName = $result->{$thid}{board}{name};
				$boardName =~ s!^[\t\ ]*!!;
				$boardName =~ s![\t\ ]*$!!;
				$boardName = decode_entities( $boardName );

				next if( !$boardId || !$boardName );
				$smf{$id}{boards_names}{$boardId} = $boardName;

				# skip known threads
				next if( defined($smf{$id}{known}{$thid}) );
				$smf{$id}{known}{$thid} = $boardId;

				my $subject = $result->{$thid}{subject};
				$subject =~ s!^[\t\ ]*!!;
				$subject =~ s![\t\ ]*$!!;
				$subject = decode_entities( $subject );

				my $poster = $result->{$thid}{poster}{name};
				$poster =~ s!^[\t\ ]*!!;
				$poster =~ s![\t\ ]*$!!;
				$poster = decode_entities( $poster );

				my $link = $result->{$thid}{link};
				$link =~ s!^[\t\ ]*!!;
				$link =~ s![\t\ ]*$!!;

				next if( !$subject || !$poster || !$link );

				foreach my $network( sort{$a cmp $b} keys( $smf{$id}{boards}{$boardId}) )
				{
					my @msg;
					my $server = Irssi::server_find_chatnet( $network );
					next if( !defined($server) );
					foreach my $channel ( $server->channels() )
					{
						my $chaname = lc($channel->{name});
						next if( !defined( $smf{$id}{boards}{$boardId}{$network}{$chaname}) );
						my $prefix = $smf{$id}{boards}{$boardId}{$network}{$chaname};
						my $text = sprintf( "\x02[\x02%s%s\x02]\x02 \"%s\" by %s \x02::\x02 %s",
							$prefix ne "" ? "$prefix, " : "",
							$boardName,
							$subject,
							$poster,
							$link
						);
						push( @msg, "msg $chaname $text" );
					}
					foreach my $msg ( @msg )
					{
						$server->command( $msg );
#						Irssi::print( $msg );
					}
				}
			}
			smf_save();
		}
#		else
#		{
#			Irssi::print( "nothing to do" );
#		}
	}
}

###

sub smf_get($)
{
	use strict;
	use warnings;

	my( %cfg ) = @_;

	my $cfg_url = $cfg{url};
	$cfg_url =~ s![\/]*$!!;
	my @cfg_boards = sort{$a <=> $b} keys( $cfg{boards} );
	if( !scalar( @cfg_boards ))
	{
		my %result = ( 'error' => 'no boards defined' );
		return( \%result );
	}

	my $url = sprintf( '%s/?action=.xml&type=smf&sa=news&limit=9999&boards=%s',
		$cfg_url, join( ',', @cfg_boards ));

	my $ua = LWP::UserAgent->new;
	$ua->agent( "irssi-smf/$VERSION" );

	my $req = HTTP::Request->new( GET => $url );
	my $res = $ua->request( $req );

	if( !$res->is_success )
	{
		my $err = sprintf( "HTML error : %d %s", $res->code, $res->message );
		my %result = ( 'error' => $err );
		return( \%result );
	}

	my $xml = XMLin( $res->content );
	if( !exists($xml->{article}) )
	{
		my %result = ( 'error' => 'missing article' );
		return( \%result );
	}

	my %result;

	foreach my $id ( sort{ $a <=> $b } keys( $xml->{article} ))
	{
		next if( defined($cfg{known}{$id}) );
		next if( defined($result{$id}) );

		$result{$id} = $xml->{article}{$id};
	}

	return( \%result );
}

sub smf_save
{
	my $file = Irssi::get_irssi_dir() . '/smf.dat';
	my %save = %smf;
	foreach my $id ( keys( %save ))
	{
		foreach my $key ( '_thread' )
		{
			delete( $save{$id}{$key} );
		}
	}
	if( -w $file || ! -x $file )
		{ store( \%save, $file ); }
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
		Irssi::print( "Error: missing identifier" );
		return;
	}

	if( !defined($url) || $url eq "" )
	{
		Irssi::print( "Error: missing url" );
		return;
	}

	if( !($url =~ /^http\:\/\// || $url =~ /^https\:\/\//) )
	{
		Irssi::print( "Error: invalid url<$url>" );
		return;
	}

	my $new = {
		'stopped' => 1,
		'url' => $url,
		'delay' => 5,
		'checked' => 0
	};

	$smf{$id} = $new;

	Irssi::print( "SMF : Added identifier<$id> with url<$url>" );
	smf_save();
}

sub cmd_smf_del
{
	my( $args, $server, $window ) = @_;

	if( !defined($smf{$args}) )
	{
		Irssi::print( "Error: identifier<$args> does not exists" );
		return;
	}
	my $url = $smf{$args}{url} || '???';

	if( defined($smf{$args}{_thread}) )
	    { $smf{$args}{_thread}->join(); }
	delete( $smf{$args} );

	Irssi::print( "SMF : Deleted identifier<$args> with url<$url>" );
	smf_save();
}

sub cmd_smf_edit
{
	my( $args, $server, $window ) = @_;

	my( $id, $action, @vals ) = split( /\ /, $args );

	if( !defined($id) )
	{
		Irssi::print( "Error: missing identifier" );
		return;
	}
	elsif( !defined($smf{$id}) )
	{
		Irssi::print( "Error: identifier<$id> does not exists" );
		return;
	}

	if( !defined($action) )
	{
		Irssi::print( "Error: missing property" );
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
		    { $error = "board id must be a number ($vals[0])"; }
		elsif( !defined(Irssi::chatnet_find($vals[1])) )
		    { $error = "unknown chatnet<$vals[1]>"; }
		elsif( !($vals[2] =~ /^\#/) )
		    { $error = "invalid channel<$vals[2]>"; }
		if( defined($error) )
		{
		    Irssi::print( "Error: $action : $error" );
		    return;
		}
		my $chatnet = Irssi::chatnet_find( $vals[1] );
		my $value = "";
		if( scalar(@vals) >= 4 )
		    { $value = join( ' ', @vals[3..scalar(@vals)-1] ); }
		@vals = map{ lc } @vals;
		$smf{$id}{boards}{$vals[0]}{$vals[1]}{$vals[2]} = $value;
		smf_save();
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
		elsif( !defined($smf{$id}{boards}{$vals[0]}) )
		    { $error = "unknown board<$vals[0]>"; }
		elsif( scalar(@vals) > 1 && scalar(@vals) < 3 )
		    { $error = "missing arguments (for channel removing)"; }
		elsif( scalar(@vals) >= 3 && !defined($smf{$id}{boards}{$vals[0]}{$vals[1]}) )
		    { $error = "invalid chatnet<$vals[1]>"; }
		elsif( scalar(@vals) >= 3 && !defined($smf{$id}{boards}{$vals[0]}{$vals[1]}{$vals[2]}) )
		    { $error = "invalid channel<$vals[2]>"; }

		if( defined($error) )
		{
			Irssi::print( "Error: $action : $error" );
			return;
		}
		if( scalar(@vals) >= 3 )
		{
			delete($smf{$id}{boards}{$vals[0]}{$vals[1]}{$vals[2]});
			
			if( !scalar(keys($smf{$id}{boards}{$vals[0]}{$vals[1]})) )
				{ delete($smf{$id}{boards}{$vals[0]}{$vals[1]}); }
			if( !scalar(keys($smf{$id}{boards}{$vals[0]})) )
			{
				delete($smf{$id}{boards}{$vals[0]});
				delete($smf{$id}{boards_names}{$vals[0]});
			}
		}
		else
		{
			delete($smf{$id}{boards}{$vals[0]});
			delete($smf{$id}{boards_names}{$vals[0]});
		}

		foreach my $thid ( keys( $smf{$id}{known} ))
		{
			if( $smf{$id}{known}{$thid} == $vals[0] )
				{ delete( $smf{$id}{known}{$thid} ); }
		}

		if( !scalar(keys($smf{$id}{boards})) )
		{
			delete($smf{$id}{boards});
			delete($smf{$id}{boards_names});
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
			Irssi::print( "Error: $action : $error" );
			return;
		}
		$smf{$id}{delay} = int($vals[0]);
	}

	# debug :P
	elsif( $action eq '--clear-known' )
	{
		delete( $smf{$id}{known} );
	}
	else
	{
		Irssi::print( "Error: unknown action<$action>" );
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
		Irssi::print( "[$id]" );
		if( defined($smf{$id}{stopped}) )
			{ Irssi::print( "  STOPPED" ); }
		Irssi::print( "  URL:     ".$smf{$id}{url} );
		Irssi::print( sprintf( "  Delay:   %d minute%s",
			$smf{$id}{delay}, $smf{$id}{delay} != 1 ? "s" : "" ));
		if( $smf{$id}{checked} > 0 )
		{
			my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($smf{$id}{checked});
			Irssi::print( sprintf( "  Checked: %d.%02d.%d, %02d:%02d:%02d",
				$mday, $mon+1, $year+1900, $hour, $min, $sec ));
		}
		{
			foreach my $board ( sort{$a <=> $b} keys( %{$smf{$id}{boards}} ))
			{
				Irssi::print( sprintf( "  Board %s%s:",
					$board, defined($smf{$id}{boards_names}{$board})
						? " ($smf{$id}{boards_names}{$board})"
						: ""
				));
				foreach my $network ( sort{$a cmp $b} keys( %{$smf{$id}{boards}{$board}} ))
				{
					next if( $network eq "_name" );
					my @channels;
					foreach my $channel ( sort{$a cmp $b} keys( %{$smf{$id}{boards}{$board}{$network}} ))
					{
						my $prefix = $smf{$id}{boards}{$board}{$network}{$channel};
						push( @channels, $prefix eq "" ? $channel : "$channel (prefix: $prefix)" );
					}
					Irssi::print( "    $network : ".join( ", ", @channels ));
				}
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
			Irssi::print( "Error: unknown identifier<$id>" );
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
		Irssi::print( "Error: missing identifier" );
		return;
	}
	elsif( !defined($smf{$args}) )
	{
		Irssi::print( "Error: identifier<$args> does not exists" );
		return;
	}

	delete( $smf{$args}{stopped} );
	smf_save();
}

sub cmd_smf_stop
{
	my( $args, $server, $window ) = @_;

	if( !defined($args) || $args eq "" )
	{
		Irssi::print( "Error: missing identifier" );
		return;
	}
	elsif( !defined($smf{$args}) )
	{
		Irssi::print( "Error: identifier<$args> does not exists" );
		return;
	}

	$smf{$args}{stopped} = 1;
	smf_save();
}

sub cmd_smf_dump
{
	use Data::Dumper;
	Irssi::print( Dumper( %smf ));
}
Irssi::command_bind( 'smf dump', \&cmd_smf_dump );

Irssi::command_bind( 'smf', \&cmd_smf );
Irssi::command_bind( 'smf add', \&cmd_smf_add );
Irssi::command_bind( 'smf del', \&cmd_smf_del );
Irssi::command_bind( 'smf edit', \&cmd_smf_edit );
Irssi::command_bind( 'smf show', \&cmd_smf_show );
Irssi::command_bind( 'smf start', \&cmd_smf_start );
Irssi::command_bind( 'smf stop', \&cmd_smf_stop );

Irssi::command_bind( 'smf save', \&smf_save );

smf_load();
$timer = Irssi::timeout_add( 1000, 'run_threads', undef );

Irssi::print( "smf loaded" );
