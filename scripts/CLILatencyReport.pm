package CLILatencyReport;
use strict;
use warnings;

our $sample_count = 50;
our %budgets = (hookOrNotice => 150, other => 250);

# Nearest-rank p95: the 48th ordered observation in the required 50 calls.
sub summarize_family {
    my ($name, $budget_class, $samples) = @_;
    die "Invalid budget class\n" unless exists $budgets{$budget_class};
    my @durations = sort { $a <=> $b } map { $_->{'cli.call_total_ms'} } @$samples;
    my $rank = int((95 * @durations + 99) / 100);
    my $p95 = @durations ? $durations[$rank - 1] : undef;
    my $failed = scalar grep { $_->{outcome} ne 'passed' } @$samples;
    return {
        family => $name, sampleCount => scalar(@$samples), failedCalls => $failed,
        budgetMs => $budgets{$budget_class}, p95Ms => $p95,
        verdict => @durations != $sample_count ? 'NOT MEASURED'
            : $failed || $p95 > $budgets{$budget_class} ? 'FAIL' : 'PASS',
    };
}

1;
