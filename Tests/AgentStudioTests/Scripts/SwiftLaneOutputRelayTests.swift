import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

private let concurrentChildStreamsLineRelayFixture = #"""
    set -euo pipefail
    source scripts/swift-test-helpers.sh
    LOG_PREFIX=writer-probe
    TIMEOUT_SECONDS=60
    fixture_directory='__FIXTURE_DIRECTORY__'
    BUILD_PATH="$fixture_directory/build"
    LANE_EVENT_STREAM_DIR="$fixture_directory/events"
    SWIFT_TEST_OUTPUT_RELAY_START_DIRECTORY="$fixture_directory/relay-starts"
    _XCB_BYPASS=1
    export BUILD_PATH LANE_EVENT_STREAM_DIR SWIFT_TEST_OUTPUT_RELAY_START_DIRECTORY _XCB_BYPASS
    mkdir -p "$BUILD_PATH" "$LANE_EVENT_STREAM_DIR" "$SWIFT_TEST_OUTPUT_RELAY_START_DIRECTORY"
    a_paused_fifo="$BUILD_PATH/a-paused"
    a_release_fifo="$BUILD_PATH/a-release"
    mkfifo "$a_paused_fifo" "$a_release_fifo"
    SWIFT_TEST_A_PAUSED_FIFO="$a_paused_fifo"
    SWIFT_TEST_A_RELEASE_FIFO="$a_release_fifo"
    export SWIFT_TEST_A_PAUSED_FIFO SWIFT_TEST_A_RELEASE_FIFO
    mkdir -p "$fixture_directory/bin"
    # The writer stub delegates filtering to /usr/bin/awk and reproduces
    # its chunked writes only at the shared stdout boundary.
    cat >"$fixture_directory/bin/awk" <<'AWK_WRITER_STUB'
    #!/bin/sh
    if [ "${LANE_WRITER_KIND:-}" != "A" ]; then
      exec /usr/bin/awk "$@"
    fi
    /usr/bin/awk "$@" | /usr/bin/perl -e '
      use strict;
      use warnings;
      binmode STDIN;
      binmode STDOUT;
      local $/;
      my $filtered_output = <STDIN>;
      die "real filter emitted no bytes\n" unless defined $filtered_output;
      my $first_newline = index($filtered_output, "\n");
      die "real filter emitted no complete line\n" if $first_newline < 0;
      my $first_line = substr($filtered_output, 0, $first_newline + 1, "");
      sub write_all {
        my ($bytes) = @_;
        while (length $bytes) {
          my $chunk = substr($bytes, 0, 4096, "");
          while (length $chunk) {
            my $count = syswrite(STDOUT, $chunk);
            die "writer stub failed: $!\n" unless defined $count;
            substr($chunk, 0, $count, "");
          }
        }
      }
      my $first_chunk = substr($first_line, 0, 4096, "");
      die "first filtered line is too short\n" unless length($first_chunk) == 4096;
      write_all($first_chunk);
      open my $paused, ">", $ENV{SWIFT_TEST_A_PAUSED_FIFO} or die $!;
      print {$paused} "A_PAUSED\n";
      close $paused;
      open my $release, "<", $ENV{SWIFT_TEST_A_RELEASE_FIFO} or die $!;
      <$release>;
      close $release;
      write_all($first_line);
      write_all($filtered_output);
    '
    AWK_WRITER_STUB
    chmod +x "$fixture_directory/bin/awk"
    PATH="$fixture_directory/bin:$PATH"
    export PATH

    LANE_WRITER_KIND=A run_swift_with_timeout 'writer A' 60 /usr/bin/perl -e \
      'my $glyph = "\xE2\x82\xAC"; for (1..128) { print "WRITER_A_START", ($glyph x 2048), ":WRITER_A_END\n"; }' build &
    writer_a_pid=$!
    IFS= read -r paused_state <"$a_paused_fifo"
    [ "$paused_state" = A_PAUSED ]

    LANE_WRITER_KIND=B run_swift_with_timeout 'writer B' 60 /usr/bin/perl -e \
      'my $glyph = "\xE2\x82\xAC"; print "WRITER_B_START", $glyph, ":WRITER_B_END\n";' build

    printf 'release A\n' >"$a_release_fifo"
    wait "$writer_a_pid"
    printf 'WRITER_TEST_COMPLETE\n'
    """#

struct SwiftLaneOutputRelayTests {
    @Test("concurrent child streams keep long multibyte output lines intact")
    func concurrentChildStreamsKeepMultibyteLinesIntact() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-concurrent-lane-output-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }
        let command = concurrentChildStreamsLineRelayFixture.replacingOccurrences(
            of: "__FIXTURE_DIRECTORY__",
            with: fixtureDirectory
        )

        // Mise consumes the lane through a pipe. A regular-file capture shares
        // one file offset across forked writers and can hide pipe interleaving.
        let (exitCode, outputData) = try await withoutBlockingCooperativePool {
            let outputPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, outputData)
        }
        let output = String(data: outputData, encoding: .utf8)
        #expect(exitCode == 0)
        #expect(output != nil)
        guard let output else { return }

        let outputLines = output.split(separator: "\n")
        let writerALines = outputLines.filter {
            $0.hasPrefix("WRITER_A_START") && $0.hasSuffix(":WRITER_A_END")
        }
        let writerBLines = outputLines.filter {
            $0.hasPrefix("WRITER_B_START") && $0.hasSuffix(":WRITER_B_END")
        }
        #expect(writerALines.count == 128)
        #expect(writerBLines.count == 1)
        #expect(writerALines.allSatisfy { $0.filter { $0 == "€" }.count == 2048 })
        #expect(writerBLines.first?.filter { $0 == "€" }.count == 1)
        #expect(output.contains("WRITER_TEST_COMPLETE"))

        let relayStarts = try FileManager.default.contentsOfDirectory(
            atPath: fixtureDirectory + "/relay-starts"
        )
        #expect(relayStarts.filter { $0.hasPrefix("command-") }.count == 2)
        #expect(relayStarts.filter { $0.hasPrefix("stream-") }.count == 2)
    }

    @Test("output relay uses a TMPDIR lock when BUILD_PATH is unset")
    func outputRelayUsesTMPDIRLockWhenBuildPathIsUnset() async throws {
        let fixtureDirectory = NSTemporaryDirectory() + "agentstudio-output-relay-fallback-\(UUIDv7.generate())"
        defer { try? FileManager.default.removeItem(atPath: fixtureDirectory) }

        let command = #"""
            set -euo pipefail
            source scripts/swift-test-helpers.sh
            LOG_PREFIX=fallback-probe
            TMPDIR='\#(fixtureDirectory)/tmp'
            LANE_EVENT_STREAM_DIR='\#(fixtureDirectory)/events'
            _XCB_BYPASS=1
            unset BUILD_PATH
            unset SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH SWIFT_TEST_OUTPUT_RELAY_SCRIPT_PATH
            export LOG_PREFIX TMPDIR LANE_EVENT_STREAM_DIR _XCB_BYPASS
            mkdir -p "$TMPDIR" "$LANE_EVENT_STREAM_DIR"
            swift_test_output_relay_begin_command
            printf 'FALLBACK_RELAY_OK\n'
            swift_test_output_relay_finish_command

            case "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH" in
              "$TMPDIR"/agentstudio-swift-test-output-*/.swift-test-output.lock)
                printf 'FALLBACK_LOCK_PATH=%s\n' "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH"
                ;;
              *)
                printf 'unexpected output lock path: %s\n' "$SWIFT_TEST_OUTPUT_RELAY_LOCK_PATH" >&2
                exit 43
                ;;
            esac
            """#

        let result = try await runLaneScriptBash(command)
        #expect(result.exitCode == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("BUILD_PATH unset; output relay lock uses TMPDIR fallback"))
        #expect(result.output.contains("FALLBACK_RELAY_OK"))
        #expect(
            result.output.contains(
                "FALLBACK_LOCK_PATH=\(fixtureDirectory)/tmp/agentstudio-swift-test-output-"
            )
        )
    }
}
