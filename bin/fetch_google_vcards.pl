#!/usr/bin/env perl

use strict;
use warnings;
use feature qw(say);

# PODNAME: fetch_google_vcards
# ABSTRACT: Output vCard 2.1 name and phone numbers for all Google Contacts

STDOUT->binmode(":crlf"); # The Siemens Gigaset DX800a requires UTF8 with CRLF files

my @contacts;
foreach my $contact ( @{ Google->new->contacts } ) {
    my $full_name = join(" ",
        $contact->name_prefix || (),
        $contact->given_name || (),
        $contact->additional_name || (),
        $contact->family_name || (),
        $contact->name_suffix || (),
    );
    next unless $full_name =~ /\w/; # Skip contacts without names
    next unless $contact->has_phone_number; # Skip contacts without phone numbers
    push @contacts, { name => $full_name, contact => $contact };
}
foreach my $entry ( sort { $a->{'name'} cmp $b->{'name'} } @contacts ) {
    my $full_name = $entry->{'name'};
    my $contact = $entry->{'contact'};
    say "BEGIN:VCARD";
    say "VERSION:2.1";
    say "N:$full_name";
    foreach my $number ( @{ $contact->phone_number } ) {
        (my $value = $number->value) =~ s/\s//g; # Strip whitespace
        $value =~ s/\+/00/; # Convert + to 00
        if ( $number->type->name =~ /_fax/ ) {
            my $type = $number->type->name;
            $type =~ s/_fax//;
            say "TEL;" . uc($type) . ";FAX:" . $value;
        }
        else {
            my $type = $number->type->name eq 'mobile' ? 'CELL' : uc($number->type->name);
            say "TEL;" . $type . ";VOICE:" . $value;
        }
    }
    say "END:VCARD";
    say "";
}

exit;

BEGIN {
    package Google;
    use Moose;
    use namespace::autoclean;
    use WWW::Google::Contacts;
    sub config_filename { return '.google.ini' }
    with 'Config::Role';
    has email    => ( is => 'ro', isa => 'Str', lazy => 1, default => sub { (shift)->config->{'email'}    } );
    has password => ( is => 'ro', isa => 'Str', lazy => 1, default => sub { (shift)->config->{'password'} } );
    has 'contacts_client' => (
        is => 'ro',
        isa => 'WWW::Google::Contacts',
        lazy_build => 1,
    );
    sub _build_contacts_client {
        my ($self) = @_;
        return WWW::Google::Contacts->new(
            username => $self->email,
            password => $self->password,
        );
    }
    sub BUILD {
        my ($self) = @_;
        confess("Please specify an email")   unless $self->email;
        confess("Please specify a password") unless $self->password;
        return;
    }
    has 'contacts' => (
        is => 'ro',
        isa => 'ArrayRef[WWW::Google::Contacts::Contact]',
        lazy_build => 1,
    );
    sub _build_contacts {
        my ($self) = @_;
        my $contact_list = $self->contacts_client->contacts;
        my @contacts;
        while ( my $contact = $contact_list->next ) {
            push @contacts, $contact if blessed($contact) and $contact->isa('WWW::Google::Contacts::Contact');
        }
        return \@contacts;
    }
}
