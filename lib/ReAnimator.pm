package ReAnimator;

use strict;
use warnings;

use ReAnimator::Client;
use ReAnimator::Socket;
use ReAnimator::Slave;
use ReAnimator::Timer;
use ReAnimator::Loop;

use IO::Socket;
use Errno qw/EAGAIN EWOULDBLOCK EINPROGRESS/;

use constant DEBUG => $ENV{REANIMATOR_DEBUG} ? 1 : 0;

our $VERSION = '0.0001';

$SIG{PIPE} = 'IGNORE';

sub new {
    my $class = shift;
    $class = ref $class if ref $class;

    my $self = {@_};
    bless $self, $class;

    $self->{max_clients} ||= 100;

    $self->{host} ||= $ENV{REANIMATOR_HOST} || 'localhost';
    $self->{port} ||= $ENV{REANIMATOR_PORT} || '3000';

    $self->{loop} = $self->build_loop;

    $self->{on_connect} ||= sub { };
    $self->{on_error}   ||= sub { };

    $self->{connections} = {};
    $self->{timers}      = {};

    return $self;
}

sub build_loop   { ReAnimator::Loop->build }
sub build_socket { shift; ReAnimator::Socket->new(@_) }
sub build_timer  { shift; ReAnimator::Timer->new(@_) }
sub build_client { shift; ReAnimator::Client->new(@_) }

sub on_connect { @_ > 1 ? $_[0]->{on_connect} = $_[1] : $_[0]->{on_connect} }
sub on_error   { @_ > 1 ? $_[0]->{on_error}   = $_[1] : $_[0]->{on_error} }

sub loop   { shift->{loop} }
sub server { shift->{server} }
sub host   { shift->{host} }
sub port   { shift->{port} }

sub connections { shift->{connections} }
sub timers      { shift->{timers} }

sub max_clients {
    @_ > 1 ? $_[0]->{max_clients} = $_[1] : $_[0]->{max_clients};
}

sub start {
    my $self = shift;

    my $host = $self->host;
    my $port = $self->port;

    my $socket = $self->build_socket($host, $port);
    die "Can't create server" unless $socket;

    $self->{server} = $socket;

    $self->loop->mask_rw($self->server);

    print "Listening on $host:$port\n";

    $self->_loop_until_i_die;
}

sub _loop_until_i_die {
    my $self = shift;

    while (1) {
        $self->loop->tick(0.1);

        $self->_timers;

        for ($self->loop->readers) {
            $self->_read($_);
        }

        for ($self->loop->writers) {
            $self->_write($_);
        }
    }
}

sub _timers {
    my $self = shift;

    foreach my $id (keys %{$self->timers}) {
        my $timer = $self->timers->{$id};

        if ($timer->wake_up) {
            delete $self->timers->{$id} if $timer->one_shot;
        }
    }
}

sub total_clients {
    my $self = shift;

    return scalar $self->clients;
}

sub _read {
    my $self   = shift;
    my $socket = shift;

    if ($socket == $self->server) {
        if ($self->total_clients >= $self->max_clients) {
            $self->loop->remove($socket);
            close $socket;
            return;
        }

        if (my $sd = $socket->accept) {
            $self->_add_client($sd);
        }
        return;
    }

    my $conn = $self->connection($socket);

    my $rb = sysread($socket, my $chunk, 1024);

    unless ($rb) {
        return if $! && $! == EAGAIN || $! == EWOULDBLOCK;

        return $self->drop($conn);
    }

    warn '< ', $chunk if DEBUG;

    my $read = $conn->read($chunk);

    unless (defined $read) {
        $self->drop($conn);
    }
}

sub _write {
    my $self   = shift;
    my $socket = shift;

    return if $socket == $self->server;

    my $conn = $self->connection($socket);

    if ($conn->is_connecting) {
        return $self->drop($conn) unless $socket->connected;

        $conn->connected;
    }

    return $self->loop->mask_ro($conn->socket) unless $conn->is_writing;

    warn '> ' . $conn->buffer if DEBUG;

    my $br = syswrite($conn->socket, $conn->buffer);

    if (not defined $br) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;

        $conn->error($!);
        return $self->drop($conn);
    }

    return $self->drop($conn) if $br == 0;

    $conn->bytes_written($br);

    $self->loop->mask_ro($socket) unless $conn->is_writing;
}

sub _add_client {
    my $self   = shift;
    my $socket = shift;

    printf "[New client from %s]\n", $socket->peerhost if DEBUG;

    my $client = $self->build_client(
        socket     => $socket,
        on_connect => sub {
            $self->on_connect->($self, @_);
        }
    );

    $self->_add_conn($client);

    return $self;
}

sub add_slave {
    my $self = shift;
    my $conn = shift;

    my $socket = $self->build_socket;
    $conn->socket($socket);

    $self->_add_conn($conn);

    my $ip = gethostbyname($conn->address);
    my $addr = sockaddr_in($conn->port, $ip);

        $socket->connect($addr) == 0 ? $conn->connected
      : $! == EINPROGRESS            ? $conn->connecting
      :                                $self->drop($conn);

    return $self;
}

sub _add_conn {
    my $self = shift;
    my $conn = shift;

    $self->loop->mask_rw($conn->socket);
    $conn->on_write(sub { $self->loop->mask_rw($conn->socket) });

    $self->connections->{$conn->id} = $conn;

    return $self;
}

sub set_timeout { shift->set_interval(@_, one_shot => 1) }

sub set_interval {
    my $self     = shift;
    my $interval = shift;
    my $cb       = shift;

    my $timer = $self->build_timer(interval => $interval, cb => $cb, @_);

    $self->_add_timer($timer);

    return $self;
}

sub _add_timer {
    my $self  = shift;
    my $timer = shift;

    $self->timers->{"$timer"} = $timer;
}

sub connection {
    my $self = shift;
    my $id   = shift;

    $id = "$id" if ref $id;

    return $self->connections->{$id};
}

sub drop {
    my $self = shift;
    my $conn = shift;

    my $id = $conn->id;

    $self->loop->remove($conn->socket);

    close $conn->socket;

    if (my $e = $conn->error) {
        print "Connection error: $e\n" if DEBUG;
    }
    else {
        print "Connection closed\n" if DEBUG;

        $conn->disconnected;
    }

    delete $self->connections->{$id};

    return $self;
}

sub clients {
    my $self = shift;

    return map { $self->connection($_) }
      grep     { $self->connections->{$_}->isa('ReAnimator::Client') }
      keys %{$self->connections};
}

sub slaves {
    my $self = shift;

    return map { $self->connection($_) }
      grep     { $self->connections->{$_}->isa('ReAnimator::Slave:') }
      keys %{$self->connections};
}

sub send_broadcast_message {
    my $self    = shift;
    my $message = shift;

    foreach my $client ($self->clients) {
        $client->send_message($message);
    }
}

1;
