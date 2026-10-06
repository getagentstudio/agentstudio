import path from "node:path";

import { dev } from "astro";

const [websiteRoot, portArgument] = process.argv.slice(2);
const port = Number(portArgument);
if (websiteRoot === undefined || !Number.isInteger(port)) {
  throw new Error("Header browser-test server requires a website root and integer port");
}

const server = await dev({
  logLevel: "silent",
  root: websiteRoot,
  server: { host: "127.0.0.1", port },
  integrations: [
    {
      name: "proof-video-test-fixture",
      hooks: {
        "astro:config:setup": ({ injectRoute }): void => {
          injectRoute({
            pattern: "/__test/proof-video",
            entrypoint: path.join(websiteRoot, "tests/fixtures/proof-video-stage.astro"),
          });
          injectRoute({
            pattern: "/__test/proof-chapter",
            entrypoint: path.join(websiteRoot, "tests/fixtures/proof-chapter.astro"),
          });
        },
      },
    },
  ],
  vite: {
    cacheDir: path.join(websiteRoot, "node_modules", ".vite-hero-browser-tests"),
    // All browser files share this dev server. Prebundle the hero's dependency
    // before parallel pages discover it, so their module URLs do not receive
    // Vite's 504 Outdated Optimize Dep response during an optimizer restart.
    optimizeDeps: { include: ["gsap"], noDiscovery: true },
    server: { strictPort: true },
  },
});
if (process.send === undefined) {
  await server.stop();
  throw new Error("Header browser-test server requires an IPC owner");
}
process.send({ kind: "ready", port: server.address.port });

const stopServer = async (): Promise<void> => {
  await server.stop();
  process.exit(0);
};

process.once("SIGTERM", (): void => {
  void stopServer();
});

await new Promise<void>(() => undefined);
