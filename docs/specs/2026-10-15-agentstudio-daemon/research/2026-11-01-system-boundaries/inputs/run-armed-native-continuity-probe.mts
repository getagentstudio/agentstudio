import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  constants,
  mkdtempSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { z } from "../../../BridgeWeb/node_modules/zod/index.js";

const referenceSchema = z.object({
  endpoint: z.object({ serviceId: z.string(), endpointId: z.literal("codex-local") }),
  sessionId: z.string(),
});
const configurationSchema = z.object({
  fixtureDirectory: z.string().startsWith("/private/tmp/2026-11-continuity-fixture-"),
  caller: referenceSchema,
  target: referenceSchema,
});
const configuration = configurationSchema.parse(
  JSON.parse(
    readFileSync(
      "tmp/practices-research/2026-11-01-system-boundaries/continuity-probe-preflight.json",
      "utf8",
    ),
  ),
);
const generationSchema = z.object({ serviceEpoch: z.string(), generation: z.number().int() });
const frameSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("listenerReady"),
    target: referenceSchema,
    generation: generationSchema.nullable(),
  }),
  z.object({ kind: z.literal("nativeMessage"), target: referenceSchema, message: z.unknown() }),
  z.object({ kind: z.literal("connectionClosed"), reason: z.string() }),
]);
const notificationSchema = z.object({ method: z.string(), params: z.unknown().optional() });
const commandSchema = z.object({
  threadId: z.string(),
  turnId: z.string(),
  item: z.object({
    id: z.string(),
    type: z.literal("commandExecution"),
    command: z.string(),
    exitCode: z.number().nullable().optional(),
    aggregatedOutput: z.string().nullable().optional(),
  }),
});
const turnSchema = z.object({
  threadId: z.string(),
  turn: z.object({
    id: z.string(),
    status: z.enum(["inProgress", "completed", "interrupted", "failed"]),
  }),
});

type CommandWitness =
  | { readonly kind: "pending" }
  | {
      readonly kind: "observed";
      readonly matches: boolean;
      readonly exitCode: number | null | undefined;
    };
type TurnWitness =
  | { readonly kind: "pending" }
  | { readonly kind: "observed"; readonly status: string };
interface ExecutionWitness {
  readonly turnId: string;
  readonly commandId: string;
  readonly command: CommandWitness;
  readonly turn: TurnWitness;
}
type ProbePhase =
  | { readonly kind: "waiting-for-observer" }
  | { readonly kind: "waiting-for-command"; readonly client: ChildProcessWithoutNullStreams }
  | {
      readonly kind: "dropping-client";
      readonly client: ChildProcessWithoutNullStreams;
      readonly witness: ExecutionWitness;
    }
  | { readonly kind: "awaiting-completion"; readonly witness: ExecutionWitness }
  | { readonly kind: "finished"; readonly verdict: "supported-primitive" | "not-established" };

const artifactDirectory = resolve("tmp/practices-research/2026-11-01-system-boundaries");
const runDirectory = mkdtempSync(resolve(configuration.fixtureDirectory, "armed-run-"));
const gatePath = resolve(runDirectory, "release.fifo");
const marker = `NATIVE_CONTINUITY_${randomBytes(12).toString("hex")}`;
const evidencePath = resolve(artifactDirectory, "continuity-probe-armed-events.jsonl");
const promptPath = resolve(runDirectory, "gate-prompt.txt");
const expectedCommand = `/bin/zsh -lc "/bin/cat '${gatePath}'"`;
const turnsStarted = new Set<string>();
const methodCounts = new Map<string, number>();
let phase: ProbePhase = { kind: "waiting-for-observer" };
let gateDescriptor: number | undefined;

function record(event: Readonly<Record<string, unknown>>): void {
  const line = JSON.stringify({ observedAt: new Date().toISOString(), ...event });
  appendFileSync(evidencePath, `${line}\n`, { mode: 0o600 });
  process.stdout.write(`${line}\n`);
}

