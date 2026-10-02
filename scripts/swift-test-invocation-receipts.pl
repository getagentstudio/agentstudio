#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
use Encode qw(decode FB_CROAK);
use Fcntl qw(O_WRONLY O_CREAT O_APPEND);

my $json = JSON::PP->new->utf8->canonical;
my $text_json = JSON::PP->new;
my $mode = shift @ARGV // '';
my $prefix = $ENV{LOG_PREFIX} // 'test';

sub load_json {
    my ($path) = @_;
    open my $input, '<:raw', $path or return {};
    local $/;
    my $record = eval { $json->decode(<$input>) };
    return ref($record) eq 'HASH' ? $record : {};
}
sub save_json {
    my ($path, $record) = @_;
    open my $output, '>:raw', "$path.tmp-$$" or die $!;
    print {$output} $json->encode($record), "\n";
    close $output or die $!;
    rename "$path.tmp-$$", $path or die $!;
}
sub numeric { defined $_[0] && !ref($_[0]) && $_[0] =~ /^-?\d+(?:\.\d+)?$/ }
sub write_lines {
    my ($path, $lines) = @_;
    open my $output, '>:raw', $path or die $!;
    print {$output} encode_utf8($_), "\n" for @$lines;
    close $output;
}
sub encode_utf8 { Encode::encode('UTF-8', $_[0]) }
sub wait_key {
    my ($kind, $fields, $metadata) = @_;
    return 'fact:' . $fields->[1] if $kind eq 'expecting' || $kind eq 'settled';
    my $waiter = $kind eq 'wait_settled' ? $fields->[2] : ($metadata->{waiterID} // 'unknown');
    return 'step:' . $fields->[1] . ':' . $waiter;
}
sub apply_wait {
    my ($row, $pending, $arrived, $closed) = @_;
    my ($kind, $fields, $metadata) = @$row{qw(kind fields metadata)};
    my $key = wait_key($kind, $fields, $metadata);
    if ($kind eq 'arrived') {
        $arrived->{$fields->[1]} = 1;
        delete $pending->{$_} for grep { ($pending->{$_}{step_id} // '') eq $fields->[1] } keys %$pending;
    } elsif ($kind eq 'settled' || $kind eq 'wait_settled') {
        $closed->{$key} = 1;
        delete $pending->{$key};
    } elsif (!$closed->{$key} && !($kind eq 'waiting' && $arrived->{$fields->[1]})) {
        $pending->{$key} = {
            kind => $kind eq 'waiting' ? 'held_step' : 'typed_fact',
            id => $fields->[1], step_id => $kind eq 'waiting' ? $fields->[1] : undef,
            waiter_id => $metadata->{waiterID}, name => $fields->[2],
            scope => $kind eq 'expecting' ? $fields->[3] : undef,
            site => $kind eq 'expecting' ? $fields->[5] : $fields->[3],
            test_id => $metadata->{testID}, parameterized => $metadata->{parameterized},
            test_site => $kind eq 'expecting' ? $fields->[4] : $fields->[3],
            order => $row->{order},
        };
    }
}

if ($mode eq 'collect') {
    my ($stem, $output_path, $events_path, $held_path, $snapshot) = @ARGV;
    my (@waits, @legacy, @issues, %definitions, %active, %cases, %started);
    my ($legacy_count, $malformed_waits, $invalid_events, $valid_events, $unclassified_tests) = (0, 0, 0, 0, 0);
    my ($announced, $ended, $case_started, $case_ended) = (0, 0, 0, 0);
    my $held_available = open(my $held, '<:raw', $held_path // '');
    my $order = 0;
    if ($held_available) {
        while (my $raw = <$held>) {
            next unless $raw =~ /\n\z/;
            my $line = eval { decode('UTF-8', $raw, FB_CROAK) };
            if (!defined $line) { $malformed_waits++; next }
            chomp $line;
            my @fields = split /\t/, $line, -1;
            my $kind = $fields[0] // '';
            next unless $kind =~ /^(waiting|arrived|wait_settled|expecting|settled)$/;
            my $metadata = eval { $text_json->decode($fields[-1]) };
            my $valid = ref($metadata) eq 'HASH' && ($metadata->{clockDomain} // '') eq 'CLOCK_UPTIME_RAW'
                && numeric($metadata->{seconds}) && numeric($metadata->{nanoseconds})
                && $metadata->{nanoseconds} >= 0 && $metadata->{nanoseconds} < 1_000_000_000
                && defined $metadata->{testID};
            my $row = {kind => $kind, fields => \@fields, metadata => $valid ? $metadata : {}, order => $order++};
            push @legacy, $row;
            if ($valid) {
                $row->{time} = $metadata->{seconds} + $metadata->{nanoseconds} / 1_000_000_000;
                push @waits, $row;
            } else { $legacy_count++ }
        }
        close $held;
    }
    my $logger_unavailable = 0;
    if (open my $output, '<:raw', $output_path // '') {
        while (<$output>) { $logger_unavailable = 1 if /\[agentstudio-test-log\] unavailable / }
        close $output;
    }
    my $events_available = open(my $events, '<:raw', $events_path // '');
    if ($events_available) {
        while (my $line = <$events>) {
            next unless $line =~ /\n\z/;
            my $raw = eval { $json->decode($line) };
            if (ref($raw) ne 'HASH') { $invalid_events++; next }
            $valid_events++;
            my $event = ref($raw->{payload}) eq 'HASH' ? $raw->{payload} : $raw;
            my $kind = $event->{kind} // '';
            if (($raw->{kind} // '') eq 'test') {
                $definitions{$event->{id}} = $event if defined $event->{id};
                next;
            }
            my $id = $event->{testID};
            my $instant = ref($event->{instant}) eq 'HASH' ? $event->{instant}{absolute} : undef;
            my $is_function = defined($id) && (($definitions{$id}{kind} // '') eq 'function');
            if (($kind eq 'testStarted' || $kind eq 'testEnded') && defined($id)
                && !defined($definitions{$id}{kind})) { $unclassified_tests++ }
            if ($kind eq 'testStarted' && $is_function) {
                $announced++; $active{$id} = 1; $started{$id} = $instant;
            } elsif ($kind eq 'testEnded' && $is_function) {
                $ended++; delete $active{$id};
            } elsif ($kind eq 'testCaseStarted' || $kind eq 'testCaseEnded') {
                my $case_id = ref($event->{_testCase}) eq 'HASH' ? $event->{_testCase}{id} : undef;
                if ($kind eq 'testCaseStarted') {
                    $case_started++; $cases{$id}{$case_id} = 1 if defined($id) && defined($case_id);
                } else {
                    $case_ended++; delete $cases{$id}{$case_id} if defined($id) && defined($case_id);
                }
            } elsif ($kind eq 'issueRecorded') {
                my $begin = defined($id) ? $started{$id} : undef;
                push @issues, {
                    test_id => $id, issue_time => numeric($instant) ? 0 + $instant : undef,
                    start_to_issue_seconds => numeric($instant) && numeric($begin) && $instant >= $begin
                        ? $instant - $begin : undef,
                    concurrently_announced_tests => $unclassified_tests ? undef : scalar(keys %active),
                    running_parameterized_cases => defined($id) ? scalar(keys %{$cases{$id} // {}}) : undef,
                    parameterized => defined($id) ? $definitions{$id}{isParameterized} : undef,
                };
            }
        }
        close $events;
    }
    @waits = sort { $a->{time} <=> $b->{time} || $a->{order} <=> $b->{order} } @waits;
    @issues = sort { ($a->{issue_time} // 0) <=> ($b->{issue_time} // 0) } @issues;
    my (%pending, %arrived, %closed, @reports);
    my $next_wait = 0;
    for my $issue (@issues) {
        while (defined($issue->{issue_time}) && $next_wait < @waits && $waits[$next_wait]{time} <= $issue->{issue_time}) {
            apply_wait($waits[$next_wait++], \%pending, \%arrived, \%closed);
        }
        my @matching = sort { $a->{order} <=> $b->{order} }
            grep { defined($issue->{test_id}) && ($_->{test_id} // '') eq $issue->{test_id} } values %pending;
        my $available = $held_available && !$logger_unavailable && !$legacy_count && !$malformed_waits
            && defined($issue->{test_id}) && defined($issue->{issue_time}) && defined($issue->{parameterized});
        $issue->{waits} = \@matching;
        $issue->{wait_status} = !$available ? 'unavailable' : @matching ? 'outstanding' : 'none';
        $issue->{attribution} = !defined($issue->{parameterized}) ? 'unknown_parameterization'
            : $issue->{parameterized} ? 'parameterized_test_and_time' : 'exact_test_and_time';
        my $label = !defined($issue->{parameterized}) ? 'parameterization unavailable: test-wide waits' : $issue->{parameterized} ? ($issue->{running_parameterized_cases}
            ? "parameterized: one of these $issue->{running_parameterized_cases} cases' waits"
            : 'parameterized: case count unavailable, test-wide waits') : 'exact test and time';
        $issue->{attribution_label} = $label;
        push @reports, "[$prefix] lane-report issue_wait_annotation " . decode('UTF-8', $json->encode($issue));
    }
    # The runner's hang snapshot uses all complete records, including legacy
    # records. Legacy rows may be paired by their payload, but cannot be joined
    # to issue time/identity and never justify wait_status=none for an issue.
    my (%all_pending, %all_arrived, %all_closed, @pending_reports);
    for my $row (@legacy) { apply_wait($row, \%all_pending, \%all_arrived, \%all_closed) }
    for my $wait (sort { $a->{order} <=> $b->{order} } values %all_pending) {
        if ($wait->{kind} eq 'held_step') {
            push @pending_reports, "[$prefix] lane-report held_step_unarrived name=$wait->{name} id=$wait->{id} test=" . ($wait->{site} // '');
        } else {
            push @pending_reports, "[$prefix] lane-report fact_expected id=$wait->{id} expected=$wait->{name} scope="
                . ($wait->{scope} // '') . ' test=' . ($wait->{test_site} // '') . ' site=' . ($wait->{site} // '');
        }
    }
    push @pending_reports, "[$prefix] lane-report held_step_log_unavailable" if $logger_unavailable;
    my $record = {
        announced_tests => $events_available && !$unclassified_tests ? $announced : undef,
        ended_tests => $events_available && !$unclassified_tests ? $ended : undef,
        started_parameterized_cases => $events_available ? $case_started : undef,
        ended_parameterized_cases => $events_available ? $case_ended : undef,
        event_coverage => !$events_available ? 'unavailable' : $invalid_events || $unclassified_tests ? 'partial' : 'v0_parameterized_case_subset',
        event_snapshot => $snapshot, issue_annotations => \@issues,
        invalid_event_records => $invalid_events, untimestamped_wait_records => $legacy_count + $malformed_waits,
    };
    save_json("$stem.invocation.json", $record);
    write_lines("$stem.pending-waits.txt", \@pending_reports);
    print encode_utf8($_), "\n" for @reports;
} elsif ($mode eq 'resources') {
    my ($stem, $child, $dispatch, $complete, $timed_out) = @ARGV;
    my $record = load_json("$stem.invocation.json");
    my ($wall, $user, $sys, $rss, $enabled);
    if (open my $mode_file, '<', "$stem.resource-mode") { $enabled = <$mode_file> =~ /bsd_time/; close $mode_file }
    if (open my $stats, '<', "$stem.resources.txt") {
        while (<$stats>) {
            $wall = 0 + $1 if /^real\s+(\d+(?:\.\d+)?)\s*$/;
            $user = 0 + $1 if /^user\s+(\d+(?:\.\d+)?)\s*$/;
            $sys = 0 + $1 if /^sys\s+(\d+(?:\.\d+)?)\s*$/;
            $rss = 0 + $1 if /^\s*(\d+)\s+maximum resident set size\s*$/;
        }
        close $stats;
    }
    my $wall_source = defined($wall) ? 'bsd_time' : 'wrapper_window';
    if (!defined $wall) {
        my ($start, $exit);
        if (open my $timing, '<', $child) { ($start, $exit) = split /\s+/, <$timing> // ''; close $timing }
        if (numeric($start) && numeric($exit) && $exit >= $start) { $wall = ($exit - $start) / 1000; $wall_source = 'command_pipeline_window' }
        elsif (numeric($dispatch) && numeric($complete) && $complete >= $dispatch) { $wall = ($complete - $dispatch) / 1000 }
    }
    @$record{qw(wall_seconds wall_coverage user_cpu_seconds sys_cpu_seconds max_rss_bytes resource_source resource_coverage)} =
        ($wall, $wall_source, $user, $sys, $rss, $enabled ? 'bsd_time' : undef,
         defined($user) && defined($sys) && defined($rss) ? 'command_pipeline_reaped_tree'
            : $enabled && $timed_out eq '1' ? 'unavailable_after_reap' : 'unavailable');
    save_json("$stem.invocation.json", $record);
} elsif ($mode eq 'attach') {
    my ($stem, $sidecar) = @ARGV;
    my $base = load_json($sidecar);
    die 'missing base timing receipt' unless %$base;
    my $extra = load_json("$stem.invocation.json");
    $base->{$_} = $extra->{$_} for keys %$extra;
    save_json($sidecar, $base);
    if (my $list = $ENV{SWIFT_TEST_F2_SIDECAR_LIST}) {
        if (sysopen my $append, $list, O_WRONLY | O_CREAT | O_APPEND, 0600) {
            # Snapshot a compact row before evidence retention or fixture cleanup
            # removes its sidecar. One append write keeps concurrent workers safe.
            my %row = map { $_ => $base->{$_} } qw(label wall_seconds user_cpu_seconds sys_cpu_seconds
                max_rss_bytes announced_tests ended_tests started_parameterized_cases ended_parameterized_cases
                resource_source resource_coverage);
            syswrite($append, $json->encode(\%row) . "\n");
            close $append;
        }
    }
} elsif ($mode eq 'table') {
    my ($list) = @ARGV;
    open my $input, '<:raw', $list or exit 0;
    my @records;
    while (my $line = <$input>) {
        next unless $line =~ /\n\z/;
        my $record = eval { $json->decode($line) };
        push @records, $record if ref($record) eq 'HASH';
    }
    close $input;
    exit 0 unless @records;
    print "[$prefix] lane-report invocation_resources columns=label|wall_s|user_s|sys_s|max_rss_bytes|announce|test_end|param_start|param_end|source|coverage\n";
    for my $record (sort { ($a->{label} // '') cmp ($b->{label} // '') } @records) {
        my @values = map { defined($record->{$_}) ? $record->{$_} : 'unavailable' }
            qw(label wall_seconds user_cpu_seconds sys_cpu_seconds max_rss_bytes announced_tests ended_tests started_parameterized_cases ended_parameterized_cases resource_source resource_coverage);
        s/[\r\n|]/ /g for @values;
        print "[$prefix] lane-report invocation_resource_row ", join('|', @values), "\n";
    }
} else { die 'unknown receipt operation' }
