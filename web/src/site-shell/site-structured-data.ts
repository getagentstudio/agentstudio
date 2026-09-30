import { marketingCopy } from "../marketing-copy";
import { canonicalHomeUrl } from "../site-metadata";

/** Product and creator facts share the page's copy owners; no inferred price. */
export const siteStructuredData = {
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
} as const;