const fifo = spawnSync("/usr/bin/mkfifo", ["-m", "600", gatePath], { encoding: "utf8" });
if (fifo.status !== 0) {
  record({ kind: "fixture-setup-failed", exitCode: fifo.status });
  process.exit(1);
}
gateDescriptor = openSync(gatePath, constants.O_RDWR | constants.O_NONBLOCK);
writeFileSync(
  promptPath,
  `New authorized qualification attempt. Remain the same write-restricted Operator; keep your model/settings. Prior aborted attempts are complete. Earlier full charter reads count.\n\nPerform exactly this one harmless command with your existing command-execution tool:\n\n/bin/cat '${gatePath}'\n\nThe fixture owns the pipe and will release it with one line and EOF. Keep the command and turn running while it waits, even if the requesting client disappears. If the tool returns a running-process handle, wait/read only that exact handle until exit. Do not sleep, poll state, write files, write the pipe, change settings/permissions, start helpers or send other messages. Do not cancel or kill the operation yourself. After it exits, return its exact stdout only, without interpretation or further work. If denied/unavailable, report the exact exception and stop; do not choose a substitute.\n`,
  { mode: 0o600 },
);

function releaseGate(aborted: boolean): void {
  const descriptor = gateDescriptor;
  if (descriptor === undefined) return;
  gateDescriptor = undefined;
  const payload = `${aborted ? "ABORTED_" : ""}${marker}\n`;
  writeSync(descriptor, payload);
  // Existing readers get the pipe's buffered value and EOF. Late readers get
  // the same regular-file value rather than blocking on a writerless FIFO.
  unlinkSync(gatePath);
  writeFileSync(gatePath, payload, { mode: 0o600 });
  closeSync(descriptor);
  record({ kind: "gate-released", aborted, marker });
}

function finish(verdict: "supported-primitive" | "not-established", reason: string): void {
  const current = phase;
  if (current.kind === "finished") return;
  phase = { kind: "finished", verdict };
  releaseGate(verdict !== "supported-primitive");
  if (current.kind === "waiting-for-command" || current.kind === "dropping-client")
    current.client.kill("SIGKILL");
  clearTimeout(hangGuard);
  observer.kill("SIGTERM");
  record({
    kind: "probe-verdict",
    verdict,
    reason,
    methodCounts: Object.fromEntries(methodCounts),
  });
  if (verdict !== "supported-primitive") process.exitCode = 1;
}

function completeIfReady(): void {
  if (phase.kind !== "awaiting-completion") return;
  const witness = phase.witness;
  if (witness.command.kind !== "observed" || witness.turn.kind !== "observed") return;
  if (
    witness.command.matches &&
    witness.command.exitCode === 0 &&
    witness.turn.status === "completed"
  ) {
    record({
      kind: "continuity-witness",
      turnId: witness.turnId,
      commandId: witness.commandId,
      markerMatched: true,
      commandExitCode: 0,
      nativeTurnStatus: witness.turn.status,
    });
    finish(
      "supported-primitive",
      "same native command and turn completed after confirmed requester SIGKILL with retained observer custody",
    );
  } else {
    finish(
      "not-established",
      "native command output/exit or turn settlement did not match the registered witness",
    );
  }
}

function updateWitness(update: (witness: ExecutionWitness) => ExecutionWitness): void {
  const current = phase;
  if (current.kind === "dropping-client" || current.kind === "awaiting-completion")
    phase = { ...current, witness: update(current.witness) };
  completeIfReady();
}

