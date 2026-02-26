#!/usr/bin/env perl
use Cwd;
use Data::Mirror qw(mirror_file mirror_csv mirror_json);
use DateTime;
use Encode;
use File::Slurp;
use HTML5::DOM;
use JSON::XS;
use URI;
use constant {
    ICANN_REGISTRAR_LIST_URL    => 'https://www.icann.org/en/contracted-parties/accredited-registrars/list-of-accredited-registrars',
    IANA_REGISTRAR_LIST_URL     => 'https://www.iana.org/assignments/registrar-ids/registrar-ids-1.csv',
};
use open qw(:utf8);
use feature qw(say);
use utf8;
use strict;

#
# these are the base URLs of the largest gTLDs, which are the ones that are most
# likely to have records for ICANN-accredited registrars
#
my @RDAP_SERVERS = qw(
    https://rdap.verisign.com/com/v1/
    https://rdap.publicinterestregistry.org/rdap/
    https://rdap.nic.biz/
    https://rdap.centralnic.com/xyz/
);

say STDERR 'updating registrar RDAP data...';

my $NOTICE = {
    'title' => 'About This Service',
    'description' => [
        'Please note that this RDAP service is NOT provided by the IANA.',
        '',
        'For more information, please see https://about.rdap.org',
    ],
};

my $updateTime = DateTime->now->iso8601;

$Data::Mirror::TTL_SECONDS = 3600;

my $dir = $ARGV[0] || getcwd();

if (!-e $dir || !-d $dir) {
    printf(STDERR "Error: %s doesn't exist, please create it first\n");
    exit(1);
}

my $json = JSON::XS->new->utf8->pretty->canonical;

my $all = {
  'rdapConformance'     => [ 'rdap_level_0' ],
  'notices'             => [ $NOTICE ],
  'entitySearchResults' => [],
};

my $file;

eval {
    $file = mirror_file(ICANN_REGISTRAR_LIST_URL);
};

die($@) if ($@);

say STDERR 'retrieved registrar list, attempting to parse';

my $parser = HTML5::DOM->new;

my $doc = $parser->parse(join('', read_file($file)));

say STDERR 'searching for embedded JSON...';

my $rars;
eval {
    my $data = [grep { 'ng-state' eq $_->attr('id') && 'application/json' eq $_->attr('type') } @{$doc->getElementsByTagName('script')}]->[0]->textContent;
    $data =~ s/\&q;/"/g;

    my $object = $json->decode(Encode::encode_utf8($data));

    $rars = $object->{'accredited-registrars-{"languageTag":"en","siteLanguageTag":"en","slug":"contracted-parties/accredited-registrars/list-of-accredited-registrars"}'}->{'data'}->{'accreditedRegistrarsOperations'}->{'registrars'};
};

die($@) if ($@);

if (scalar(@{$rars}) < 1) {
    say STDERR 'no registrars found, the page format may have changed...';
    exit(1);
}

say STDERR 'retrieving IANA registry...';
my $urls = {};
eval {
    my $rows = mirror_csv(IANA_REGISTRAR_LIST_URL);

    shift(@{$rows});
    foreach my $row (@{$rows}) {
        $urls->{$row->[0]} = $row->[3];
    }
};

die($@) if ($@);

say STDERR 'generating RDAP records for registrars...';

