import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { z } from "../../../BridgeWeb/node_modules/zod/index.js";

const fixtureSessionId = "01a199ac-e013-70a3-bc49-65aaf9bf8faf";
const responseSchema = z.object({
  id: z.union([z.string(), z.number()]),
  result: z.unknown().optional(),
  error: z.unknown().optional(),
});
const nativeErrorSchema = z.object({
  message: z.string().optional(),
  codexErrorInfo: z.unknown().optional(),
});
const itemSchema = z.object({ type: z.string() }).passthrough();
const commandItemSchema = z.object({
  type: z.literal("commandExecution"),
  command: z.string(),
  status: z.string(),
  exitCode: z.number().nullable().optional(),
  aggregatedOutput: z.string().optional(),
  durationMs: z.number().nullable().optional(),
});
const resultSchema = z.object({
  thread: z.object({
    id: z.literal(fixtureSessionId),
    turns: z.array(
      z.object({
        id: z.string(),
        status: z.string(),
        error: z.unknown().optional(),
        items: z.array(itemSchema),
      }),
    ),
  }),
});
const bridge = spawn("agent-collaboration", ["native", "--endpoint", "codex-local"], {
  stdio: ["pipe", "pipe", "pipe"],
});
const lines = createInterface({ input: bridge.stdout });
let received = false;

function sendFrame(frame: Readonly<Record<string, unknown>>): void {
  bridge.stdin.write(`${JSON.stringify(frame)}\n`);
}

function report(value: Readonly<Record<string, unknown>>): void {
  const output = `${JSON.stringify(value, null, 2)}\n`;
  writeFileSync(
    resolve(
      "tmp/practices-research/2026-11-01-system-boundaries/continuity-probe-native-diagnostic.json",
    ),
    output,
    { mode: 0o600 },
  );
  process.stdout.write(output);
}

lines.on("line", (line: string): void => {
  try {
    const decoded: unknown = JSON.parse(line);
    const response = responseSchema.safeParse(decoded);
    if (!response.success) return;
    if (response.data.error !== undefined) {
      report({
        kind: "native-read-error",
        responseId: response.data.id,
        error: response.data.error,
      });
      received = true;
      bridge.stdin.end();
      return;
    }
    if (response.data.id === 1) {
      sendFrame({ method: "initialized" });
      sendFrame({
        id: 2,
        method: "thread/read",
        params: { threadId: fixtureSessionId, includeTurns: true },
      });
    } else if (response.data.id === 2) {
      const result = resultSchema.parse(response.data.result);
      report({
        kind: "fixture-native-turn-metadata",
        target: fixtureSessionId,
        turns: result.thread.turns.map((turn) => {
          const failure = nativeErrorSchema.safeParse(turn.error);
          return {
            turnId: turn.id,
            status: turn.status,
            itemTypes: turn.items.map((item) => item.type),
            commands: turn.items.flatMap((item) => {
              const command = commandItemSchema.safeParse(item);
              if (!command.success) return [];
              const fixtureCommand = command.data.command.includes(
                "/private/tmp/2026-11-continuity-fixture-TBssSS/",
              );
              return [
                {
                  command: command.data.command,
                  status: command.data.status,
                  exitCode: command.data.exitCode,
                  durationMs: command.data.durationMs,
                  fixtureOutput: fixtureCommand ? command.data.aggregatedOutput : undefined,
                },
              ];
            }),
            error: failure.success ? failure.data : null,
          };
        }),
      });
      received = true;
      bridge.stdin.end();
    }
  } catch (error: unknown) {
    report({
      kind: "diagnostic-parse-error",
      message: error instanceof Error ? error.message : String(error),
    });
    received = true;
    bridge.stdin.end();
  }
});
bridge.on("error", (error: Error): void =>
  report({ kind: "native-bridge-error", message: error.message }),
);
bridge.stderr.on("data", (chunk: Buffer): void => {
  process.stderr.write(chunk);
});
const hangGuard = setTimeout((): void => {
  report({ kind: "native-read-hang-guard", received });
  bridge.kill("SIGKILL");
  process.exitCode = 1;
}, 20_000);
bridge.on("close", (code: number | null, signal: NodeJS.Signals | null): void => {
  clearTimeout(hangGuard);
  process.stdout.write(
    `${JSON.stringify({ kind: "native-read-client-closed", code, signal, received })}\n`,
  );
  if (!received || code !== 0) process.exitCode = 1;
});
sendFrame({
  id: 1,
  method: "initialize",
  params: {
    clientInfo: {
      name: "continuity_fixture_diagnostic",
      title: "Continuity fixture diagnostic",
      version: "0.1.0",
    },
    capabilities: { experimentalApi: true },
  },
});
