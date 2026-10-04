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
