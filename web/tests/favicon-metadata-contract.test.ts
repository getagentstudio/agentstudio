import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { extname, resolve, sep } from "node:path";

import sharp from "sharp";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  campaignAttributionRegistry,
  campaignChannels,
} from "../src/campaign-attribution/campaign-attribution-registry";
import { marketingCopy } from "../src/marketing-copy";

const canonicalHomeUrl = "https://getagentstudio.dev/";
const canonicalSitemapUrl = "https://getagentstudio.dev/sitemap.xml";
const expectedMetadataTitle = "Agent Studio: Native macOS IDE for parallel coding agents";
const productionOutputDirectory = resolve(process.cwd(), "dist");
const productionOutputPrefix = `${productionOutputDirectory}${sep}`;
const contentTypeByExtension = new Map<string, string>([
  [".html", "text/html; charset=utf-8"],
  [".jpg", "image/jpeg"],
  [".mp4", "video/mp4"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"],
  [".txt", "text/plain; charset=utf-8"],
  [".xml", "application/xml; charset=utf-8"],
]);
let previewOrigin = "";
let previewServer: Server | undefined;

const parseAttributes = (tag: string): ReadonlyMap<string, string> => {
  const attributes = new Map<string, string>();
  for (const match of tag.matchAll(/([:\w-]+)=["']([^"']*)["']/g)) {
    const [, name, value] = match;
    if (name !== undefined && value !== undefined) {
      attributes.set(name, value);
    }
  }
  return attributes;
};

const findTagAttributes = (
  html: string,
  tagName: "link" | "meta",
  selectorName: string,
  selectorValue: string,
): ReadonlyMap<string, string> | undefined => {
  const tags = html.match(new RegExp(`<${tagName}\\b[^>]*>`, "gi")) ?? [];
  return tags
    .map(parseAttributes)
    .find((attributes) => attributes.get(selectorName) === selectorValue);
};

const startProductionArtifactServer = async (): Promise<void> => {
  previewServer = createServer((request, response): void => {
    void (async (): Promise<void> => {
      const requestPath = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
      const outputPath = requestPath.endsWith("/") ? `${requestPath}index.html` : requestPath;
      const filePath = resolve(productionOutputDirectory, outputPath.replace(/^\/+/, ""));
      if (filePath !== productionOutputDirectory && !filePath.startsWith(productionOutputPrefix)) {
        response.writeHead(404).end();
        return;
      }

      try {
        const fileBytes = await readFile(filePath);
        response.writeHead(200, {
          "Content-Type":
            contentTypeByExtension.get(extname(filePath)) ?? "application/octet-stream",
        });
        response.end(fileBytes);
      } catch {
        response.writeHead(404).end();
      }
    })();
  });

  await new Promise<void>((resolveListen, rejectListen): void => {
    const server = previewServer;
    if (server === undefined) {
      rejectListen(new Error("Production artifact server was not created"));
      return;
    }
    server.once("error", rejectListen);
    server.listen(0, "127.0.0.1", (): void => {
      server.off("error", rejectListen);
      const address = server.address();
      if (address === null || typeof address === "string") {
        rejectListen(new Error("Production artifact server did not bind a TCP port"));
        return;
      }
      previewOrigin = `http://127.0.0.1:${address.port}`;
      resolveListen();
    });
  });
};

describe("site discovery metadata", () => {
  beforeAll(async (): Promise<void> => {
    const buildResult = spawnSync("pnpm", ["run", "build"], {
      cwd: process.cwd(),
      encoding: "utf8",
    });

    if (buildResult.status !== 0) {
      throw new Error(`Website build failed:\n${buildResult.stdout}\n${buildResult.stderr}`);
    }

    await startProductionArtifactServer();
  }, 30_000);

  afterAll(async (): Promise<void> => {
    if (previewServer !== undefined) {
      await new Promise<void>((resolveClose, rejectClose): void => {
        previewServer?.close((error?: Error): void => {
          if (error === undefined) {
            resolveClose();
          } else {
            rejectClose(error);
          }
        });
      });
    }
  });

  it("publishes one truthful structured-data graph from the page's owned facts", async (): Promise<void> => {
    const html = await (await fetch(previewOrigin)).text();
    const scripts = [
      ...html.matchAll(/<script\b[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gu),
    ];
    expect(scripts).toHaveLength(1);
    const graphText = scripts[0]?.[1];
    if (graphText === undefined) throw new Error("Structured data missing");
    const parsed: unknown = JSON.parse(graphText);
    expect(parsed).toEqual({
      "@context": "https://schema.org",
      "@graph": [
        {
          "@type": "SoftwareApplication",
          "@id": `${canonicalHomeUrl}#application`,
          name: marketingCopy.productName,
          description: marketingCopy.hero.description,
          applicationCategory: marketingCopy.applicationCategory,
          operatingSystem: marketingCopy.installation.systemRequirement
            .replace(/^Requires /u, "")
            .replace(/\.$/u, ""),
          url: canonicalHomeUrl,
          installUrl: `${marketingCopy.githubUrl}#install`,
          softwareHelp: { "@type": "CreativeWork", url: `${marketingCopy.githubUrl}#readme` },
          creator: { "@id": `${canonicalHomeUrl}#creator` },
        },
        {
          "@type": "WebSite",
          "@id": `${canonicalHomeUrl}#website`,
          name: marketingCopy.productName,
          url: canonicalHomeUrl,
          description: marketingCopy.hero.description,
        },
        {
          "@type": "Person",
          "@id": `${canonicalHomeUrl}#creator`,
          name: marketingCopy.finalCallToAction.creatorName,
          sameAs: [marketingCopy.socialLinks.github.url, marketingCopy.socialLinks.x.url],
        },
      ],
    });
  });

  it("serves a plain-text agent summary with exact rendered install command parity", async (): Promise<void> => {
    const response = await fetch(new URL("/llms.txt", previewOrigin));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/^text\/plain\b/u);
    const text = await response.text();
    expect(await readFile(resolve(productionOutputDirectory, "public", "llms.txt"), "utf8")).toBe(
      text,
    );
    const commands = text.match(/```sh\n([\s\S]*?)\n```/u)?.[1];
    expect(commands).toBe(marketingCopy.installation.commands.join("\n"));
    const html = await (await fetch(previewOrigin)).text();
    const installTag = html.match(/<div\b[^>]*data-install-command-root[^>]*>/u)?.[0];
    if (installTag === undefined) throw new Error("Rendered install box missing");
    expect(commands).toBe(parseAttributes(installTag).get("data-install-command"));
    expect(text).toContain(`# ${marketingCopy.productName}`);
    expect(text).toContain(marketingCopy.hero.description);
    expect(text).toContain(marketingCopy.installation.systemRequirement);
    for (const url of [
      canonicalHomeUrl,
      marketingCopy.githubUrl,
      `${marketingCopy.githubUrl}#readme`,
      `${marketingCopy.githubUrl}/tree/main/docs`,
    ])
      expect(text).toContain(`](${url})`);
  });

  it("advertises a fetchable image favicon from the home page", async (): Promise<void> => {
    const homePageResponse = await fetch(previewOrigin);
    expect(homePageResponse.status).toBe(200);

    const homePageHtml = await homePageResponse.text();
    const faviconHref = homePageHtml.match(
      /<link\b[^>]*\brel=["'](?:shortcut )?icon["'][^>]*\bhref=["']([^"']+)["'][^>]*>/i,
    )?.[1];
    expect(faviconHref).toBeDefined();
    if (faviconHref === undefined) {
      throw new Error("The built home page did not advertise a favicon");
    }

    const faviconResponse = await fetch(new URL(faviconHref, previewOrigin));
    expect(faviconResponse.status).toBe(200);
    expect(faviconResponse.headers.get("content-type")).toMatch(/^image\//);
  });

  it("publishes canonical search and social metadata with a usable social card", async (): Promise<void> => {
    const homePageResponse = await fetch(previewOrigin);
    expect(homePageResponse.status).toBe(200);

    const homePageHtml = await homePageResponse.text();
    expect(homePageHtml).toContain(`<title>${expectedMetadataTitle}</title>`);

    const canonicalLink = findTagAttributes(homePageHtml, "link", "rel", "canonical");
    expect(canonicalLink?.get("href")).toBe(canonicalHomeUrl);

    const pageDescription = findTagAttributes(homePageHtml, "meta", "name", "description")?.get(
      "content",
    );
    expect(pageDescription).toBeTruthy();

    const expectedMetadata = new Map<string, string>([
      ["og:type", "website"],
      ["og:site_name", "Agent Studio"],
      ["og:title", expectedMetadataTitle],
      ["og:description", pageDescription ?? ""],
      ["og:url", canonicalHomeUrl],
      ["og:image:type", "image/png"],
      ["og:image:width", "1200"],
      ["og:image:height", "630"],
      ["twitter:card", "summary_large_image"],
      ["twitter:title", expectedMetadataTitle],
      ["twitter:description", pageDescription ?? ""],
    ]);

    for (const [metadataName, expectedValue] of expectedMetadata) {
      const selectorName = metadataName.startsWith("og:") ? "property" : "name";
      const metadataTag = findTagAttributes(homePageHtml, "meta", selectorName, metadataName);
      expect(metadataTag?.get("content"), metadataName).toBe(expectedValue);
    }

    const openGraphImage = findTagAttributes(homePageHtml, "meta", "property", "og:image");
    const xImage = findTagAttributes(homePageHtml, "meta", "name", "twitter:image");
    const openGraphImageAlt = findTagAttributes(
      homePageHtml,
      "meta",
      "property",
      "og:image:alt",
    )?.get("content");
    const xImageAlt = findTagAttributes(homePageHtml, "meta", "name", "twitter:image:alt")?.get(
      "content",
    );
    const socialImageUrl = openGraphImage?.get("content");
    expect(socialImageUrl).toBe("https://getagentstudio.dev/agent-studio-social-card.png");
    expect(xImage?.get("content")).toBe(socialImageUrl);
    expect(openGraphImageAlt).toBeTruthy();
    expect(xImageAlt).toBe(openGraphImageAlt);

    if (socialImageUrl === undefined) {
      throw new Error("The built home page did not advertise a social-card image");
    }

    const socialImageResponse = await fetch(
      new URL(new URL(socialImageUrl).pathname, previewOrigin),
    );
    expect(socialImageResponse.status).toBe(200);
    expect(socialImageResponse.headers.get("content-type")).toBe("image/png");

    const socialImageMetadata = await sharp(
      Buffer.from(await socialImageResponse.arrayBuffer()),
    ).metadata();
    expect(socialImageMetadata.width).toBe(1200);
    expect(socialImageMetadata.height).toBe(630);
  });

  it("publishes aggregate and registered campaign pages with canonical homepage metadata", async (): Promise<void> => {
    const campaignPaths = [
      ...campaignChannels.map((channel) => `/${channel}/`),
      ...campaignAttributionRegistry.routes.map((route) => `${route.path}/`),
    ];

    await Promise.all(
      campaignPaths.map(async (campaignPath): Promise<void> => {
        const campaignResponse = await fetch(new URL(campaignPath, previewOrigin));
        expect(campaignResponse.status, campaignPath).toBe(200);

        const campaignHtml = await campaignResponse.text();
        expect(campaignHtml, campaignPath).toContain(`<title>${expectedMetadataTitle}</title>`);
        expect(
          findTagAttributes(campaignHtml, "link", "rel", "canonical")?.get("href"),
          campaignPath,
        ).toBe(canonicalHomeUrl);
        expect(
          findTagAttributes(campaignHtml, "meta", "property", "og:url")?.get("content"),
          campaignPath,
        ).toBe(canonicalHomeUrl);
        expect(
          findTagAttributes(campaignHtml, "meta", "name", "twitter:title")?.get("content"),
          campaignPath,
        ).toBe(expectedMetadataTitle);
        expect(
          findTagAttributes(campaignHtml, "meta", "property", "og:image")?.get("content"),
          campaignPath,
        ).toBe("https://getagentstudio.dev/agent-studio-social-card.png");
      }),
    );

    const unknownCampaignResponse = await fetch(new URL("/x/zzzz/", previewOrigin));
    expect(unknownCampaignResponse.status).toBe(404);
  });

  it("publishes only the canonical home page in the sitemap and advertises it in robots", async (): Promise<void> => {
    const sitemapResponse = await fetch(new URL("/sitemap.xml", previewOrigin));
    expect(sitemapResponse.status).toBe(200);
    expect(sitemapResponse.headers.get("content-type")).toMatch(/^application\/xml/);

    const sitemapXml = await sitemapResponse.text();
    expect(sitemapXml).toContain(`<loc>${canonicalHomeUrl}</loc>`);
    for (const campaignChannel of campaignChannels) {
      expect(sitemapXml).not.toContain(`/${campaignChannel}`);
    }

    const robotsResponse = await fetch(new URL("/robots.txt", previewOrigin));
    expect(robotsResponse.status).toBe(200);
    const robotsText = await robotsResponse.text();
    expect(robotsText).toContain("User-agent: *");
    expect(robotsText).toContain("Allow: /");
    expect(robotsText).toContain(`Sitemap: ${canonicalSitemapUrl}`);
  });
});
