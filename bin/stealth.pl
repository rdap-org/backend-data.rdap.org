#!perl
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
use vars qw($KNOWN @PATHS $PSL @TLDs $IANA $INFO $EXCLUDE);
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
};

#
# these are the most common prefixes in the paths of RDAP Base URLs
#
@PATHS = qw(/ /rdap /v1);

say STDERR 'running...';

say STDERR 'updating Tranco list...';
Data::Tranco->update_db;

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

    #
    # this will contain a list of hosts
    #
    my @hosts;

    push(@hosts, $KNOWN->{$tld}) if (exists($KNOWN->{$tld}));

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

    my ($domain, undef) = Data::Tranco->top_domain($tld);

    my @paths;
    if ($domain) {
        @paths = map { $_.'/domain/'.$domain } ('/'.$tld, @PATHS);

    } else {
        @paths = map { $_.'/help '} ('/'.$tld, @PATHS);

    }

    my $ua = LWP::UserAgent->new(
        user_agent => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0',
        timeout => 1,
        ssl_opts => {
            # for the purposes of this survey, we don't care about
            # whether the server has a valid TLS certificate
            verify_hostname => undef,
        }
    );

    foreach my $host (map { lc } @hosts) {
        foreach my $path (@paths) {
            $path =~ s/\/+/\//g;

            my $url = URI->new(q{https://}.$host.$path)->canonical;

            my $result = $ua->request(GET($url, connection => 'close'));

            if (200 == $result->code && $result->header('content-type') =~ m!^application/(rdap\+|)json!i) {
                say STDERR sprintf('%s is an RDAP server!', $host);
                say STDOUT $tld;

                return;
            }
        }
    }
}