foreach my $id (sort { $a <=> $b } keys(%{$urls})) {
    my $rar = [ grep { $id == $_->{'ianaNumber'} } @{$rars} ]->[0];
    next unless ($rar);

    my $handle = sprintf('%s-iana', $id);

    my $self = "https://registrars.rdap.org/entity/".$handle;

    my (@vcard, @entities, @remarks, @links);
    SERVER: foreach my $server (@RDAP_SERVERS) {
        my $url = URI->new_abs('entity/'.$id, $server);

        my $rdap;
        eval {
            $rdap = mirror_json($url);
        };

        if ($rdap) {
            @vcard = @{$rdap->{vcardArray}->[1] || []};
            push(@entities, @{$rdap->{entities} || []});

            push(@remarks, {
                "title" => "Data Source",
                "description" => [ sprintf("The contact information in this record was retrieved from %s. Please follow the 'canonical' link to see the original record.", $url->authority) ],
            });

            push(@links, {
                "rel"   => "canonical",
                "title" => "Original source for this record",
                "type"  => "application/rdap+json",
                "value" => $self,
                "href"  => $url->as_string,
            });
            last SERVER;
        }
    }

    if (scalar(@vcard) < 1) {
        #
        # no record found at a public RDAP server, construct a vcard from the
        # ICANN data
        #
        push(@vcard, [ 'version', {}, 'text', '4.0' ]);

        if ($rar->{'publicContact'}->{'name'}) {
            push(@vcard, [ 'fn', {}, 'text', $rar->{'publicContact'}->{'name'} ]);
            push(@vcard, [ 'org', {}, 'text', $rar->{'name'} ]);

        } else {
            push(@vcard, [ 'fn', {}, 'text', $rar->{'name'} ]);

        }

        if ($rar->{'publicContact'}->{'phone'}) {
            $rar->{'publicContact'}->{'phone'} =~ s/^="//g;
            $rar->{'publicContact'}->{'phone'} =~ s/"$//g;
            push(@vcard, [ 'tel', {} , 'text', $rar->{'publicContact'}->{'phone'} ]);
        };

        push(@vcard, [ 'email', {} , 'text', $rar->{'publicContact'}->{'email'} ]) if ($rar->{'publicContact'}->{'email'});
        push(@vcard, [ 'adr', {} , 'text', [ '', '', '', '', '', '', $rar->{'country'} ] ]) if ($rar->{'country'});

        push(@remarks, {
            "title"         => "Data Source",
            "description"   => [ "The contact information in this record was retrieved from ICANN." ],
        });
    }

    push(@links, {
        "rel"   => "self",
        "value" => $self,
        "href"  => $self,
    });

    push(@links, {
        "rel"   => "collection",
        "value" => $self,
        "title" => "Official ICANN Registrar List",
        "href"  => ICANN_REGISTRAR_LIST_URL,
    });

    push(@links, {
        "rel"   => "collection",
        "value" => $self,
        "title" => "IANA Registrar IDs",
        "href"  => IANA_REGISTRAR_LIST_URL,
    });

    my $data = {
        'objectClassName'   => 'entity',
        'handle'            => $handle,
        'roles'             => [],
        'publicIds'         => [ { 'type' => 'IANA Registrar ID', 'identifier' => sprintf("%u", $id) }],
        'rdapConformance'   => [ 'rdap_level_0' ],
        'status'            => [ 'active' ],
        'vcardArray'        => [ 'vcard', \@vcard ],
        'entities'          => \@entities,
        'remarks'           => \@remarks,
        'links'             => \@links,
    };

    if ($rar->{'url'}) {
        push(@{$data->{'links'}}, {
            'title' => "Registrar's Website",
            'rel'   => 'related',
            "value" => $self,
            'href'  => $rar->{'url'},
        });
    }

    if ($urls->{$id}) {
        push(@{$data->{'links'}}, {
            'title' => "Registrar's RDAP Base URL",
            'rel'   => 'related',
            "value" => $self,
            'href'  => $urls->{$id},
        });
    }

    $data->{'notices'} = [ $NOTICE ];

    $data->{'events'} = [ {
        'eventAction'   => 'last update of RDAP database',
        'eventDate'     => $updateTime,
    } ];

    #
    # add some links
    #
    push(@{$data->{'links'}}, {
        'title' => 'About RDAP',
        'rel'   => 'related',
        "value" => $self,
        'href'  => 'https://about.rdap.org',
    });

    #
    # write RDAP object to disk
    #
    my $jfile = sprintf('%s/%s.json', $dir, $data->{'handle'});

    if (!write_file($jfile, {'binmode' => ':utf8'}, $json->encode($data))) {
        printf(STDERR "Unable to write data to '%s': %s\n", $jfile, $!);
        exit(1);
    }

    delete($data->{'notices'});
    delete($data->{'rdapConformance'});

    push(@{$all->{'entitySearchResults'}}, $data);
}

say STDERR 'RDAP records generated, writing registrar search result file...';

#
# write RDAP object to disk
#
my $jfile = sprintf('%s/_all.json', $dir);

if (!write_file($jfile, {'binmode' => ':utf8'}, $json->encode($all))) {
    printf(STDERR "Unable to write to '%s': %s\n", $jfile, $!);
    exit(1);

} else {
    say STDERR sprintf('wrote %s', $jfile);

}

say STDERR 'done';
