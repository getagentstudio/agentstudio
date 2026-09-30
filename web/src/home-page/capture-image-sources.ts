import type { ImageMetadata } from "astro";
import { getImage } from "astro:assets";

/** Palette PNG preserves the approved crop while selecting a phone-sized delivery. */
export async function createPhoneCaptureSources(image: ImageMetadata): Promise<string> {
  const variants = await Promise.all(
    [320, 640, 1280].map(async (width): Promise<string> => {
      const variant = await getImage({ src: image, width, format: "png", quality: 100 });
      return `${variant.src} ${width}w`;
    }),
  );
  return variants.join(", ");
}
