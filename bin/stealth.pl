#!/usr/bin/perl
use Data::Mirror qw(mirror_str mirror_json mirror_file);
use Data::Tranco;
use Domain::PublicSuffix;
use Email::Address::XS;
use HTTP::Request::Common;
use LWP::UserAgent;
use List::Util qw(uniq);
use Net::RDAP;
use URI;
use constant {
    PSL_URL     => 'https://publicsuffix.org/list/public_suffix_list.dat',
    RDAP_URL    => 'https://data.iana.org/rdap/dns.json',
    TLD_INFO    => 'https://root.rdap.org/domains',
    TLD_LIST    => 'https://data.iana.org/TLD/tlds-alpha-by-domain.txt',
};
use feature qw(say);
use strict;
use open qw(:encoding(utf8));
use vars qw($KNOWN $KNOWN_URLS @PATHS $PSL @TLDs $IANA $INFO $EXCLUDE);
use warnings;

$| = 1;

#
# these are known stealth RDAP servers
#
$KNOWN = {
    'ch' => 'rdap.nic.ch',
    'tl' => 'whois.nic.tl',
    'gy' => 'whois.registry.gy',
    'af' => 'whois.nic.af',
    'ht' => 'whois.nic.ht',
    'hn' => 'whois.nic.hn',
    'sb' => 'rdap.nic.sb',
    'ml' => 'rdap.nic.ml',
    'ke' => 'whois.kenic.or.ke',
    'gov' => 'rdap.cloudflareregistry.com',
};

# reported by @notpushkin, see https://gist.github.com/notpushkin/6220d8efa5899dbb0dcff1b9ccf729d4
$KNOWN_URLS = {
    "ac" => "https://rdap.identitydigital.services/rdap/",
    "ae" => "https://rdap.nic.ae/", # works but no data
    "ag" => "https://rdap.identitydigital.services/rdap/",
    "bh" => "https://rdap.centralnic.com/bh/",
    "bz" => "https://rdap.identitydigital.services/rdap/",
    "ch" => "https://rdap.nic.ch/",
    "co" => "https://rdap.nic.co/",
    "de" => "https://rdap.denic.de/",
    "dm" => "https://rdap.dmdomains.dm/rdap/",
    "ga" => "https://rdap.nic.ga/",
    "gi" => "https://rdap.identitydigital.services/rdap/",
    "gl" => "https://rdap.centralnic.com/gl/",
    "in" => "https://rdap.registry.in/",
    "io" => "https://rdap.identitydigital.services/rdap/",
    "ki" => "https://rdap.coccaregistry.org/",
    "kn" => "https://rdap.nic.kn/",
    "lc" => "https://rdap.identitydigital.services/rdap/",
    "li" => "https://rdap.nic.li/",
    "me" => "https://rdap.identitydigital.services/rdap/",
    "mg" => "https://rdap.nic.mg/",
    "mn" => "https://rdap.identitydigital.services/rdap/",
    "mr" => "https://rdap.nic.mr/",
    "my" => "https://rdap.mynic.my/rdap/",
    "mz" => "https://rdap.nic.mz/",
    "ng" => "https://rdap.nic.net.ng/",
    "om" => "https://rdap.registry.om/",
    "pr" => "https://rdap.identitydigital.services/rdap/",
    "py" => "https://rdap.nic.py/",
    "sc" => "https://rdap.identitydigital.services/rdap/",
    "sh" => "https://rdap.identitydigital.services/rdap/",
    "sn" => "https://rdap.nic.sn/",
    "so" => "https://rdap.nic.so/",
    "td" => "https://rdap.nic.td/",
    "tl" => "https://rdap.nic.tl/",
    "us" => "https://rdap.nic.us/",
    "vc" => "https://rdap.identitydigital.services/rdap/",
    "ve" => "https://rdap.nic.ve/rdap/",
    "vu" => "https://rdap.dnrs.vu/",
    "ws" => "https://rdap.website.ws/",
    "arpa" => "https://rdap.iana.org/",
};

