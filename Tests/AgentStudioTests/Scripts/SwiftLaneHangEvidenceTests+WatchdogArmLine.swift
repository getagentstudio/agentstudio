import AgentStudioInfrastructure
import Foundation
import Testing

// A hang fixture arms the runner's watchdog with a line in its own output, which
// the runner reads from the output file as a newline-terminated record. These
// fixtures put their own `tee` on PATH for the output copy. It stops at a chosen
// point until the watchdog has sampled the file, so each verdict follows from
// what that sample saw, not from how fast the copy ran.
extension SwiftLaneHangEvidenceTests {
    @Test("output printed before the arm line is in the timeout report, however late the output copy runs")
    func armLineOrdersEvidenceAheadOfTheTimeoutReport() async throws {
        // The child prints its evidence, then the arm line, and parks. The copy
        // to the output file starts only after the watchdog's first sample, so
        // that sample sees an empty file. A watchdog armed by anything but the
        // arm line in the file times out there and reports without the evidence.
        // Armed by the line, it reads a file that holds every line printed first.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-arm-order-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory + "/bin", withIntermediateDirectories: true)
        try await requireRunnerArmLineMatchesFixtures()
        let childPrinted = workDirectory + "/child-printed.fifo"
        let copyRelease = workDirectory + "/copy-release.fifo"
        let neverWritten = workDirectory + "/never-written.fifo"
        try writeArmLineFixtureExecutable(
            """
            #!/bin/bash
            IFS= read -r copy_release <'\(copyRelease)'
            exec /usr/bin/tee "$@"

            """,
            at: workDirectory + "/bin/tee"
        )
        // A wedged test that honours the runner's SIGINT, so the reap needs no grace period.
        try #"""
        $| = 1;
        $SIG{INT} = "DEFAULT";
        my ($printed_path, $never_written_path) = @ARGV;
        print STDERR "[agentstudio-test-log] unavailable path=/missing/events.log errno=2\n";
        print "\#(laneWatchdogArmLine)\n";
        open(my $printed, ">", $printed_path) or die $!;
        print {$printed} "printed\n";
        close($printed) or die $!;
        open(my $never_written, "<", $never_written_path) or die $!;
        <$never_written>;

        """#.write(toFile: workDirectory + "/wedged-test.pl", atomically: true, encoding: .utf8)

        let report = try await laneBashAllowingFailure(
            "mkfifo '\(childPrinted)' '\(copyRelease)' '\(neverWritten)'; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH='\(workDirectory)/build'; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "export PATH='\(workDirectory)/bin':$PATH; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + laneWatchdogFirstSampleHandshake(readyFIFO: childPrinted, releaseFIFO: copyRelease)
                + "run_swift_with_timeout 'arm order probe' 0 /usr/bin/perl '\(workDirectory)/wedged-test.pl' "
                + "'\(childPrinted)' '\(neverWritten)' swiftpm-testing-helper "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\"",
            innerWatchdog: .armedByFixture
        )
        let unavailableRange = try #require(
            report.range(of: "lane-report held_step_log_unavailable"), Comment(rawValue: report))
        let reapRange = try #require(report.range(of: "lane-report timeout_reap="), Comment(rawValue: report))
        #expect(report.contains("RETURNED=124"), Comment(rawValue: report))
        #expect(unavailableRange.lowerBound < reapRange.lowerBound, Comment(rawValue: report))
    }

    @Test("a line that begins with the arm line's bytes does not arm while it is still being written")
    func unterminatedArmLineBytesDoNotArm() async throws {
        // The copy writes the arm line's bytes without their newline, lets the
        // watchdog sample that file, and only then writes the rest of a longer
        // line. Read as a whole line, those bytes would arm the watchdog, which
        // allows no inactivity here and would time the command out at that sample.
        let workDirectory = NSTemporaryDirectory() + "agentstudio-arm-fragment-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory + "/bin", withIntermediateDirectories: true)
        try await requireRunnerArmLineMatchesFixtures()
        let fragmentCopied = workDirectory + "/fragment-copied.fifo"
        let copyRelease = workDirectory + "/copy-release.fifo"
        try writeArmLineFixtureExecutable(
            #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            use IO::Handle;
            open(my $output, ">", shift) or die $!;
            $output->autoflush(1);
            $| = 1;
            my $line = <STDIN>;
            defined($line) or die "no line to copy";
            print $line;
            my $fragment_length = length('\#(laneWatchdogArmLine)');
            print {$output} substr($line, 0, $fragment_length);
            open(my $copied, ">", '\#(fragmentCopied)') or die $!;
            print {$copied} "copied\n";
            close($copied) or die $!;
            open(my $release, "<", '\#(copyRelease)') or die $!;
            <$release>;
            print {$output} substr($line, $fragment_length);
            while (my $rest = <STDIN>) {
              print $rest;
              print {$output} $rest;
            }

            """#,
            at: workDirectory + "/bin/tee"
        )
        try "printf '%s\\n' '\(laneWatchdogArmLine) and the rest of a longer line'\n"
            .write(toFile: workDirectory + "/longer-line.sh", atomically: true, encoding: .utf8)