function startClient(): void {
  if (phase.kind !== "waiting-for-observer") return;
  const client = spawn(
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
  phase = { kind: "waiting-for-command", client };
  record({ kind: "control-client-started", pid: client.pid });
  client.stdout.on("data", (chunk: Buffer): void =>
    record({ kind: "control-client-output", bytes: chunk.byteLength }),
  );
  client.stderr.on("data", (chunk: Buffer): void =>
    record({ kind: "control-client-stderr", bytes: chunk.byteLength }),
  );
  client.on("error", (error: Error): void =>
    finish("not-established", `control client error: ${error.message}`),
  );
  client.on("exit", (code: number | null, signal: NodeJS.Signals | null): void => {
    record({ kind: "control-client-exited", pid: client.pid, code, signal });
    const current = phase;
    if (current.kind === "dropping-client" && current.client === client && signal === "SIGKILL") {
      phase = { kind: "awaiting-completion", witness: current.witness };
      releaseGate(false);
      completeIfReady();
    } else if (current.kind !== "finished") {
      finish("not-established", "requester exited before the controlled SIGKILL witness");
    }
  });
}

function handleNotification(value: unknown): void {
  const notification = notificationSchema.safeParse(value);
  if (!notification.success) return;
  const { method, params } = notification.data;
  methodCounts.set(method, (methodCounts.get(method) ?? 0) + 1);
  if (method === "turn/started" || method === "turn/completed") {
    const parsed = turnSchema.safeParse(params);
    if (!parsed.success || parsed.data.threadId !== configuration.target.sessionId) return;
    record({ kind: method, turnId: parsed.data.turn.id, status: parsed.data.turn.status });
    if (method === "turn/started" && phase.kind === "waiting-for-command")
      turnsStarted.add(parsed.data.turn.id);
    if (method === "turn/completed")
      updateWitness((witness) =>
        parsed.data.turn.id === witness.turnId
          ? { ...witness, turn: { kind: "observed", status: parsed.data.turn.status } }
          : witness,
      );
    return;
  }
  if (method !== "item/started" && method !== "item/completed") return;
  const parsed = commandSchema.safeParse(params);
  if (
    !parsed.success ||
    parsed.data.threadId !== configuration.target.sessionId ||
    parsed.data.item.command !== expectedCommand
  )
    return;
  const command = parsed.data;
  if (method === "item/started" && phase.kind === "waiting-for-command") {
    if (!turnsStarted.has(command.turnId)) {
      finish("not-established", "matching command began without its captured turn-start event");
      return;
    }
    const client = phase.client;
    phase = {
      kind: "dropping-client",
      client,
      witness: {
        turnId: command.turnId,
        commandId: command.item.id,
        command: { kind: "pending" },
        turn: { kind: "pending" },
      },
    };
    record({
      kind: "gate-command-started",
      turnId: command.turnId,
      commandId: command.item.id,
      command: command.item.command,
      outputShapeAtStart:
        command.item.aggregatedOutput === null ? "null" : typeof command.item.aggregatedOutput,
    });
    record({ kind: "control-client-kill-requested", pid: client.pid, signal: "SIGKILL" });
    if (!client.kill("SIGKILL"))
      finish("not-established", "owned requester could not be signalled");
  } else if (method === "item/completed") {
    record({
      kind: "gate-command-completed",
      turnId: command.turnId,
      commandId: command.item.id,
      exitCode: command.item.exitCode,
      markerMatched: command.item.aggregatedOutput?.trim() === marker,
    });
    updateWitness((witness) =>
      command.turnId === witness.turnId && command.item.id === witness.commandId
        ? {
            ...witness,
            command: {
              kind: "observed",
              matches: command.item.aggregatedOutput?.trim() === marker,
              exitCode: command.item.exitCode,
            },
          }
        : witness,
    );
  }
}

const observer = spawn(
  "agent-collaboration",
  [
    "events",
    "listen",
    "--endpoint",
    "codex-local",
    "--session",
    configuration.target.sessionId,
    "--attach",
    "--timeout-seconds",
    "180",
  ],
  { stdio: ["pipe", "pipe", "pipe"] },
);
const observerLines = createInterface({ input: observer.stdout });
observerLines.on("line", (line: string): void => {
  if (phase.kind === "finished") return;
  try {
    const frame = frameSchema.parse(JSON.parse(line));
    if (frame.kind === "connectionClosed") {
      finish("not-established", `observer closed: ${frame.reason}`);
      return;
    }
    if (JSON.stringify(frame.target) !== JSON.stringify(configuration.target)) {
      finish("not-established", "observer target mismatch");
      return;
    }
    if (frame.kind === "listenerReady") {
      record({ kind: "listener-ready", target: frame.target, generation: frame.generation });
      startClient();
    } else handleNotification(frame.message);
  } catch (error: unknown) {
    finish("not-established", error instanceof Error ? error.message : String(error));
  }
});
observer.stderr.on("data", (chunk: Buffer): void =>
  record({ kind: "observer-stderr", bytes: chunk.byteLength }),
);
observer.on("error", (error: Error): void =>
  finish("not-established", `observer error: ${error.message}`),
);
observer.on("exit", (code: number | null, signal: NodeJS.Signals | null): void => {
  record({ kind: "observer-exited", code, signal });
  if (phase.kind !== "finished") finish("not-established", "observer exited before completion");
});
// Same runner-owned bound as the first attempt. No elapsed-time pass condition.
const hangGuard = setTimeout((): void => finish("not-established", "runner hang guard"), 240_000);
process.on("SIGTERM", (): void => finish("not-established", "driver stopped"));
process.on("SIGINT", (): void => finish("not-established", "driver interrupted"));
record({
  kind: "registered-probe",
  target: configuration.target,
  gatePath,
  marker,
  expectedCommand,
  scope:
    "native requester SIGKILL with retained observer as prototype custody; not a product Host upgrade or last-subscriber loss",
});
