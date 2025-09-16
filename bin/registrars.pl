#!/usr/bin/perl
use Cwd;
use Data::Mirror qw(mirror_file mirror_csv);
use DateTime;
use Encode;
use File::Slurp;
use HTML5::DOM;
use JSON::XS;
use open qw(:utf8);
use feature qw(say);
use utf8;
use strict;

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
  'rdapConformance' => [ 'rdap_level_0' ],
  'notices' => [ $NOTICE ],
  'entitySearchResults' => [],
};

my $file;

eval {
    $file = mirror_file('https://www.icann.org/en/contracted-parties/accredited-registrars/list-of-accredited-registrars');
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
    my $rows = mirror_csv('https://www.iana.org/assignments/registrar-ids/registrar-ids-1.csv');

    shift(@{$rows});
    foreach my $row (@{$rows}) {
        $urls->{$row->[0]} = $row->[3];
    }
};

die($@) if ($@);

say STDERR 'generating RDAP records for registrars...';

foreach my $rar (sort { $a->{'ianaNumber'} <=> $b->{'ianaNumber'} } @{$rars}) {
    my $id = $rar->{'ianaNumber'};

	my $data = {
		'objectClassName' => 'entity',
		'handle' => sprintf('%s-iana', $id),
        'roles' => [],
		'publicIds' => [ { 'type' => 'IANA Registrar ID', 'identifier' => sprintf("%u", $id) }],
		'rdapConformance' => [ 'rdap_level_0' ],
		'status' => [ 'active' ],
		'vcardArray' => [ 'vcard', [ [
			'version',
			{},
			'text',
			'4.0',
		] ] ],
	};

	if ($rar->{'publicContact'}->{'name'}) {
		push(@{$data->{'vcardArray'}->[1]}, [ 'fn', {}, 'text', $rar->{'publicContact'}->{'name'} ]);
		push(@{$data->{'vcardArray'}->[1]}, [ 'org', {}, 'text', $rar->{'name'} ]);

	} else {
		push(@{$data->{'vcardArray'}->[1]}, [ 'fn', {}, 'text', $rar->{'name'} ]);

	}

	if ($rar->{'publicContact'}->{'phone'}) {
		$rar->{'publicContact'}->{'phone'} =~ s/^="//g;
		$rar->{'publicContact'}->{'phone'} =~ s/"$//g;
		push(@{$data->{'vcardArray'}->[1]}, [ 'tel', {} , 'text', $rar->{'publicContact'}->{'phone'} ]);
	};

	push(@{$data->{'vcardArray'}->[1]}, [ 'email', {} , 'text', $rar->{'publicContact'}->{'email'} ]) if ($rar->{'publicContact'}->{'email'});
	push(@{$data->{'vcardArray'}->[1]}, [ 'adr', {} , 'text', [ '', '', '', '', '', '', $rar->{'country'} ] ]) if ($rar->{'country'});

	if ($rar->{'url'}) {
		push(@{$data->{'links'}}, {
			'title' => "Registrar's Website",
			'rel'   => 'related',
			'value' => $rar->{'url'},
			'href'  => $rar->{'url'},
		});
	}

    if ($urls->{$id}) {
		push(@{$data->{'links'}}, {
			'title' => "Registrar's RDAP Base URL",
			'rel'   => 'related',
			'value' => $urls->{$id},
			'href'  => $urls->{$id},
		});
    }

	$data->{'notices'} = [ $NOTICE ];

	$data->{'events'} = [ {
		'eventAction' => 'last update of RDAP database',
		'eventDate' => $updateTime,
	} ];

	#
	# add some links
	#
	push(@{$data->{'links'}}, {
		'title'	=> 'About RDAP',
		'rel'	=> 'related',
		'value'	=> 'https://about.rdap.org',
		'href'	=> 'https://about.rdap.org',
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