        let report = try await laneBashAllowingFailure(
            "mkfifo '\(fragmentCopied)' '\(copyRelease)'; "
                + "LOG_PREFIX=lane; TIMEOUT_SECONDS=0; BUILD_PATH='\(workDirectory)/build'; "
                + "export LANE_EVENT_STREAM_DIR='\(workDirectory)/ci-runs'; "
                + "export PATH='\(workDirectory)/bin':$PATH; "
                + "source scripts/swift-test-helpers.sh; set +e; "
                + laneWatchdogFirstSampleHandshake(readyFIFO: fragmentCopied, releaseFIFO: copyRelease)
                + "run_swift_with_timeout 'arm fragment probe' 0 /bin/bash '\(workDirectory)/longer-line.sh' "
                + "|| returned=$?; echo \"RETURNED=${returned:-0}\"",
            innerWatchdog: .armedByFixture
        )
        #expect(report.contains("RETURNED=0"), Comment(rawValue: report))
        #expect(!report.contains("ERROR: no output progress"), Comment(rawValue: report))
        #expect(!report.contains("timeout_reap="), Comment(rawValue: report))
    }
}

/// Fails the test, rather than leaving its fixture unarmed until the outer hang
/// bound, when the runner's arm line has drifted from the one fixtures print.
@discardableResult
private func requireRunnerArmLineMatchesFixtures() async throws -> String {
    let runnerArmLine = try await laneBash(
        "source scripts/swift-test-helpers.sh; printf '%s' \"$SWIFT_TEST_WATCHDOG_ARM_LINE\"")
    try #require(runnerArmLine == laneWatchdogArmLine)
    return runnerArmLine
}

/// Shell, sourced after the lane helpers, that turns the watchdog's first two
/// sleeps into a handshake. The runner sleeps before each sample of the output
/// file. Its first sleep returns once `readyFIFO` is written, so the first
/// sample sees what the fixture prepared. Its second sleep follows that sample:
/// after its arm check, or after the timeout report it led to has read the
/// output file. That sleep writes `releaseFIFO`. Later sleeps are the runner's own.
private func laneWatchdogFirstSampleHandshake(readyFIFO: String, releaseFIFO: String) -> String {
    #"""
    lane_watchdog_sleep_count=0
    sleep() {
      lane_watchdog_sleep_count=$((lane_watchdog_sleep_count + 1))
      case "$lane_watchdog_sleep_count" in
        1) IFS= read -r lane_watchdog_ready <'\#(readyFIFO)' ;;
        2) printf 'release\n' >'\#(releaseFIFO)' ;;
        *) /bin/sleep "$@" ;;
      esac
    }

    """#
}

private func writeArmLineFixtureExecutable(_ source: String, at path: String) throws {
    try source.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}
