import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Swift lane helper cancellation")
struct SwiftLaneHelperCancellationTests {
    @Test("SIGINT cancellation reaps a helper in its own process group without process listing")
    func sigintCancellationReapsSeparateHelperGroup() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-helper-cancel-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)

        let fakeToolDirectory = workDirectory + "/bin"
        try FileManager.default.createDirectory(atPath: fakeToolDirectory, withIntermediateDirectories: true)
        try writeDeniedProcessListingTool(named: "ps", into: fakeToolDirectory)
        try writeDeniedProcessListingTool(named: "pgrep", into: fakeToolDirectory)

        let eventDirectory = workDirectory + "/events"
        let releasePath = workDirectory + "/helper.release"
        let watchdogArmPath = workDirectory + "/watchdog.arm"
        let helperPIDPath = workDirectory + "/helper.pid"
        let parentReapedPath = workDirectory + "/parent-reaped"
        let helperFixturePath = workDirectory + "/helper-fixture.pl"
        try helperFixtureSource.write(toFile: helperFixturePath, atomically: true, encoding: .utf8)

        let shellCommand = """
            chmod +x '\(fakeToolDirectory)/ps' '\(fakeToolDirectory)/pgrep'
            mkfifo '\(releasePath)'
            exec 8<>'\(releasePath)'
            PATH='\(fakeToolDirectory)':"$PATH"
            export PATH
            LOG_PREFIX=helper-cancel
            TIMEOUT_SECONDS=2
            BUILD_PATH=.build-agent-1
            LANE_WATCHDOG_ARM_PATH='\(watchdogArmPath)'
            LANE_EVENT_STREAM_DIR='\(eventDirectory)'
            export LANE_WATCHDOG_ARM_PATH LANE_EVENT_STREAM_DIR
            source scripts/swift-test-helpers.sh
            set +e
            run_swift_with_timeout 'separate helper probe' 2 /usr/bin/perl '\(helperFixturePath)' \
              '\(helperPIDPath)' '\(watchdogArmPath)' '\(releasePath)' '\(parentReapedPath)' || runner_status=$?
            echo "RUNNER_STATUS=${runner_status:-0}"
            if [ -f '\(parentReapedPath)' ]; then echo PARENT_REAPED_HELPER=yes; else echo PARENT_REAPED_HELPER=no; fi
            helper_pid=0
            helper_pgid=0
            read -r helper_pid helper_pgid <'\(helperPIDPath)' || true
            echo "HELPER_PID=$helper_pid HELPER_PGID=$helper_pgid"
            if [ "$helper_pid" -gt 0 ] && [ "$helper_pid" -eq "$helper_pgid" ]; then
              echo HELPER_GROUP_LEADER=yes
            else
              echo HELPER_GROUP_LEADER=no
            fi
            if [ "$helper_pgid" -gt 0 ] && \
              /usr/bin/perl -e 'use Errno qw(ESRCH); my $pgid = shift; exit 0 if kill 0, -$pgid; exit($! == ESRCH ? 1 : 0);' "$helper_pgid"
            then
              echo HELPER_GROUP_ALIVE=yes
              kill -KILL -- "-$helper_pgid" 2>/dev/null || true
            else
              echo HELPER_GROUP_ALIVE=no
            fi
            """
        let result = try await runLaneScriptBash(shellCommand)
        let laneOutput = result.output

        let helperPIDReceipt =
            laneOutput
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("HELPER_PID=") })
        if let helperPIDReceipt {
            print(helperPIDReceipt)
        }

        #expect(laneOutput.contains("HELPER_READY"), Comment(rawValue: laneOutput))
        #expect(
            laneOutput.contains("HELPER_PID=") && laneOutput.contains("HELPER_PGID="), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("HELPER_GROUP_LEADER=yes"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("process listing unavailable in this environment; reaping by process group"))
        #expect(laneOutput.contains("PARENT_REAPED_HELPER=yes"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("HELPER_GROUP_ALIVE=no"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("timeout_reap=sigint_cancelled"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("RUNNER_STATUS=124"), Comment(rawValue: laneOutput))
    }

    @Test("a command that ignores SIGINT still reaches TERM and KILL escalation")
    func ignoredINTStillEscalatesToKill() async throws {
        let workDirectory = NSTemporaryDirectory() + "agentstudio-helper-cancel-escalation-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: workDirectory) }
        try FileManager.default.createDirectory(atPath: workDirectory, withIntermediateDirectories: true)

        let fakeToolDirectory = workDirectory + "/bin"
        try FileManager.default.createDirectory(atPath: fakeToolDirectory, withIntermediateDirectories: true)
        try writeDeniedProcessListingTool(named: "ps", into: fakeToolDirectory)
        try writeDeniedProcessListingTool(named: "pgrep", into: fakeToolDirectory)

        let eventDirectory = workDirectory + "/events"
        let releasePath = workDirectory + "/command.release"
        let watchdogArmPath = workDirectory + "/watchdog.arm"
        let commandPIDPath = workDirectory + "/command.pid"
        let commandFixturePath = workDirectory + "/command-fixture.pl"
        let commandFixture = #"""
            use strict;
            use warnings;
            $| = 1;
            my ($pid_path, $arm_path, $release_path) = @ARGV;
            $SIG{INT} = "IGNORE";
            $SIG{TERM} = "IGNORE";
            open(my $pid_file, ">", $pid_path) or die $!;
            print {$pid_file} "$$\n";
            close($pid_file) or die $!;
            open(my $arm, ">", $arm_path) or die $!;
            close($arm) or die $!;
            print "IGNORING_INT_AND_TERM\n";
            open(my $release, "<", $release_path) or die $!;
            <$release>;
            """#
        try commandFixture.write(toFile: commandFixturePath, atomically: true, encoding: .utf8)

        let shellCommand = """
            chmod +x '\(fakeToolDirectory)/ps' '\(fakeToolDirectory)/pgrep'
            mkfifo '\(releasePath)'
            exec 8<>'\(releasePath)'
            PATH='\(fakeToolDirectory)':"$PATH"
            export PATH
            LOG_PREFIX=helper-cancel-escalation
            TIMEOUT_SECONDS=2
            BUILD_PATH=.build-agent-1
            LANE_WATCHDOG_ARM_PATH='\(watchdogArmPath)'
            LANE_EVENT_STREAM_DIR='\(eventDirectory)'
            export LANE_WATCHDOG_ARM_PATH LANE_EVENT_STREAM_DIR
            source scripts/swift-test-helpers.sh
            set +e
            run_swift_with_timeout 'ignored signal probe' 2 /usr/bin/perl '\(commandFixturePath)' \
              '\(commandPIDPath)' '\(watchdogArmPath)' '\(releasePath)' || runner_status=$?
            echo "RUNNER_STATUS=${runner_status:-0}"
            command_pid=$(cat '\(commandPIDPath)' 2>/dev/null || echo 0)
            echo "COMMAND_PID=$command_pid"
            if [ "$command_pid" -gt 0 ] && \
              /usr/bin/perl -e 'use Errno qw(ESRCH); my $pid = shift; exit 0 if kill 0, $pid; exit($! == ESRCH ? 1 : 0);' "$command_pid"
            then
              echo COMMAND_ALIVE=yes
              kill -KILL "$command_pid" 2>/dev/null || true
            else
              echo COMMAND_ALIVE=no
            fi
            """
        let result = try await runLaneScriptBash(shellCommand)
        let laneOutput = result.output

        let commandPIDReceipt =
            laneOutput
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("COMMAND_PID=") })
        if let commandPIDReceipt {
            print(commandPIDReceipt)
        }

        #expect(laneOutput.contains("IGNORING_INT_AND_TERM"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("COMMAND_ALIVE=no"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("timeout_reap=killed"), Comment(rawValue: laneOutput))
        #expect(laneOutput.contains("RUNNER_STATUS=124"), Comment(rawValue: laneOutput))
    }

    private func writeDeniedProcessListingTool(named toolName: String, into directoryPath: String) throws {
        let toolPath = directoryPath + "/" + toolName
        try "#!/bin/sh\nexit 3\n".write(toFile: toolPath, atomically: true, encoding: .utf8)
    }

    private var helperFixtureSource: String {
        #"""
        use strict;
        use warnings;
        $| = 1;
        my ($pid_path, $arm_path, $release_path, $reaped_path) = @ARGV;
        pipe(my $ready_reader, my $ready_writer) or die $!;
        my $helper_pid = fork();
        defined $helper_pid or die $!;
        if ($helper_pid == 0) {
          close $ready_reader;
          setpgrp(0, 0) or die $!;
          $SIG{INT} = "DEFAULT";
          $SIG{TERM} = "IGNORE";
          my $helper_pgid = getpgrp(0);
          open(my $pid_file, ">", $pid_path) or die $!;
          print {$pid_file} "$$ $helper_pgid\n";
          close($pid_file) or die $!;
          print {$ready_writer} "READY\n";
          close($ready_writer) or die $!;
          open(my $release, "<", $release_path) or die $!;
          <$release>;
          exit 0;
        }
        close $ready_writer;
        defined <$ready_reader> or die "helper did not become ready";
        close $ready_reader;
        $SIG{TERM} = "IGNORE";
        $SIG{INT} = sub {
          kill "INT", -$helper_pid;
          waitpid($helper_pid, 0);
          open(my $reaped, ">", $reaped_path) or die $!;
          print {$reaped} "REAPED\n";
          close($reaped) or die $!;
          exit 0;
        };
        open(my $arm, ">", $arm_path) or die $!;
        close($arm) or die $!;
        print "HELPER_READY\n";
        open(my $release, "<", $release_path) or die $!;
        <$release>;
        waitpid($helper_pid, 0);
        """#
    }
}
