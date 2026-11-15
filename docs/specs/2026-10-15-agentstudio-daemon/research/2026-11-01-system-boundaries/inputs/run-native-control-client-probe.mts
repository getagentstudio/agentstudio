import { appendFileSync, closeSync, constants, openSync, readFileSync, writeSync } from "node:fs";
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { z } from "../../../BridgeWeb/node_modules/zod/index.js";

const sessionReferenceSchema = z.object({
  endpoint: z.object({ serviceId: z.string().min(1), endpointId: z.literal("codex-local") }),
  sessionId: z.string().min(1),
});
const configurationSchema = z.object({
  fixtureDirectory: z.string().startsWith("/private/tmp/2026-11-continuity-fixture-"),
  caller: sessionReferenceSchema,
  target: sessionReferenceSchema,
});
const commandSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("start-client") }),
  z.object({ kind: z.literal("drop-client") }),
  z.object({ kind: z.literal("release-gate") }),
  z.object({ kind: z.literal("finish") }),
]);
type ProbeCommand = z.infer<typeof commandSchema>;
type GateState =
  | { readonly kind: "held"; readonly descriptor: number }
  | { readonly kind: "released" };

const artifactDirectory = resolve("tmp/practices-research/2026-11-01-system-boundaries");
const configuration = configurationSchema.parse(
  JSON.parse(readFileSync(resolve(artifactDirectory, "continuity-probe-preflight.json"), "utf8")),
);
const gatePath = resolve(configuration.fixtureDirectory, "release.fifo");
const promptPath = resolve(artifactDirectory, "continuity-probe-gate-prompt.txt");
const evidencePath = resolve(artifactDirectory, "continuity-probe-events.jsonl");
const marker = `CONTINUITY_GATE_${randomBytes(12).toString("hex")}`;

function recordEvent(event: Readonly<Record<string, unknown>>): void {
  const serialized = JSON.stringify({ observedAt: new Date().toISOString(), ...event });
  appendFileSync(evidencePath, `${serialized}\n`, { mode: 0o600 });
  process.stdout.write(`${serialized}\n`);
}

const created = spawnSync("/usr/bin/mkfifo", ["-m", "600", gatePath], { encoding: "utf8" });
if (created.status !== 0) {
  recordEvent({ kind: "fixture-setup-failed", exitCode: created.status, stderr: created.stderr });
  process.exit(1);
}
let gate: GateState = {
  kind: "held",
  descriptor: openSync(gatePath, constants.O_RDWR | constants.O_NONBLOCK),
};
let controlClient: ChildProcessWithoutNullStreams | undefined;
let controlClientExited = false;
let started = false;
let finishing = false;
const input = createInterface({ input: process.stdin, terminal: false });

function releaseGate(aborted: boolean): void {
  if (gate.kind === "released") {
    recordEvent({ kind: "gate-already-released" });
    return;
  }
  const payload = aborted ? `ABORTED_${marker}` : marker;
  writeSync(gate.descriptor, `${payload}\n`);
  closeSync(gate.descriptor);
  gate = { kind: "released" };
  recordEvent({ kind: "gate-released", aborted, payload });
}

function finishProbe(aborted: boolean): void {
  if (finishing) return;
  finishing = true;
  if (gate.kind === "held") releaseGate(true);
  if (controlClient && !controlClientExited) controlClient.kill("SIGKILL");
  clearTimeout(hangGuard);
  input.close();
  process.stdin.pause();
  recordEvent({ kind: "driver-finished", aborted });
}

function startClient(): void {
  if (started) {
    recordEvent({ kind: "refused-duplicate-client-launch" });
    return;
  }
  started = true;
  controlClient = spawn(
    "agent-collaboration",
    [
      "conversation",
      "prompt",
      "--to",
      JSON.stringify(configuration.target),
      "--from",
      JSON.stringify(configuration.caller),
      "--approver",
      JSON.stringify(configuration.caller),
      "--cwd",
      configuration.fixtureDirectory,
      "--text-file",
      promptPath,
      "--timeout-seconds",
      "120",
      "--json",
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  recordEvent({
    kind: "control-client-started",
    pid: controlClient.pid,
    target: configuration.target,
  });
  controlClient.stdout.on("data", (chunk: Buffer): void =>
    recordEvent({ kind: "control-client-stdout", text: chunk.toString("utf8") }),
  );
  controlClient.stderr.on("data", (chunk: Buffer): void =>
    recordEvent({ kind: "control-client-stderr", text: chunk.toString("utf8") }),
  );
  controlClient.on("error", (error: Error): void =>
    recordEvent({ kind: "control-client-error", message: error.message }),
  );
  controlClient.on("exit", (code: number | null, signal: NodeJS.Signals | null): void => {
    controlClientExited = true;
    recordEvent({ kind: "control-client-exited", code, signal });
  });
}

function handleCommand(command: ProbeCommand): void {
  switch (command.kind) {
    case "start-client":
      startClient();
      return;
    case "drop-client":
      if (!controlClient || controlClientExited) {
        recordEvent({ kind: "no-live-client-to-drop" });
        return;
      }
      recordEvent({
        kind: "control-client-kill-requested",
        pid: controlClient.pid,
        signal: "SIGKILL",
      });
      controlClient.kill("SIGKILL");
      return;
    case "release-gate":
      releaseGate(false);
      return;
    case "finish":
      finishProbe(false);
      return;
    default:
      return assertNever(command);
  }
}

function assertNever(value: never): never {
  throw new Error(`Unhandled probe command: ${JSON.stringify(value)}`);
}

// Runner-owned hang guard only; elapsed time never determines a passing verdict.
const hangGuard = setTimeout((): void => {
  recordEvent({ kind: "runner-hang-guard" });
  finishProbe(true);
}, 240_000);
input.on("line", (line: string): void => {
  try {
    handleCommand(commandSchema.parse(JSON.parse(line)));
  } catch (error: unknown) {
    recordEvent({
      kind: "invalid-command",
      message: error instanceof Error ? error.message : String(error),
    });
  }
});
process.on("SIGTERM", (): void => finishProbe(true));
process.on("SIGINT", (): void => finishProbe(true));
recordEvent({ kind: "fixture-ready", gatePath, marker, target: configuration.target });
