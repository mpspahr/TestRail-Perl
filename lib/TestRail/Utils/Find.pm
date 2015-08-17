# PODNAME: TestRail::Utils::Find
# ABSTRACT: Find runs and tests according to user specifications.

package TestRail::Utils::Find;

use strict;
use warnings;

use Carp qw{confess cluck};
use Scalar::Util qw{blessed};

use File::Find;
use Cwd qw{abs_path};
use File::Basename qw{basename};

use TestRail::Utils;

=head1 DESCRIPTION

=head1 FUNCTIONS

=head2 findRuns

Find runs based on the options HASHREF provided.
See the documentation for L<testrail-runs>, as the long argument names there correspond to hash keys.

The primary routine of testrail-runs.

=over 4

=item HASHREF C<OPTIONS> - flags acceptable by testrail-tests

=item TestRail::API C<HANDLE> - TestRail::API object

=back

Returns ARRAYREF of run definition HASHREFs.

=cut

sub findRuns {
    my ($opts,$tr) = @_;
    confess("TestRail handle must be provided as argument 2") unless blessed($tr) eq 'TestRail::API';

    my ($status_labels);

    #Process statuses
    if ($opts->{'statuses'}) {
        @$status_labels = $tr->statusNamesToLabels(@{$opts->{'statuses'}});
    }

    my $project = $tr->getProjectByName($opts->{'project'});
    confess("No such project '$opts->{project}'.\n") if !$project;

    my $pconfigs = [];
    @$pconfigs = $tr->translateConfigNamesToIds($project->{'id'},@{$opts->{configs}}) if $opts->{'configs'};

    my ($runs,$plans,$planRuns,$cruns,$found) = ([],[],[],[],0);
    $runs = $tr->getRuns($project->{'id'}) if (!$opts->{'configs'}); # If configs are passed, global runs are not in consideration.
    $plans = $tr->getPlans($project->{'id'});
    @$plans = map {$tr->getPlanByID($_->{'id'})} @$plans;
    foreach my $plan (@$plans) {
        $cruns = $tr->getChildRuns($plan);
        next if !$cruns;
        foreach my $run (@$cruns) {
            next if scalar(@$pconfigs) != scalar(@{$run->{'config_ids'}});

            #Compare run config IDs against desired, invalidate run if all conditions not satisfied
            $found = 0;
            foreach my $cid (@{$run->{'config_ids'}}) {
                $found++ if grep {$_ == $cid} @$pconfigs;
            }
            $run->{'created_on'}   = $plan->{'created_on'};
            $run->{'milestone_id'} = $plan->{'milestone_id'};
            push(@$planRuns, $run) if $found == scalar(@{$run->{'config_ids'}});
        }
    }

    push(@$runs,@$planRuns);

    if ($opts->{'statuses'}) {
        @$runs =  $tr->getRunSummary(@$runs);
        @$runs = grep { defined($_->{'run_status'}) } @$runs; #Filter stuff with no results
        foreach my $status (@$status_labels) {
            @$runs = grep { $_->{'run_status'}->{$status} } @$runs; #If it's positive, keep it.  Otherwise forget it.
        }
    }

    #Sort FIFO/LIFO by milestone or creation date of run
    my $sortkey = 'created_on';
    if ($opts->{'milesort'}) {
        @$runs = map {
            my $run = $_;
            $run->{'milestone'} = $tr->getMilestoneByID($run->{'milestone_id'}) if $run->{'milestone_id'};
            my $milestone = $run->{'milestone'} ? $run->{'milestone'}->{'due_on'} : 0;
            $run->{'due_on'} = $milestone;
            $run
        } @$runs;
        $sortkey = 'due_on';
    }

    if ($opts->{'lifo'}) {
        @$runs = sort { $b->{$sortkey} <=> $a->{$sortkey} } @$runs;
    } else {
        @$runs = sort { $a->{$sortkey} <=> $b->{$sortkey} } @$runs;
    }

    return $runs;
}

=head2 getTests(opts,testrail)

Get the tests specified by the options passed.

=over 4

=item HASHREF C<OPTS> - Options for getting the tests

=over 4

=item STRING C<PROJECT> - name of Project to look for tests in

=item STRING C<RUN> - name of Run to get tests from

=item STRING C<PLAN> (optional) - name of Plan to get run from

