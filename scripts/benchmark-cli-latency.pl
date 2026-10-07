#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use CLILatencyReport;
use JSON::PP;
use Digest::SHA;
use File::Temp qw(tempfile);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw(strftime _exit);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Errno qw(EINTR);

my $json = JSON::PP->new->utf8->canonical;
my $root = abs_path("$FindBin::Bin/..");
my $fixture_path = shift @ARGV;
die "Exactly one fixture-file argument is required\n" unless defined $fixture_path && !@ARGV;

sub read_json {
    my ($path) = @_;
    open my $input, '<:raw', $path or die "Cannot read required input\n";
    local $/;
    my $value = eval { $json->decode(<$input>) };
    die "Invalid JSON input\n" if $@ || ref($value) ne 'HASH';
    return $value;
}
sub private_file {
    my ($path, $outside_repository) = @_;
    my @info = lstat($path);
    die "Fixture must be a regular owner-only mode 0600 file\n"
        unless @info && -f _ && !-l _ && ($info[2] & 07777) == 0600 && $info[4] == $<;
    my $absolute = abs_path($path);
    die "Fixture must be outside the repository\n" if $outside_repository && index($absolute, "$root/") == 0;
}
sub nonempty { defined $_[0] && !ref($_[0]) && length($_[0]) > 0 }
sub uuid_string { nonempty($_[0]) && $_[0] =~ /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i }
sub file_hash {
    my ($path) = @_;
    open my $input, '<:raw', $path or die "Cannot read CLI artifact\n";
    return Digest::SHA->new(256)->addfile($input)->hexdigest;
}
sub emit_json {
    my ($path, $value) = @_;
    open my $output, '>:raw', $path or die "Cannot save benchmark report\n";
    print {$output} $json->encode($value), "\n";
    close $output or die "Cannot close benchmark report\n";
}

# Anonymous owner-only files avoid pipe backpressure on discovery output. They
# are unlinked before spawn; neither request payloads nor responses become logs.
sub run_process {
    my ($executable, $arguments, $input, $environment) = @_;
    my ($stdin_file, $stdin_path) = tempfile(UNLINK => 1);
    my ($stdout_file, $stdout_path) = tempfile(UNLINK => 1);
    my ($stderr_file, $stderr_path) = tempfile(UNLINK => 1);
    unlink $stdin_path, $stdout_path, $stderr_path;
    binmode $_ for ($stdin_file, $stdout_file, $stderr_file);
    print {$stdin_file} $input;
    seek($stdin_file, 0, 0) or die "Cannot rewind process input\n";
    $stdin_file->flush;
    my $start = clock_gettime(CLOCK_MONOTONIC);
    my $child = fork();
    die "Cannot spawn benchmark child\n" unless defined $child;
    if (!$child) {
        open STDIN, '<&', $stdin_file or _exit(126);
        open STDOUT, '>&', $stdout_file or _exit(126);
        open STDERR, '>&', $stderr_file or _exit(126);
        %ENV = %$environment;
        exec {$executable} $executable, @$arguments or _exit(127);
    }
    local $SIG{INT} = local $SIG{TERM} = sub {
        kill 'TERM', $child;
        waitpid($child, 0);
        die "Benchmark interrupted\n";
    };
    my $waited;
    do { $waited = waitpid($child, 0) } while $waited < 0 && $! == EINTR;
    my $status = $?;
    my $duration = (clock_gettime(CLOCK_MONOTONIC) - $start) * 1000;
    die "Cannot join benchmark child\n" if $waited != $child;
    seek($_, 0, 0) or die "Cannot rewind process output\n" for ($stdout_file, $stderr_file);
    local $/;
    my $stdout = <$stdout_file> // '';
    my $stderr = <$stderr_file> // '';
    return {
        duration => $duration, exitCode => $status >> 8, signal => $status & 127,
        stdout => $stdout, stderr => $stderr, stderrPresent => length($stderr) ? JSON::PP::true : JSON::PP::false,
    };
}

