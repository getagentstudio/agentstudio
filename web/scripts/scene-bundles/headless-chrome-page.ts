// One headless Chrome page driven over the DevTools protocol with Node's
// built-in WebSocket, so the scene bundle build needs no browser library.

import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";

import { resolveChromeExecutable, stopBrowserProcess } from "../headless-chrome-process.ts";

// Hang bounds only: Chrome reports readiness and results as events.
const chromeStartupHangBoundMs = 30_000;
const pageCallHangBoundMs = 60_000;

export interface HeadlessChromePage {
  /**
   * Runs a self-contained function in the page and returns its JSON-serializable
   * result. The function must not close over module scope: only its source text
   * and JSON arguments reach the page.
   */
  evaluate<TArguments extends readonly unknown[], TResult>(
    pageFunction: (...args: TArguments) => TResult,
    ...args: TArguments
  ): Promise<Awaited<TResult>>;
  close(): Promise<void>;
}

interface DevToolsTarget {
  readonly type: string;
  readonly webSocketDebuggerUrl: string;
}

/** A protocol reply, read field by field from untyped JSON. */
type DevToolsReply = Readonly<Record<string, unknown>>;

type EvaluationOutcome =
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly message: string };

interface PendingCall {
  readonly resolve: (reply: DevToolsReply) => void;
  readonly reject: (error: Error) => void;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null;
}

function isDevToolsTarget(value: unknown): value is DevToolsTarget {
  return (
    isRecord(value) &&
    typeof value["type"] === "string" &&
    typeof value["webSocketDebuggerUrl"] === "string"
  );
}

/** Runtime.evaluate's reply: the returned value, or why the page call failed. */
function readEvaluationOutcome(reply: DevToolsReply): EvaluationOutcome {
  const { error, result } = reply;
  if (isRecord(error)) {
    return { ok: false, message: `DevTools rejected the call: ${String(error["message"])}` };
  }
  if (!isRecord(result)) {
    return { ok: false, message: "DevTools answered without a result." };
  }
  const exceptionDetails = result["exceptionDetails"];
  if (isRecord(exceptionDetails)) {
    const exception = exceptionDetails["exception"];
    const description = isRecord(exception) ? exception["description"] : undefined;
    return {
      ok: false,
      message: typeof description === "string" ? description : String(exceptionDetails["text"]),
    };
  }
  const remoteObject = result["result"];
  return { ok: true, value: isRecord(remoteObject) ? remoteObject["value"] : undefined };
}

async function readDevToolsBrowserUrl(chromeProcess: ChildProcess): Promise<URL> {
  const stderr = chromeProcess.stderr;
  if (stderr === null) {
    throw new Error("Headless Chrome started without a readable stderr.");
  }
  const lines = createInterface({ input: stderr });
  return await new Promise<URL>((resolve, reject): void => {
    const finish = (outcome: URL | Error): void => {
      clearTimeout(hangBound);
      lines.close();
      chromeProcess.off("exit", rejectOnExit);
      chromeProcess.off("error", finish);
      if (outcome instanceof URL) {
        resolve(outcome);
      } else {
        reject(outcome);
      }
    };
    const rejectOnExit = (exitCode: number | null): void => {
      finish(new Error(`Headless Chrome exited with ${String(exitCode)} before DevTools started.`));
    };
    const hangBound = setTimeout((): void => {
      finish(new Error("Headless Chrome did not report a DevTools endpoint."));
    }, chromeStartupHangBoundMs);
    lines.on("line", (line: string): void => {
      const match = /DevTools listening on (ws:\/\/\S+)/.exec(line);
      if (match?.[1] !== undefined) {
        finish(new URL(match[1]));
      }
    });
    chromeProcess.once("exit", rejectOnExit);
    chromeProcess.once("error", finish);
  });
}

async function readPageTargetUrl(browserUrl: URL): Promise<string> {
  const response = await fetch(`http://${browserUrl.host}/json/list`);
  const targets: unknown = await response.json();
  const pageTarget = Array.isArray(targets)
    ? targets.filter(isDevToolsTarget).find((target) => target.type === "page")
    : undefined;
  if (pageTarget === undefined) {
    throw new Error("Headless Chrome has no page target.");
  }
  return pageTarget.webSocketDebuggerUrl;
}