=item ARRAYREF[STRING] C<CONFIGS> (optional) - names of configs run must satisfy, if part of a plan

=item ARRAYREF[STRING] C<USERS> (optional) - names of users to filter cases by assignee

=item ARRAYREF[STRING] C<STATUSES> (optional) - names of statuses to filter cases by

=back

=back

Returns ARRAYREF of tests, and the run in which they belong.

=cut

sub getTests {
    my ($opts,$tr) = @_;
    confess("TestRail handle must be provided as argument 2") unless blessed($tr) eq 'TestRail::API';

    my (undef,undef,$run) = TestRail::Utils::getRunInformation($tr,$opts);
    my ($status_ids,$user_ids);

    #Process statuses
    @$status_ids = $tr->statusNamesToIds(@{$opts->{'statuses'}}) if $opts->{'statuses'};

    #Process assignedto ids
    @$user_ids = $tr->userNamesToIds(@{$opts->{'users'}}) if $opts->{'users'};

    my $cases = $tr->getTests($run->{'id'},$status_ids,$user_ids);
    return ($cases,$run);
}

=head2 findTests(opts,case1,...,caseN)

Given an ARRAY of tests, find tests meeting your criteria (or not) in the specified directory.

=over 4

=item HASHREF C<OPTS> - Options for finding tests:

=over 4

=item STRING C<MATCH> - Only return tests which exist in the path provided, and in TestRail.  Mutually exclusive with no-match, orphans.

=item STRING C<NO-MATCH> - Only return tests which are in the path provided, but not in TestRail.  Mutually exclusive with match, orphans.

=item STRING C<ORPHANS> - Only return tests which are in TestRail, and not in the path provided.  Mutually exclusive with match, no-match

=item BOOL C<NO-RECURSE> - Do not do a recursive scan for files.

=item BOOL C<NAMES-ONLY> - Only return the names of the tests rather than the entire test objects.

=item STRING C<EXTENSION> (optional) - Only return files ending with the provided text (e.g. .t, .test, .pl, .pm)

=back

=item ARRAY C<CASES> - Array of cases to translate to pathnames based on above options.

=back

Returns tests found that meet the criteria laid out in the options.
Provides absolute path to tests if match is passed; this is the 'full_title' key if names-only is false/undef.
Dies if mutually exclusive options are passed.

=cut

sub findTests {
    my ($opts,@cases) = @_;

    confess "Error! match and no-match options are mutually exclusive.\n" if ($opts->{'match'} && $opts->{'no-match'});
    confess "Error! match and orphans options are mutually exclusive.\n" if ($opts->{'match'} && $opts->{'orphans'});
    confess "Error! no-match and orphans options are mutually exclusive.\n" if ($opts->{'orphans'} && $opts->{'no-match'});
    my @tests = @cases;
    my (@realtests);
    my $ext = $opts->{'extension'} // '';

    if ($opts->{'match'} || $opts->{'no-match'} || $opts->{'orphans'}) {
        my @tmpArr = ();
        my $dir = ($opts->{'match'} || $opts->{'orphans'}) ? ($opts->{'match'} || $opts->{'orphans'}) : $opts->{'no-match'};
        if (!$opts->{'no-recurse'}) {
            File::Find::find( sub { push(@realtests,$File::Find::name) if -f && m/\Q$ext\E$/ }, $dir );
        } else {
            @realtests = glob("$dir/*$ext");
        }
        foreach my $case (@cases) {
            foreach my $path (@realtests) {
                next unless $case->{'title'} eq basename($path);
                $case->{'path'} = $path;
                push(@tmpArr, $case);
                last;
            }
        }
        @tmpArr = grep {my $otest = $_; !(grep {$otest->{'title'} eq $_->{'title'}} @tmpArr) } @tests if $opts->{'orphans'};
        @tests = @tmpArr;
        @tests = map {{'title' => $_}} grep {my $otest = basename($_); scalar(grep {basename($_->{'title'}) eq $otest} @tests) == 0} @realtests if $opts->{'no-match'}; #invert the list in this case.
    }

    @tests = map { abs_path($_->{'path'}) } @tests if $opts->{'match'} && $opts->{'names-only'};
    @tests = map { $_->{'full_title'} = abs_path($_->{'path'}); $_ } @tests if $opts->{'match'} && !$opts->{'names-only'};
    @tests = map { $_->{'title'} } @tests if !$opts->{'match'} && $opts->{'names-only'};

    return @tests;
}

