export interface DeferredProofVideo {
  prime(): void;
  dispose(): void;
}

/** Prime below-fold proof one viewport early; the scene also primes at handoff. */
export function createDeferredProofVideo(video: HTMLVideoElement | null): DeferredProofVideo {
  const deferredSource = video?.querySelector<HTMLSourceElement>("source[data-src]");
  let observer: IntersectionObserver | undefined;
  const lifecycle = new AbortController();
  const prime = (): void => {
    if (video === null || deferredSource === null || deferredSource === undefined) return;
    const sourceUrl = deferredSource.dataset["src"];
    if (sourceUrl === undefined || deferredSource.hasAttribute("src")) return;
    deferredSource.src = sourceUrl;
    video.preload = "auto";
    video.load();
    observer?.disconnect();
  };
  if (video !== null && deferredSource !== null && deferredSource !== undefined) {
    observer = new IntersectionObserver(
      (entries): void => {
        if (entries.some((entry) => entry.isIntersecting)) prime();
      },
      { rootMargin: `${window.innerHeight}px 0px` },
    );
    observer.observe(video.closest(".chapter-scene-stage") ?? video);
    video.addEventListener("pointerdown", prime, { signal: lifecycle.signal });
    video.addEventListener("keydown", prime, { signal: lifecycle.signal });
  }
  return {
    prime,
    dispose: (): void => {
      observer?.disconnect();
      lifecycle.abort();
    },
  };
}