private_file($fixture_path, 1);
my $fixture = read_json($fixture_path);
die "Fixture needs canonical pane and window UUIDs\n"
    unless uuid_string($fixture->{paneId}) && uuid_string($fixture->{workspaceWindowId});
my $pane_environment = $fixture->{environment};
die "Fixture needs its real pane environment\n" unless ref($pane_environment) eq 'HASH';
for my $key (qw(AGENTSTUDIO_CLI AGENTSTUDIO_PANE_TOKEN AGENTSTUDIO_IPC_SOCKET AGENTSTUDIO_CLI_STORE)) {
    die "Fixture is missing required pane environment\n" unless nonempty($pane_environment->{$key});
}
die "Fixture store must be from the debug channel\n"
    unless ($pane_environment->{AGENTSTUDIO_CLI_STORE_CHANNEL} // '') eq 'debug';
my $cli = abs_path($pane_environment->{AGENTSTUDIO_CLI});
die "CLI artifact is not executable\n" unless defined $cli && -f $cli && -x $cli;
die "Fixture needs the debug escrow path\n" unless nonempty($fixture->{debugEscrowPath});
private_file($fixture->{debugEscrowPath}, 0);
my $escrow = read_json($fixture->{debugEscrowPath});
die "Invalid debug escrow\n" unless uuid_string($escrow->{runtimeId}) && nonempty($escrow->{token})
    && ($escrow->{socketPath} // '') eq $pane_environment->{AGENTSTUDIO_IPC_SOCKET};
my %clean_environment = %ENV;
delete $clean_environment{$_} for grep { /^AGENTSTUDIO_/ } keys %clean_environment;
my %pane_env = (%clean_environment, %$pane_environment);
my %debug_env = %pane_env;
delete @debug_env{qw(AGENTSTUDIO_PANE_TOKEN AGENTSTUDIO_IPC_SOCKET)};
$debug_env{AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW} = $fixture->{debugEscrowPath};

my $manifest_path = $ENV{AGENTSTUDIO_CLI_BENCHMARK_WORKLOADS} // "$FindBin::Bin/cli-latency-workloads.json";
my $manifest = read_json($manifest_path);
die "Unsupported workload manifest\n" unless ($manifest->{version} // 0) == 1
    && ref($manifest->{families}) eq 'ARRAY' && ref($manifest->{notMeasured}) eq 'ARRAY';
my %family_names;
for my $family (@{$manifest->{families}}) {
    die "Invalid workload family\n" unless ref($family) eq 'HASH'
        && ($family->{name} // '') =~ /^[a-z][a-z.]*$/ && !$family_names{$family->{name}}++
        && ref($family->{argv}) eq 'ARRAY' && @{$family->{argv}}
        && !grep { !nonempty($_) } @{$family->{argv}};
    die "Invalid workload policy\n" unless exists $CLILatencyReport::budgets{$family->{budgetClass} // ''}
        && ($family->{fixtureRequirement} // '') =~ /^(ownedPane|debugRuntime)$/;
}
for my $name (qw(hook session terminal pane system command discovery.capabilities discovery.commands)) {
    die "Required method family is not represented\n" unless $family_names{$name};
}
for my $name (@{$manifest->{notMeasured}}) {
    die "Invalid unmeasured family\n" unless nonempty($name) && $name =~ /^[a-z][a-z.]*$/
        && !$family_names{$name};
}
my $conversation = "cli-latency-$$-" . strftime('%Y%m%dT%H%M%SZ', gmtime);
my %substitutions = (
    paneId => $fixture->{paneId}, workspaceWindowId => $fixture->{workspaceWindowId},
    conversationId => $conversation, sampleId => '',
);
sub substitute {
    my ($value) = @_;
    if (ref($value) eq 'HASH') { return {map { $_ => substitute($value->{$_}) } keys %$value} }
    if (ref($value) eq 'ARRAY') { return [map { substitute($_) } @$value] }
    return $value if !defined($value) || ref($value);
    $value =~ s/\$\{([a-zA-Z]+)\}/exists $substitutions{$1} ? $substitutions{$1} : die "Unknown workload placeholder\n"/ge;
    return $value;
}
# Validate every template before taking ownership or executing any mutation.
substitute($_) for @{$manifest->{families}};
my $output_directory = $ENV{AGENTSTUDIO_CLI_BENCHMARK_OUTPUT}
    // "$root/tmp/cli-latency/" . strftime('%Y-%m-%dT%H-%M-%SZ', gmtime) . "-$$";
die "Benchmark output directory already exists\n" if -e $output_directory;
umask 0077;
make_path($output_directory, {mode => 0700});
my $head = run_process('/usr/bin/git', ['-C', $root, 'rev-parse', 'HEAD'], '', \%clean_environment)->{stdout};
chomp $head;
die "Cannot record source HEAD\n" unless $head =~ /^[a-f0-9]{40}$/;
my $load = run_process('/usr/sbin/sysctl', ['-n', 'vm.loadavg'], '', \%clean_environment)->{stdout};
my @load = $load =~ /([0-9]+(?:\.[0-9]+)?)/g;
my $report = {
    metric => 'cli.call_total_ms', sourceHead => $head, cliSHA256 => file_hash($cli),
    workloadSHA256 => file_hash($manifest_path), loadAverageAtStart => [map { 0 + $_ } @load],
    measuredAtUTC => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
    boundary => 'parent CLOCK_MONOTONIC immediately before fork through waitpid exit; includes spawn, loader and teardown overhead',
    startupProxy => '50 fresh-process local-help invocations of the GRDB-linked CLI; includes help work, not causal GRDB-only attribution',
    fixture => 'redacted dedicated disposable pane, handed off exclusively by the Lead',
    verdictScope => 'measured current-branch families only; NOT MEASURED families do not pass',
    launchProvenance => 'Lead must record warm debug launch provenance alongside this report; wire does not advertise channel',
    bindingProof => 'unbound -> harness SessionStart -> UserPromptSubmit -> live/running/reported; query does not echo conversation identity',
    families => [], notMeasured => [map { {family => $_, verdict => 'NOT MEASURED'} } @{$manifest->{notMeasured}}],
    cleanup => 'notStarted', verdict => 'FAIL',
};
open my $samples_file, '>:raw', "$output_directory/samples.jsonl" or die "Cannot save samples\n";
my $owns_pane = 0;
my $stage = 'debugIdentity';
my $failure_context;

sub invoke {
    my ($arguments, $input, $environment) = @_;
    return run_process($cli, $arguments, defined($input) ? $json->encode($input) : '', $environment);
}
sub checked_result {
    my ($arguments, $environment) = @_;
    my $result = invoke($arguments, undef, $environment);
    die "Fixture IPC call failed\n" if $result->{exitCode} || $result->{signal} || $result->{stderrPresent};
    my $value = eval { $json->decode($result->{stdout}) };
    die "Fixture IPC result invalid\n" if $@ || ref($value) ne 'HASH';
    return $value;
}
sub hook {
    my ($event, $sample_id) = @_;
    my $result = invoke(['hook', 'claude', $event], {
        session_id => $conversation, hook_event_name => $event, tool_use_id => $sample_id,
        prompt_id => 'benchmark-turn',
    }, \%pane_env);
    die "Hook warmup was not delivered\n" if $result->{exitCode} || $result->{signal} || $result->{stderrPresent};
}
# Only controlled classes cross into reports; no stderr text, field paths,
# command identifiers, required scopes or payload values are copied out.
sub call_failure_class {
    my ($family_name, $result) = @_;
    return 'processSignal' if $result->{signal};
    if ($result->{exitCode} || $result->{stderrPresent}) {
        my $diagnostic = eval { $json->decode($result->{stderr}) };
        my %known_reasons = (
            invalidArguments => 'argumentsRejected', invalidParams => 'argumentsRejected',
            unauthorized => 'authorizationRejected', missingGrant => 'authorizationRejected',
            notYetAllowed => 'authorizationRejected', refusedForAgent => 'authorizationRejected',
            unauthenticated => 'authenticationRejected', invalidHandle => 'targetRejected',
            unknownCommand => 'unknownCommand', stateUnavailable => 'stateUnavailable',
            unsupportedCommand => 'unsupportedCommand',
        );
        if (!$@ && ref($diagnostic) eq 'HASH' && !ref($diagnostic->{reason})
            && exists $known_reasons{$diagnostic->{reason} // ''}) {
            return $known_reasons{$diagnostic->{reason}};
        }
        return $result->{exitCode} ? 'unclassifiedCLIExit' : 'diagnosticOutput';
    }
    return undef if $family_name eq 'hook' || $family_name eq 'startup';
    my $decoded = eval { $json->decode($result->{stdout}) };
    return 'invalidJSONResult' if $@;
    return 'invalidResultShape' unless ref($decoded) eq 'HASH';
    if ($family_name eq 'command' && ($decoded->{kind} // '') ne 'applied') {
        my %unavailable_reasons = (
            featureUnavailable => 'commandUnavailable.featureUnavailable',
            noApplicableTarget => 'commandUnavailable.noApplicableTarget',
            stateUnavailable => 'commandUnavailable.stateUnavailable',
        );
        return $unavailable_reasons{$decoded->{reason}}
            if ($decoded->{kind} // '') eq 'unavailable' && !ref($decoded->{reason})
            && exists $unavailable_reasons{$decoded->{reason} // ''};
        return 'unexpectedCommandResult';
    }
    return undef;
}

sub measure_family {
    my ($family) = @_;
    my @samples;
    my $environment = $family->{fixtureRequirement} eq 'ownedPane' ? \%pane_env : \%debug_env;
    for my $index (0 .. $CLILatencyReport::sample_count) {
        $substitutions{sampleId} = "benchmark-$$-$family->{name}-$index";
        my $workload = substitute($family);
        my $result = invoke($workload->{argv}, $workload->{stdin}, $environment);
        my $failure_class = call_failure_class($family->{name}, $result);
        my $valid = !defined $failure_class;
        if (!$index && !$valid) {
            $failure_context = {
                phase => 'warmup', reasonClass => $failure_class,
                exitCode => $result->{exitCode}, signal => $result->{signal},
            };
            die "Family warmup failed\n";
        }
        next unless $index; # One untimed warmup; exactly 50 retained samples.
        my $sample = {
            family => $family->{name}, sample => $index, 'cli.call_total_ms' => $result->{duration},
            outcome => $valid ? 'passed' : 'failed', exitCode => $result->{exitCode},
            signal => $result->{signal}, stderrPresent => $result->{stderrPresent},
            failureClass => $failure_class,
        };
        push @samples, $sample;
        print {$samples_file} $json->encode($sample), "\n" or die "Cannot save benchmark sample\n";
    }
    push @{$report->{families}}, CLILatencyReport::summarize_family($family->{name}, $family->{budgetClass}, \@samples);
}

my $completed = eval {
    my $identity = checked_result(['system.identify'], \%debug_env);
    $stage = 'paneAuthentication';
    my $auth = checked_result(['auth.status'], \%pane_env);
    die "Runtime identity or authentication mismatch\n" unless $auth->{authenticated}
        && lc($identity->{runtimeId} // '') eq lc($escrow->{runtimeId})
        && lc($auth->{runtimeId} // '') eq lc($escrow->{runtimeId})
        && ($identity->{accessMode} // '') ne 'unsafeDebug' && ($identity->{accessMode} // '') ne 'off'
        && ($auth->{accessMode} // '') eq ($identity->{accessMode} // '');
    $stage = 'paneIdentity';
    my $snapshot = checked_result(['pane.snapshot', '--handle', 'self'], \%pane_env);
    die "Pane credential does not resolve to fixture pane\n"
        unless lc($snapshot->{pane}{id} // '') eq lc($fixture->{paneId});
    $owns_pane = 1;
    $stage = 'unboundSession';
    my $before = checked_result(['session.query', '--handle', 'self'], \%pane_env);
    die "Disposable fixture already has a session\n" unless ($before->{sourceHealth} // '') eq 'unbound';
    $stage = 'hookBindingWarmup';
    hook('SessionStart', 'warmup-start');
    hook('UserPromptSubmit', 'warmup-turn');
    my $after = checked_result(['session.query', '--handle', 'self'], \%pane_env);
    die "Hook binding/activity warmup not established\n" unless lc($after->{paneId} // '') eq lc($fixture->{paneId})
        && ($after->{sourceHealth} // '') eq 'live' && ($after->{state} // '') eq 'running'
        && ($after->{origin} // '') eq 'reported';
    $stage = 'terminalReady';
    my $terminal = checked_result(['terminal.status', '--handle', 'self'], \%pane_env);
    die "Fixture terminal is not warm and ready\n" unless $terminal->{isReady};
    $stage = 'startup';
    measure_family({name => 'startup', argv => ['help'], budgetClass => 'hookOrNotice', fixtureRequirement => 'debugRuntime'});
    for my $family (@{$manifest->{families}}) {
        $stage = $family->{name};
        measure_family($family);
    }
    1;
};
my $failure = $@;
if ($owns_pane) {
    my $closed = eval { checked_result(['pane.close', '--handle', $fixture->{paneId}], \%debug_env); 1 };
    $report->{cleanup} = $closed ? 'closedOwnedPane' : 'FAIL';
} else {
    $report->{cleanup} = 'notOwnedIdentityCheckFailed';
}
my %measured = map { $_->{family} => 1 } @{$report->{families}};
for my $name ('startup', map { $_->{name} } @{$manifest->{families}}) {
    push @{$report->{families}}, {family => $name, verdict => 'NOT MEASURED'} unless $measured{$name};
}
my $failed_family_count = scalar grep { $_->{verdict} ne 'PASS' } @{$report->{families}};
$report->{verdict} = $completed && $report->{cleanup} eq 'closedOwnedPane'
    && $failed_family_count == 0 ? 'PASS' : 'FAIL';
$report->{failureStage} = $failure ? $stage : undef; # Controlled labels only, never exception values or IO paths.
$report->{failureClass} = $failure ? ($failure_context->{reasonClass} // 'unclassifiedHarnessFailure') : undef;
$report->{failurePhase} = $failure ? ($failure_context->{phase} // 'preflightOrWarmup') : undef;
$report->{failureExitCode} = $failure_context->{exitCode} if $failure_context;
$report->{failureSignal} = $failure_context->{signal} if $failure_context;
close $samples_file or die "Cannot close benchmark samples\n";
emit_json("$output_directory/report.json", $report);
for my $family (@{$report->{families}}, @{$report->{notMeasured}}) {
    printf "%s %s", $family->{family}, $family->{verdict};
    printf " p95=%.3fms budget=%dms calls=%d failed=%d", @$family{qw(p95Ms budgetMs sampleCount failedCalls)}
        if defined $family->{p95Ms};
    print "\n";
}
if ($failure) {
    print "failure stage=$report->{failureStage} phase=$report->{failurePhase} class=$report->{failureClass}\n";
}
print "cleanup=$report->{cleanup}\ncli.call_total_ms boundary: $report->{boundary}\n";
print "startup is a linked-binary local-help proxy; line/title/notify remain NOT MEASURED\n";
exit($report->{verdict} eq 'PASS' ? 0 : 1);