async function connectToPage(pageUrl: string): Promise<WebSocket> {
  const socket = new WebSocket(pageUrl);
  await new Promise<void>((resolve, reject): void => {
    socket.addEventListener("open", (): void => resolve(), { once: true });
    socket.addEventListener(
      "error",
      (): void => reject(new Error("Could not connect to the headless Chrome page.")),
      { once: true },
    );
  });
  return socket;
}

function createPageCaller(socket: WebSocket): (expression: string) => Promise<DevToolsReply> {
  const pendingCalls = new Map<number, PendingCall>();
  let nextCallId = 1;
  socket.addEventListener("message", (event: MessageEvent): void => {
    const reply: unknown = JSON.parse(String(event.data));
    if (!isRecord(reply) || typeof reply["id"] !== "number") {
      return;
    }
    const callId = reply["id"];
    const pendingCall = pendingCalls.get(callId);
    if (pendingCall !== undefined) {
      pendingCalls.delete(callId);
      pendingCall.resolve(reply);
    }
  });
  socket.addEventListener("close", (): void => {
    for (const pendingCall of pendingCalls.values()) {
      pendingCall.reject(new Error("The headless Chrome page closed mid-call."));
    }
    pendingCalls.clear();
  });
  return async (expression: string): Promise<DevToolsReply> => {
    const callId = nextCallId;
    nextCallId += 1;
    return await new Promise<DevToolsReply>((resolve, reject): void => {
      const hangBound = setTimeout((): void => {
        pendingCalls.delete(callId);
        reject(new Error("A headless Chrome page call did not answer."));
      }, pageCallHangBoundMs);
      pendingCalls.set(callId, {
        resolve: (reply): void => {
          clearTimeout(hangBound);
          resolve(reply);
        },
        reject: (error): void => {
          clearTimeout(hangBound);
          reject(error);
        },
      });
      socket.send(
        JSON.stringify({
          id: callId,
          method: "Runtime.evaluate",
          params: { expression, awaitPromise: true, returnByValue: true },
        }),
      );
    });
  };
}

export async function openHeadlessChromePage(purpose: string): Promise<HeadlessChromePage> {
  const chromeExecutable = await resolveChromeExecutable(purpose);
  const profileDirectory = await mkdtemp(path.join(tmpdir(), "agent-studio-headless-chrome-"));
  const chromeProcess = spawn(
    chromeExecutable,
    [
      "--headless=new",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-gpu",
      "--no-default-browser-check",
      "--no-first-run",
      "--remote-debugging-port=0",
      `--user-data-dir=${profileDirectory}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  const close = async (socket?: WebSocket): Promise<void> => {
    socket?.close();
    await stopBrowserProcess(chromeProcess);
    // Chrome's helper processes (network service, GPU) can still flush files into
    // Default/ just after the browser process exits; rm retries on ENOTEMPTY/EBUSY.
    await rm(profileDirectory, { force: true, recursive: true, maxRetries: 10, retryDelay: 100 });
  };

  let socket: WebSocket;
  try {
    const browserUrl = await readDevToolsBrowserUrl(chromeProcess);
    socket = await connectToPage(await readPageTargetUrl(browserUrl));
  } catch (error: unknown) {
    await close();
    throw error;
  }
  const callPage = createPageCaller(socket);

  return {
    async evaluate<TArguments extends readonly unknown[], TResult>(
      pageFunction: (...args: TArguments) => TResult,
      ...args: TArguments
    ): Promise<Awaited<TResult>> {
      const expression = `(${pageFunction.toString()})(...${JSON.stringify(args)})`;
      const outcome = readEvaluationOutcome(await callPage(expression));
      if (!outcome.ok) {
        throw new Error(`${pageFunction.name} failed in the page: ${outcome.message}`);
      }
      // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the page ran pageFunction itself, so the JSON it returned is that function's TResult.
      return outcome.value as Awaited<TResult>;
    },
    close: async (): Promise<void> => await close(socket),
  };
}
