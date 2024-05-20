#!/usr/bin/perl
use Cwd;
use Data::Mirror qw(mirror_fh mirror_json);
use DateTime;
use Encode qw(encode decode);
use File::Slurp;
use File::stat;
use IO::Socket;
use JSON::XS;
use List::Util qw(min);
use LWP::ConnCache;
use Object::Anon;
use POSIX qw(floor);
use Storable qw(dclone);
use constant {
    TIMEOUT             => 3,
    IANA_RDAP_BASE_URL  => 'https://rdap.iana.org/domain/',
    ABOUT_URL           => 'https://about.rdap.org',
};
use open qw(:utf8);
use feature qw(say);
use threads;
use utf8;
use strict;

$Data::Mirror::UA->timeout(TIMEOUT);
$Data::Mirror::UA->agent('https://github.com/gbxyz/rdap-data-sources');
$Data::Mirror::UA->conn_cache(LWP::ConnCache->new);

say STDERR 'updating root zone RDAP data...';

my @tlds = map { chomp ; lc } grep { /^[A-Z0-9-]+$/ } mirror_fh('https://data.iana.org/TLD/tlds-alpha-by-domain.txt')->getlines;
say STDERR 'retrieved TLD list';

my $all = {
    'rdapConformance' => [ 'rdap_level_0' ],
    'notices' => [ {
        'title' => 'About this service',
        'description' => [
            'Please note that this RDAP service is NOT provided by the IANA.',
            '',
            'For more information, please see '.ABOUT_URL,
        ],
        'links' => [{
            'title' => 'More information about this service',
            'href'  => ABOUT_URL,
            'value' => ABOUT_URL,
            'rel'   => 'about',
        }],
    } ],
    'domainSearchResults' => [],
};

say STDERR 'generating RDAP records for TLDs...';

TLD: foreach my $tld (@tlds) {
    for (my $i = 0 ; $i < 3 ; $i++) {
        eval {
            my $record = mirror_json(IANA_RDAP_BASE_URL.$tld);

            delete($record->{'notices'});
            delete($record->{'rdapConformance'});

            push(@{$all->{'domainSearchResults'}}, $record);

            say STDERR '.'.$tld;
        };

        if ($@) {
            say STDERR $@;

        } else {
            next TLD;

        }
    }
}

print JSON::XS->new->allow_blessed->utf8->pretty->canonical->encode($all);

say STDERR 'done';
