import { spawn } from "node:child_process";
import { once } from "node:events";

import { expect, it } from "vitest";

import { stopBrowserProcess } from "../scripts/headless-chrome-process.ts";

it("returns from a forced stop only after the browser process has exited", async () => {
  // Arrange: a stand-in browser that ignores SIGTERM, like a Chrome too busy to shut down.
  const stubbornBrowser = spawn(
    process.execPath,
    [
      "-e",
      "process.on('SIGTERM', () => {}); process.stdout.write('ready'); setInterval(() => {}, 1000);",
    ],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  await once(stubbornBrowser.stdout, "data");

  // Act
  await stopBrowserProcess(stubbornBrowser, { forcedExitAfterMs: 20 });

  // Assert: the caller may now delete the profile because the process is gone.
  expect(stubbornBrowser.signalCode).toBe("SIGKILL");
});

it("rejects when a running browser cannot be signalled, so its profile is not deleted", async () => {
  // Arrange: a live process whose kill() fails, as with EPERM.
  const unkillableBrowser = spawn(
    process.execPath,
    ["-e", "process.stdout.write('ready'); setInterval(() => {}, 1000);"],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  await once(unkillableBrowser.stdout, "data");
  const realKill = unkillableBrowser.kill.bind(unkillableBrowser);
  unkillableBrowser.kill = (): boolean => {
    throw new Error("kill EPERM");
  };

  // Act + Assert: liveness is unknown, so the stop must not report success.
  await expect(stopBrowserProcess(unkillableBrowser, { forcedExitAfterMs: 20 })).rejects.toThrow(
    "kill EPERM",
  );
  expect(unkillableBrowser.exitCode).toBeNull();

  // Cleanup: stop the real child before the test returns.
  const exited = once(unkillableBrowser, "exit");
  realKill("SIGKILL");
  await exited;
});

it("returns for a browser that never started, so failed launches still clean up", async () => {
  // Arrange: a missing executable gets no pid and emits "error" then "close", never "exit".
  const missingBrowser = spawn("/nonexistent/agent-studio-test-browser", [], { stdio: "ignore" });
  const spawnErrorDelivered = once(missingBrowser, "error");

  // Act: stop before the "error" event arrives, while exitCode is still null.
  await stopBrowserProcess(missingBrowser, { forcedExitAfterMs: 20 });

  // Assert
  expect(missingBrowser.pid).toBeUndefined();
  const [spawnError] = await spawnErrorDelivered;
  expect(spawnError).toMatchObject({ code: "ENOENT" });
});
