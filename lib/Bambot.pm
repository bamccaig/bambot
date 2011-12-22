# 
# bambot is a simple IRC bot.
# Copyright (C) 2011 Brandon McCaig
# 
# This file is part of bambot.
# 
# bambot is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
# 
# bambot is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with bambot.  If not, see <http://www.gnu.org/licenses/>.
# 

use v5.010;
use strict;
use warnings;
use version;

package Bambot;

our $VERSION;
our $EST;

BEGIN
{
    $VERSION = '0.0001';
    $EST = '2011-12-19';
}

use Class::Unload;
use Data::Dumper;
use File::Slurp qw(edit_file slurp);
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use List::Util qw(max);

sub add_urls
{
    my ($self, $msg) = @_;
    my @urls = $msg =~ m{\b(https?://\S+)}gi;
    if(@urls)
    {
        edit_file {
            my @lines = grep { /^http/ } split /^/m;
            shift @lines;
            push @lines, @urls;
            shift @lines while @lines > 5;
            unshift @lines, <<'EOF';
# This file is automatically written by Bambot, an IRC bot. The following
# lines are things that looked like HTTP and HTTPS URIs in an IRC channel
# that Bambot was in. It writes them to this file as a convenience for
# users that are working from a virtual console (or other interface)
# without copy+paste or open-URI functionality.
#
# Please note that there is no sensible way for Bambot to know the
# intentions of the users posting the URIs, nor the legitimacy of the URIs
# posted. Please use these URIs at your own risk. I am not responsible for
# what other people post in IRC channels and while I will make every
# effort to promptly remove URIs that I don't approve of, I make no
# guarantees to do so (I imagine I won't even know most of the URIs that
# get written here).
#
# Bambot limits the number of URIs that are recorded here so stale URIs
# will automatically be flushed as new ones are posted.
EOF

            $_ = join "\n", @lines;
        } $self->{url_file};
    }
}

sub auto_response
{
    my ($self, @responses) = @_;
    my $response = join '', @responses;
    $response =~ s/^/AUTO: /gm; 
    print $response;
    $self->send(@responses);
    return $self;
}

sub connect
{
    my ($self) = @_;
    my $sock = IO::Socket::INET->new(
            PeerAddr => $self->{host} // 'localhost',
            PeerPort => $self->{port} // 6667,
            Proto => 'tcp',
            ) or die "IO::Socket::INET::new: $!";

    $self->{sock_} = $sock;
    $self->{selector_}->add($sock);
    #$self->{verbose_} = 1;
    return $self;
}

sub identify
{
    my ($self) = @_;
    my $pwd = $self->{password};

    if(length $pwd > 0)
    {
        $self->auto_response('PRIVMSG NickServ :identify ', $pwd, "\n");
    }
    return $self;
}

sub join_channel
{
    my ($self, @channels) = @_;
    $self->auto_response(map { "JOIN $_\n" } @channels);
    return $self;
}

sub load
{
    my ($self) = @_;
    open my $fh, '<', $self->{config_file} or return 0;
    my $mode = (stat $fh)[2];
    die sprintf 'Insecure config permissions: %04o', $mode & 0777
            if ($mode & 0177) != 0;
    while(my $line = <$fh>)
    {
        next if $line =~ /^\s*(#|$)/;
        chomp $line;
        if($line =~ /(\w+)\s*=\s*(.*)/)
        {
            $self->{$1} = $2;
            next;
        }
        warn "invalid config: $line";
    }
    close $fh or warn "close: $!";
    return $self;
}

sub log
{
    my ($self, @messages) = @_;
    my $opts = $messages[-1];
    if(ref $opts)
    {
        return if $opts->{verbose} && !$self->{verbose};
        delete $messages[-1];
    }

    my $messages = join ' ', map { "$_\n" } @messages;
    $messages =~ s/^/DIAGNOSTIC: /gm;

    print STDERR $messages;
    return $self;
}

sub new
{
    my ($class, $config) = @_;
    my $selector = IO::Select->new(\*STDIN);
    my $self = {
        %$config,
        selector_ => $selector,
    };
    bless $self, $class;
    $self->load;
    return $self;
}

sub pong
{
    my ($self, @servers) = @_;
    $self->auto_response("PONG @servers\n");
    return $self;
}

sub process_client_command
{
    my ($self, $command) = @_;
    if($command =~ m{^/eval (.*)})
    {
        my @results = eval $1 or warn $@;
        print Dumper \@results;
    }
    elsif($command =~ /^exit|q(?:uit)?|x$/)
    {
        $self->auto_response("PRIVMSG #allegro :I don't blame you...\n");
        $self->auto_response("QUIT :Shutting down...\n");
        return 0;
    }
    elsif($command =~ m{^/identify$})
    {
        $self->identify();
    }
    elsif($command =~ m{^/j(?:oin)? ([#&]?\w+)})
    {
        $self->join_channel($1);
    }
    elsif($command =~ m{^/me ([#&]?\w+) (.+)})
    {
        $self->auto_response('PRIVMSG ', $1, " :\001ACTION ", $2, "\001\n");
    }
    elsif($command =~ m{^/msg ([#&]?\w+) (.+)})
    {
        $self->auto_response('PRIVMSG ', $1, ' :', $2, "\n");
    }
    elsif($command =~ m{^/nick (\w+)})
    {
        $self->set_nick($1);
    }
    elsif($command =~ m{^/p(?:art)? ([#&]?\w+) (.*)})
    {
        $self->auto_response('PART ', $1, ' :', $2, "\n");
    }
    elsif($command =~ m{^/register})
    {
        $self->register();
    }
    elsif($command =~ m{^/reload$})
    {
        $self->reload;
    }
    elsif($command =~ m{^/restart$})
    {
        $self->log('Restarting ...');
        exec("$0 @{$self->{ARGV}}");
    }
    else
    {
        $self->send($command, "\n");
    }
    return $self;
}

sub process_server_message
{
    my ($self, $msg) = @_;
    print 'SERVER: ', $msg, "\n";
    if($msg =~ /^PING :?([\w\.]+)/)
    {
        $self->pong($1);
    }
    elsif($msg =~ /:(\S+) PRIVMSG (\S+) :?(.*)/)
    {
        my ($sender, $target, $msg) = ($1, $2, $3);
        my ($nick) = $sender =~ /(\S+)!/;
        my $is_master = $sender =~ /\Q!~$self->{master}\E$/;
        $target = $target eq $self->{nick} ? $nick : $target;
        $self->add_urls($msg);
        if($msg =~ /^\001(.*)\001/)
        {
            say STDERR "CTCP: $1" if $self->{verbose};
            if($1 eq 'VERSION')
            {
                $self->auto_response(
                        'NOTICE ',
                        $nick,
                        " :\001VERSION bambot:$VERSION:perl $]\001\n",
                        );
            }
            elsif($1 =~ /^PING\b/)
            {
                $self->auto_response(
                        'NOTICE ',
                        $nick,
                        " :\001PONG\001\n",
                        );
            }
        }
        elsif($is_master && $msg eq '~activate')
        {
            $self->auto_response(
                    "PRIVMSG $target :Sentry mode activated..\n");
        }
        elsif($is_master && $msg eq '~deactivate')
        {
            $self->auto_response(
                    "PRIVMSG $target :Sleep mode activated..\n");
        }
    }
    return $self;
}

sub register
{
    my ($self) = @_;
    my $nick = $self->{nick} // 'bambot' . int rand 99;
    my $user = $self->{username} // $ENV{USER} // 'unknown' . rand(99);
    my $real_name = $self->{real_name} // 'Unknown';
    $self->set_nick($self->{nick});
    $self->auto_response('USER ', $user, ' 0 0 :', $real_name, "\n");
    $self->identify();

    return $self;
}

sub reload
{
    my $pkg = __PACKAGE__;
    unless(eval "require $pkg")
    {
        warn $@;
        return 0;
    };
    Class::Unload->unload($pkg);
    eval "require $pkg";
    return 0 if $@;
    return 1;
}

sub run
{
    my ($self) = @_;
    my ($sock, $selector) = @$self{qw/sock_ selector_/};
    STDOUT->autoflush(1);
    $self->register();
    $self->join_channel(qw(#allegro #bambot));
    MAIN: while(1)
    {
        my @handles = $selector->can_read;

        if(@handles > 0)
        {
            for my $rh (@handles)
            {
                my $line = <$rh>;

                next unless defined $line;

                chomp $line;

                if($rh == $sock)
                {
                    $self->log('Reading from socket...',
                            { verbose => 1 });
                    $self->process_server_message($line);
                }
                elsif($rh == \*STDIN)
                {
                    $self->log('Reading from stdin...',
                            { verbose => 1 });
                    $self->process_client_command($line) or last MAIN;
                }
                else
                {
                    $self->log('Unknown handle...',
                            {verbose => 1});
                    print Data::Dumper->Dump(
                            [\*STDIN, $sock, $rh],
                            [qw(STDIN sock rh)]);
                }
            }
        }
    }

    close($sock);

    return $self;
}

sub send
{
    my ($self, @messages) = @_;
    $self->{sock_}->print(@messages);
    return $self;
}

sub set_nick
{
    my ($self, $nick) = @_;
    $self->auto_response('NICK ', $nick, "\n");
    $self->{nick} = $nick;
    return $self;
}

1;