=head2 getCases

Get cases in a testsuite matching your parameters passed

=cut

sub getCases {
    my ($opts,$tr) = @_;
    confess("First argument must be instance of TestRail::API") unless blessed($tr) eq 'TestRail::API';

    my $project = $tr->getProjectByName($opts->{'project'});
    confess "No such project '$opts->{project}'.\n" if !$project;

    my $suite = $tr->getTestSuiteByName($project->{'id'},$opts->{'testsuite'});
    confess "No such testsuite '$opts->{testsuite}'.\n" if !$suite;
    $opts->{'testsuite_id'} = $suite->{'id'};

    my $section;
    $section = $tr->getSectionByName($project->{'id'},$suite->{'id'},$opts->{'section'}) if $opts->{'section'};
    confess "No such section '$opts->{section}.\n" if $opts->{'section'} && !$section;

    my $section_id;
    $section_id = $section->{'id'} if ref $section eq "HASH";

    my $type_ids;
    @$type_ids = $tr->typeNamesToIds(@{$opts->{'types'}}) if ref $opts->{'types'} eq 'ARRAY';
    #Above will confess if anything's the matter

    #TODO Translate opts into filters
    my $filters = {
        'section_id' => $section_id,
        'type_id'    => $type_ids
    };

    return $tr->getCases($project->{'id'},$suite->{'id'},$filters);
}

sub findCases {
    my ($opts,@cases) = @_;

    my $ret = {'testsuite_id' => $opts->{'testsuite_id'}};
    if (!$opts->{'no-missing'}) {
        my $mopts = {
            'no-match'   => $opts->{'directory'},
            'names-only' => 1,
            'extension'  => $opts->{'extension'}
        };
        my @missing = findTests($mopts,@cases);
        $ret->{'missing'} = \@missing;
    }
    if ($opts->{'orphans'}) {
        my $oopts = {
            'orphans'    => $opts->{'directory'},
            'extension'  => $opts->{'extension'}
        };
        my @orphans = findTests($oopts,@cases);
        $ret->{'orphans'} = \@orphans;
    }
    if ($opts->{'update'}) {
        my $uopts = {
            'match'     => $opts->{'directory'},
            'extension' => $opts->{'extension'}
        };
        my @updates = findTests($uopts,@cases);
        $ret->{'update'} = \@updates;
    }
    return $ret;
}

=head2 synchronize($instructions,$tr)

Add, update and remove cases from a testsuite based on the provided instructions hash.

Expects hash to have the following keys:

    testuite_id => int
    missing => array of tests to add to TestRail
    update  => array of tests to update in TestRail
    orphans => array of tests to remove from TestRail
    test    => don't actually do anything, just print what would have happened

Second argument is a testRail handle.

=cut

sub synchronize {
    my ($instructions,$tr) = @_;

    if (ref $instructions->{'missing'} eq "ARRAY" && scalar(@{$instructions->{'missing'}})) {
        foreach my $test (@{$instructions->{'missing'}}) {
            print "Adding test $test...\n";
            next if $instructions->{'test'};
            #TODO get or create relevant section, mapping directory -> section
            my $relevantSection = {};
            #TODO pass other relevant data
            $tr->createCase($relevantSection->{'id'},basename($test));
        }
    }

    if (ref $instructions->{'orphans'} eq "ARRAY" && scalar(@{$instructions->{'orphans'}})) {
        foreach my $test (@{$instructions->{'orphans'}}) {
            print "Deleting test $test->{title}...\n";
            next if $instructions->{'test'};
            $tr->deleteCase($test->{'id'});
        }
    }

    if (ref $instructions->{'update'} eq "ARRAY" && scalar(@{$instructions->{'update'}})) {
        foreach my $test (@{$instructions->{'update'}}) {
            print "Updating test $test->{title}...\n";
            next if $instructions->{'test'};
            #TODO use special updater class
            my $caseOpts = {'description' => "Automated test found in ".$test->{'full_title'}."\n"};
            $tr->updateCase($test->{'id'},$caseOpts);
        }
    }

    return 1;
}

1;

__END__

=head1 SPECIAL THANKS

Thanks to cPanel Inc, for graciously funding the creation of this module.