#
# these are the most common prefixes in the paths of RDAP Base URLs
#
@PATHS = qw(/ /rdap /v1);

say STDERR 'running...';

say STDERR 'mirroring PSL...';
$PSL = Domain::PublicSuffix->new({ data_file => mirror_file(PSL_URL) });

say STDERR 'getting list of TLDs...';
@TLDs = sort grep { $_ !~ /^#/ } split(/\n/, lc(mirror_str(TLD_LIST)));

say STDERR 'retrieving TLD info...';
$INFO = { map { lc($_->name->name) => $_ } Net::RDAP::SearchResult->new(mirror_json(TLD_INFO), TLD_INFO)->domains };

#
# generate an exclusion list of TLDs that have a bootstrap entry already
#
$EXCLUDE = {};
foreach my $service (@{ mirror_json(RDAP_URL)->{services} }) {
    foreach my $tld (map { lc } @{$service->[0]}) {
        $EXCLUDE->{$tld} = 1;
    }
}

say STDERR 'checking TLDs...';

foreach my $tld (grep { !exists($EXCLUDE->{$_}) } @TLDs) {
    check_tld($tld);
}

say STDERR 'done';

exit;

sub check_tld {
    my $tld = shift;
    say STDERR sprintf('checking .%s...', uc($tld));

    my $domain = [ Data::Tranco->top_domain($tld) ]->[0];

    my @urls;

    if (exists($KNOWN_URLS->{$tld})) {
        say STDERR sprintf('.%s has a known URL (%s)', uc($tld), $KNOWN_URLS->{$tld});
        push(@urls, URI->new($KNOWN_URLS->{$tld}));

    } else {
        #
        # this will contain a list of hosts
        #
        my @hosts;

        if (exists($KNOWN->{$tld})) {
            say STDERR sprintf('.%s has a known RDAP server (%s)', uc($tld), $KNOWN->{$tld});
            push(@hosts, $KNOWN->{$tld});

        } else {
            #
            # this will be populated with any domain name found
            # in the TLD's RDAP record
            #
            my @domains;

            if (!exists($INFO->{$tld})) {
                say STDERR sprintf('missing info for .%s!', uc($tld));
                return;
            }

            my $rdap = $INFO->{$tld};

            #
            # extract domains from related links
            #
            foreach my $link (grep { 'related' eq $_->rel } $rdap->links) {
                push (@domains, $PSL->get_root_domain($link->href->host));
            }

            #
            # extract domains from entity email addresses
            #
            foreach my $email (map { $_->{address} } map { @{$_->vcard->email_addresses} } $rdap->entities) {
                push(@domains, $PSL->get_root_domain(Email::Address::XS->parse($email)->host));
            }

            #
            # generate a list of hosts from the list of domains
            #
            @hosts = uniq(map { 'rdap.'.$_ } (grep { defined } @domains, $tld));

            push(@hosts, $rdap->port43) if ($rdap->port43);
        }

        foreach my $host (map { lc } @hosts) {
            foreach my $path (@PATHS) {
                $path =~ s/\/+/\//g;

                push(@urls, URI->new(q{https://}.$host.$path)->canonical);
            }
        }
    }

    my $ua = LWP::UserAgent->new(
        user_agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0',
        timeout => 3,
        ssl_opts => {
            # for the purposes of this survey, we don't care about
            # whether the server has a valid TLS certificate
            verify_hostname => undef,
        }
    );

    foreach my $url (@urls) {
        $url->path_segments(grep { length > 0 } $url->path_segments, $domain ? (q{domain}, $domain) : q{help});

        say STDERR sprintf('checking %s...', $url);
        my $result = $ua->request(GET($url, connection => 'close'));

        if (200 == $result->code && $result->header('content-type') =~ /^application\/(rdap\+)?json/i) {
            say STDERR sprintf('%s returned an RDAP response!', $url);
            say STDOUT $tld;

            return;
        }
    }
}
