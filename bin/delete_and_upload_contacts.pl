#!/usr/bin/env perl

use strict;
use warnings;
use rlib;
use WWW::Gigaset;
use feature qw(say);

# PODNAME: delete_and_upload_contacts
# ABSTRACT: Delete contacts from phone and upload contacts from VCF to phone

die("Please specify vCard file\n") unless @ARGV;

my $gigaset = WWW::Gigaset->new();
say $gigaset->delete_vcards("office");
say $gigaset->transfer_vcards("office", shift);
