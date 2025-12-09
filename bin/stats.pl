#!/usr/bin/env perl
use Data::Printer;
use DBI;
use Fcntl qw(:flock);
use HTTP::Request::Common qw(GET DELETE POST);
use JSON::XS;
use LWP::UserAgent;
use constant {
    STATS_URL               => q{https://rdap.org/stats},
    ALERTABLE_QUERY_RATE    => 50,
    PUSHOVER_URL            => q{https://api.pushover.net/1/messages.json},
};
use vars qw(@SERIES $DB $UA);
use common::sense;

if (!flock(DATA, LOCK_EX | LOCK_NB)) {
    say STDERR q{waiting for existing process to finish...};
    flock(DATA, LOCK_EX);
}

@SERIES = qw(status type user_agent network tld origin);

say STDERR q{opening database connection...};
my $DB = DBI->connect(sprintf(
    q{dbi:SQLite:dbname=%s},
    $ARGV[0] || q{./stats.db}
));

$DB->do(q{CREATE TABLE IF NOT EXISTS `total_queries` (
    `id`        INTEGER PRIMARY KEY,
    `timestamp` INTEGER UNIQUE,
    `count`     INTEGER
)});

foreach my $column (@SERIES) {
    $DB->do(sprintf(q{CREATE TABLE IF NOT EXISTS `queries_by_%s` (
        `id`        INTEGER PRIMARY KEY,
        `timestamp` INTEGER,
        `%s`        TEXT,
        `count`     INTEGER
    )}, $column, $column));

    $DB->do(sprintf(
        q{CREATE UNIQUE INDEX IF NOT EXISTS `queries_by_%s_index` ON `queries_by_%s`(`timestamp`, `%s`)},
        $column,
        $column,
        $column,
    ));
}

$UA = LWP::UserAgent->new;

#
# 1. get current stats
#

my $req1 = GET(STATS_URL);
$req1->header(authorization => sprintf(q{Bearer %s}, $ENV{STATS_TOKEN}));

say STDERR q{getting stats...};

my $res1 = $UA->request($req1);

die($res1->status_line) unless ($res1->is_success);

#
# 2. clear stats
#
my $req2 = DELETE(STATS_URL);
$req2->header(authorization => sprintf(q{Bearer %s}, $ENV{STATS_TOKEN}));

say STDERR q{purging stats...};
my $res2 = $UA->request($req2);

die($res2->status_line) unless ($res2->is_success);

#
# store stats in DB
#

my $stats = JSON::XS->new->utf8->decode($res1->decoded_content);

my $timestamp = delete($stats->{timestamp});

say STDERR q{updating database...};

$DB->prepare(q{
    INSERT INTO `total_queries`
    (`timestamp`, `count`)
    VALUES (?, ?)
})->execute(
    $timestamp,
    delete($stats->{total_queries}),
);

foreach my $column (@SERIES) {
    my $key = sprintf(q{queries_by_%s}, $column);

    my $sth = $DB->prepare(sprintf(
        q{
            INSERT INTO `%s`
            (`timestamp`, `%s`, `count`)
            VALUES (?, ?, ?)
        },
        $key,
        $column,
    ));

    foreach my $value (keys(%{$stats->{$key}})) {
        $sth->execute(
            $timestamp,
            $value,
            $stats->{$key}->{$value},
        );
    }
}

say STDERR q{running checks...};

my $sth = $DB->prepare(q{SELECT * FROM `total_queries` ORDER BY `timestamp` DESC LIMIT 0,3});
$sth->execute;

my $r2 = $sth->fetchrow_hashref;
my $r1 = $sth->fetchrow_hashref;
my $r0 = $sth->fetchrow_hashref;

my $curr_rate = $r2->{count} / ($r2->{timestamp} - $r1->{timestamp});
my $prev_rate = $r1->{count} / ($r1->{timestamp} - $r0->{timestamp});

printf(STDERR qq{query rate is %.1fqps (previously %.1fqps)\n}, $curr_rate, $prev_rate);

my $alert;

if ($curr_rate >= ALERTABLE_QUERY_RATE || $prev_rate >= ALERTABLE_QUERY_RATE) {
    $alert = {
        title   => sprintf(q{RDAP.ORG query rate exceeds %uqps}, ALERTABLE_QUERY_RATE),
        message => sprintf(q{As of %s, the query rate is %.1fqps (previously %.1fs).}, scalar(gmtime($r1->{timestamp})), $curr_rate, $prev_rate),
    };

} elsif ($curr_rate <= ALERTABLE_QUERY_RATE && $prev_rate >= ALERTABLE_QUERY_RATE) {
    $alert = {
        title   => sprintf(q{RDAP.ORG query rate below %uqps}, ALERTABLE_QUERY_RATE),
        message => sprintf(q{As of %s, the query rate is now %.1fqps (previously %.1fs).}, scalar(gmtime($r1->{timestamp})), $curr_rate, $prev_rate),
    };

}

if ($alert) {
    say STDERR q{sending notification...};

    my $res = $UA->request(POST(PUSHOVER_URL, Content => {
        token   => $ENV{PUSHOVER_APP_TOKEN},
        user    => $ENV{PUSHOVER_USER_TOKEN},
        url     => q{https://stats.rdap.org/private},
        %{$alert},
    }));

    exit(1) unless ($res->is_success);
}

say STDERR q{done};

__DATA__
