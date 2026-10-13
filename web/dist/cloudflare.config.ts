import { bindings, defineWorker } from "@cloudflare/vite-plugin/experimental-config";

import * as entrypoint from "../src/campaign-attribution/campaign-request-worker.ts" with { type: "cf-worker" };

export default defineWorker({
  name: "agent-studio-web",
  compatibilityDate: "2026-08-20",
  entrypoint,
  env: {
    ASSETS: bindings.assets(),
    ANALYTICS: bindings.analyticsEngineDataset({ name: "agent_studio_campaign_requests" }),
  },
  assets: {
    htmlHandling: "drop-trailing-slash",
    notFoundHandling: "none",
    runWorkerFirst: ["/x", "/x/*", "/yt", "/yt/*", "/c", "/c/*"],
  },
});
