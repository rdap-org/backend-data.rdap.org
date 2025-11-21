#!/usr/bin/env perl
use DBI;
use Fcntl qw(:flock);
use HTTP::Request::Common qw(GET DELETE);
use JSON::XS;
use LWP::UserAgent;
use constant URL => q{https://rdap.org/stats};
use vars qw(@SERIES $DB);
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

$DB->do(q{CREATE TABLE IF NOT EXISTS total_queries (
    id          INTEGER PRIMARY KEY,
    timestamp   INTEGER UNIQUE,
    count       INTEGER
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

my $ua = LWP::UserAgent->new;

#
# 1. get current stats
#

my $req1 = GET(URL);
$req1->header(authorization => sprintf(q{Bearer %s}, $ENV{STATS_TOKEN}));

say STDERR q{getting stats...};

my $res1 = $ua->request($req1);

die($res1->status_line) unless ($res1->is_success);

#
# 2. clear stats
#
my $req2 = DELETE(URL);
$req2->header(authorization => sprintf(q{Bearer %s}, $ENV{STATS_TOKEN}));

say STDERR q{purging stats...};
my $res2 = $ua->request($req2);

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

say STDERR q{done};

__DATA__
