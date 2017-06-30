use strict;
use warnings;

package WWW::Gigaset;

use Moose;
use namespace::autoclean;

# ABSTRACT: Manipulate phonebook on web-enabled Siemens Gigaset phone

use WWW::Mechanize;

# Read configuration from ~/.gigaset.ini, available in $self->config
has 'config_filename'   => ( is => 'ro', isa => 'Str', lazy_build => 1 );
sub _build_config_filename { return '.gigaset.ini' }
with 'Config::Role';

# Fetch a value from the configuration, allow constructor override
has 'host'   => ( is => 'ro', isa => 'Str', lazy_build => 1 );
sub _build_host { return (shift)->config->{'host'}; }

# Fetch a value from the configuration, allow constructor override
has 'pin'   => ( is => 'ro', isa => 'Str', lazy_build => 1 );
sub _build_pin { return (shift)->config->{'pin'}; }

# The root URL of the Gigaset device, also loadable from config file
has 'url'   => ( is => 'ro', isa => 'Str', lazy_build => 1 );
sub _build_url {
    my ($self) = @_;
    return $self->config->{'url'} if $self->config->{'url'};
    return 'http://' . $self->host;
}

sub BUILD {
    my ($self) = @_;
    confess("Please specify the Gigaset host or url")    unless $self->url;
    confess("Please specify the Gigaset pin")            unless $self->pin;
    confess("Gigaset PIN should be a four digit number") unless $self->pin =~ m/^\d{4}$/;
    return 1;
}

# Our browser / client used to interact with the website
has 'browser'   => ( is => 'ro', isa => 'WWW::Mechanize', lazy_build => 1 );
sub _build_browser { return WWW::Mechanize->new() }

sub login {
    my ($self) = @_;
    my $mech = $self->browser;
    $mech->get( $self->url );
    $mech->submit_form(
        form_name => 'gigaset',
        fields    => {
            'password' => $self->pin,
        },
    );
    if ( $mech->content() =~ /var error = (\d+);/ ) {
        my $error = $1;
        confess("Login failed: The system PIN you entered is invalid. Please enter the correct one") if $error == 1;
        confess("Login failed: Access is denied because there is already a session initialized by another client") if $error == 2;
        confess("Login failed: Please wait for the firmware update to be finished") if $error == 4;
        confess("Login failed: Please wait until the settings have been restored")  if $error == 7;
    }
    my $link = $mech->find_link( text => 'Settings' );
    confess("Login failed: Unknown error") unless $link;
    return $mech->content();
}

# Generic logout handler
# NB: Always run this, or other users will be blocked until session timeout (usually 5min)
sub logout {
    my ($self) = @_;
    my $mech = $self->browser;
    $mech->get( $self->url . '/logout.html' );
    return 1 if $mech->content() =~ /You have been successfully logged off./;
    return $mech->content();
}

# Fetch names of valid handsets
sub get_handsets {
    my ($self) = @_;
    $self->login();
    my $mech = $self->browser;
    $mech->get( $self->url . '/settings_telephony_tdt.html' );
    my $handset_map = _parse_handset_html( $mech->content() );
    $self->logout();
    return wantarray ? keys %$handset_map : join(", ", keys %$handset_map);
}

# Fetch vCards for the given handset
sub get_vcards {
    my ($self, $handset) = @_;
    $self->throw_error("Please specify a handset") unless $handset;
    $self->login();
    my $mech = $self->browser;
    $mech->get( $self->url . '/settings_telephony_tdt.html' );
    my $handset_map = _parse_handset_html( $mech->content() );
    my $handset_port = $handset_map->{ lc $handset };
    $self->throw_error("Invalid handset '$handset' specified\n") unless $handset_port;
    $mech->submit_form(
        form_name => 'gigaset',
        fields    => {
            tdt_handset_port => $handset_port,
            tdt_file         => '',
            tdt_function     => '1', # Save
        }
    );
    my $content = $mech->content();
    $self->logout();
    return $content;
}

