use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More 'tests' => 28;
use Test::Fatal;
use Test::Deep;
use File::Basename qw{dirname};

use TestRail::Utils;
use TestRail::Utils::Lock;
use Test::LWP::UserAgent::TestRailMock;
use File::Basename qw{basename};

#FindRuns tests

my $opts = {
    'project'    => 'TestProject'
};

my ($apiurl,$login,$pw) = ('http://testrail.local','bogus','bogus');

my $tr = new TestRail::API($apiurl,$login,$pw,undef,1);

#Mock if necesary
$tr->{'debug'} = 0;

$tr->{'browser'} = Test::LWP::UserAgent::TestRailMock::lockMockStep0();

my $runs = TestRail::Utils::Find::findRuns($opts,$tr);
is(ref $runs, 'ARRAY', "FindRuns returns ARRAYREF");
is(scalar(@$runs),4,"All runs for project found when no other options are passed");
@$runs = map {$_->{'name'}} @$runs;
my @expected = qw{OtherOtherSuite TestingSuite FinalRun lockRun};
cmp_deeply($runs,\@expected,"Tests ordered FIFO by creation date correctly");

$opts->{'lifo'} = 1;
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
@$runs = map {$_->{'name'}} @$runs;
@expected = qw{lockRun TestingSuite FinalRun OtherOtherSuite};
cmp_deeply($runs,\@expected,"Tests ordered LIFO by creation date correctly");

$opts->{'milesort'} = 1;
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
@$runs = map {$_->{'name'}} @$runs;
@expected = qw{OtherOtherSuite TestingSuite FinalRun lockRun};
cmp_deeply($runs,\@expected,"Tests ordered LIFO by milestone date correctly");

delete $opts->{'lifo'};
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
@$runs = map {$_->{'name'}} @$runs;
@expected = qw{TestingSuite FinalRun lockRun OtherOtherSuite};
cmp_deeply($runs,\@expected,"Tests ordered LIFO by milestone date correctly");

delete $opts->{'milesort'};

$opts->{'configs'} = ['eee', 'testConfig'];
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
@$runs = map {$_->{'name'}} @$runs;
is(scalar(@$runs),0,"Filtering runs by configurations works");

$opts->{'configs'} = ['testConfig'];
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
@$runs = map {$_->{'name'}} @$runs;
is(scalar(@$runs),3,"Filtering runs by configurations works");

delete $opts->{'configs'};
$opts->{'statuses'} = ['passed'];
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
is(scalar(@$runs),0,"No passing runs can be found in projects without them");

$opts->{'statuses'} = ['retest'];
$runs = TestRail::Utils::Find::findRuns($opts,$tr);
is(scalar(@$runs),1,"Failed runs can be found in projects with them");

#Test testrail-tests

$opts = {
    'project'    => 'TestProject',
    'plan'       => 'GosPlan',
    'run'        => 'Executing the great plan',
    'match'      => $FindBin::Bin,
    'configs'    => ['testConfig'],
    'no-recurse' => 1,
    'names-only' => 1
};

my $cases = TestRail::Utils::Find::getTests($opts,$tr);
my @tests = TestRail::Utils::Find::findTests($opts,@$cases);
@expected = ("$FindBin::Bin/skipall.test");
cmp_deeply(\@tests,\@expected,"findTests: match, no-recurse, plan mode, names-only");

delete $opts->{'names-only'};
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
@tests = map {$_->{'full_title'}} @tests;
cmp_deeply(\@tests,\@expected,"findTests: match, no-recurse, plan mode");

delete $opts->{'match'};
$opts->{'no-match'} = $FindBin::Bin;
$opts->{'names-only'} = 1;
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(grep {$_ eq 'skipall.test'} @tests),0,"Tests in tree are not returned in no-match mode");
is(scalar(grep {$_ eq 'NOT SO SEARED AFTER ALL'} @tests),0,"Tests not in tree that do exist are not returned in no-match mode");
is(scalar(grep {$_ eq $FindBin::Bin.'/faker.test'} @tests),1,"Orphan Tests in tree ARE returned in no-match mode");
is(scalar(@tests),26,"Correct number of non-existant cases shown (no-match, names-only)");

$opts->{'configs'} = ['testPlatform1'];
isnt(exception { TestRail::Utils::Find::getTests($opts,$tr) } , undef,"Correct number of non-existant cases shown (no-match, names-only)");
$opts->{'configs'} = ['testConfig'];

delete $opts->{'names-only'};
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
my @filtered_tests = grep {defined $_} map {$_->{'full_title'}} @tests;
is(scalar(@filtered_tests),0,"Full titles not returned in no-match mode");
is(scalar(@tests),26,"Correct number of nonexistant cases shown in no-match mode");

delete $opts->{'no-recurse'};
$opts->{'names-only'} = 1;
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),30,"Correct number of non-existant cases shown (no-match, names-only, recurse)");

#mutual excl
$opts->{'match'} = $FindBin::Bin;
$cases = TestRail::Utils::Find::getTests($opts,$tr);
isnt(exception {TestRail::Utils::Find::findTests($opts,@$cases)},undef,"match and no-match are mutually exclusive");
delete $opts->{'no-match'};

delete $opts->{'plan'};
$opts->{'run'} = 'TestingSuite';
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),1,"Correct number of non-existant cases shown (match, plain run)");
is(scalar(grep {$_ eq "$FindBin::Bin/skipall.test"} @tests),1,"Tests in tree are returned in match, plain run mode");

#Now that we've made sure configs are ignored...
$opts->{'plan'} = 'GosPlan';
$opts->{'run'} = 'Executing the great plan';
$opts->{'users'} = ['teodesian'];
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),1,"Correct number of cases shown (match, plan run, assignedto pos)");
is(scalar(grep {$_ eq "$FindBin::Bin/skipall.test"} @tests),1,"Tests in tree are returned filtered by assignee");

$opts->{'users'} = ['billy'];
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),0,"Correct number of cases shown (match, plan run, assignedto neg)");

delete $opts->{'users'};
$opts->{'statuses'} = ['passed'];
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),1,"Correct number of cases shown (match, plan run, passed)");

$opts->{'statuses'} = ['failed'];
delete $opts->{'match'};
$cases = TestRail::Utils::Find::getTests($opts,$tr);
@tests = TestRail::Utils::Find::findTests($opts,@$cases);
is(scalar(@tests),0,"Correct number of cases shown (match, plan run, failed)");
