package ReAnimator::WebSocket::URL;

use strict;
use warnings;

sub new {
    my $class = shift;
    $class = ref $class if ref $class;

    my $self = {@_};
    bless $self, $class;

    $self->{secure} ||= 0;

    return $self;
}

sub secure { @_ > 1 ? $_[0]->{secure} = $_[1] : $_[0]->{secure} }

sub host { @_ > 1 ? $_[0]->{host} = $_[1] : $_[0]->{host} }

sub resource_name {
    @_ > 1 ? $_[0]->{resource_name} = $_[1] : $_[0]->{resource_name};
}

sub parse {
    my $self   = shift;
    my $string = shift;

    my ($scheme) = $string =~ m{^(wss?)://};
    return unless $scheme;

    $self->secure(1) if $scheme =~ m/ss$/;

    my ($host) = $string =~ m{^$scheme://(.*?)(?:\/|$)};
    $host = '/' unless defined $host && $host ne '';
    $self->host($host);

    my ($path) = $string =~ m{^$scheme://(?:.*?)(/.*?)(?:\?|$)};
    $path = '/' unless defined $path && $path ne '';
    $self->resource_name($path);

    return $self;
}

sub to_string {
    my $self = shift;

    my $string = '';

    $string .= 'ws';
    $string .= 's' if $self->secure;
    $string .= '://';
    $string .= $self->host;
    $string .= $self->resource_name || '/';

    return $string;
}

1;