# Delete all vCards for the given handset
sub delete_vcards {
    my ($self, $handset) = @_;
    $self->throw_error("Please specify a handset") unless $handset;
    $self->login();
    my $mech = $self->browser;
    $mech->get( $self->url . '/settings_telephony_tdt.html' );
    my $handset_map = _parse_handset_html( $mech->content() );
    my $handset_port = $handset_map->{ lc $handset };
    $self->throw_error("Invalid handset '$handset' specified\n") unless $handset_port;
    $mech->submit_form(
        form_name => 'gigaset',
        fields    => {
            tdt_handset_port => $handset_port,
            tdt_file         => '',
            tdt_function     => '3', # Delete
        }
    );
    my $status = 0;
    my $counter = 0;
    while ( $status == 0 ) {
        if ( $mech->content() =~ /var status = (\d+);/ ) {
            $status = $1;
            last if $status > 0;
        }
        sleep(1);
        $mech->get( $self->url . '/status.html' );
        $counter++;
        last if $counter >= 5;
    }
    $self->throw_error("Delete vCards failed: Handset connection not available") if $status == 23;
    $self->throw_error("Delete vCards failed: Unknown error") if $status > 16 and $status <= 31;
    if ( $status == 16 ) {
        $self->logout();
        return "Telephone directory has been deleted";
    }
    my $content = $mech->content();
    $self->logout();
    return $content;
}

# Transfer vCard file for the given handset
sub transfer_vcards {
    my ($self, $handset, $vcard_file) = @_;
    $self->throw_error("Please specify a handset") unless $handset;
    $self->throw_error("Please specify vCard file to upload") unless $vcard_file and -r $vcard_file;
    $self->login();
    my $mech = $self->browser;
    $mech->get( $self->url . '/settings_telephony_tdt.html' );
    my $handset_map = _parse_handset_html( $mech->content() );
    my $handset_port = $handset_map->{ lc $handset };
    $self->throw_error("Invalid handset '$handset' specified\n") unless $handset_port;
    $mech->submit_form(
        form_name => 'gigaset',
        fields    => {
            tdt_handset_port => $handset_port,
            tdt_file         => $vcard_file,
            tdt_function     => '2', # Transfer
        }
    );
    my $status = 0;
    my $counter = 0;
    while ( $status == 0 ) {
        if ( $mech->content() =~ /var status = (\d+);/ ) {
            $status = $1;
            last if $status > 0;
        }
        sleep(1);
        $mech->get( $self->url . '/status.html' );
        $counter++;
        last if $counter >= 500; # Supports up to 1000 entries, phone handles about 2 entries per second
    }
    $self->throw_error("Transfer vCards failed: vCard file is corrupt")   if $status == 19;
    $self->throw_error("Transfer vCards failed: vCard file is empty")     if $status == 21;
    $self->throw_error("Transfer vCards failed: vCard file is too large") if $status == 22;
    $self->throw_error("Transfer vCards failed: Handset unavailable")     if $status == 23;
    $self->throw_error("Transfer vCards failed: Unknown error") if $status > 18 and $status <= 31;
    if ( $status == 18 ) {
        $self->logout();
        return "All vCards have been transferred";
    }
    my $content = $mech->content();
    $self->logout();
    return $content;
}

# Logout and throw exception
sub throw_error {
    my ($self, $msg) = @_;
    $self->logout();
    confess($msg);
}

# Parse lines like this:
#
# handsets[0]=new Array();
# handsets[0][0]='Office';
# handsets[0][1]=6;
# handsets[0][2]=1;
# handsets[0][3]=1;
# handsets[0][4]=1;
# handsets[1]=new Array();
# handsets[1][0]='Cordless';
# handsets[1][1]=0;
# handsets[1][2]=2;
# handsets[1][3]=0;
# handsets[1][4]=0;
#
# into this:
#
# { 'office' => 6, 'cordless' => 0 }
#
sub _parse_handset_html {
    my ($html) = @_;
    my @lines = grep { /^handsets/ } split("\n", $html);
    my $handsets = [];
    foreach my $line ( @lines ) {
        if ( $line =~ /^handsets\[(\d)\]\[0\]='(\w+)';/ ) {
            $handsets->[$1] = {};
            $handsets->[$1]->{'name'} = lc $2;
        }
        if ( $line =~ /^handsets\[(\d)\]\[1\]=(\d);/ ) {
            $handsets->[$1]->{'port'} = $2;
        }
    }
    return {
        map { $_->{'name'} => $_->{'port'} }
        @$handsets
    };
}

1;

__END__

=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 SEMANTIC VERSIONING

This module uses semantic versioning concepts from L<http://semver.org/>.


=head1 SEE ALSO

=for :list
* L<Moose>
* L<WWW::Mechanize>
* L<Config::Role>
