export interface QuickFindSceneObservation {
  readonly time: number;
  readonly query: string;
  readonly paneVisible: boolean;
  readonly paneSelected: boolean;
  readonly paneTitle: string;
  readonly paneSubtitle: string;
  readonly subtitleVisible: boolean;
  readonly recentVisible: boolean;
  readonly shortcutVisible: boolean;
}

export function observeQuickFindScene(root: HTMLElement, time: number): QuickFindSceneObservation {
  const visible = (element: Element | null): boolean => {
    if (element === null) return false;
    const bounds = element.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) return false;
    let top = bounds.top,
      bottom = bounds.bottom,
      left = bounds.left,
      right = bounds.right;
    let opacity = 1;
    for (
      let ancestor: Element | null = element;
      ancestor !== null;
      ancestor = ancestor.parentElement
    ) {
      const style = getComputedStyle(ancestor);
      opacity *= Number(style.opacity);
      if (style.display === "none" || style.visibility === "hidden" || opacity < 0.9) return false;
      if (["hidden", "clip"].includes(style.overflowY)) {
        const clip = ancestor.getBoundingClientRect();
        top = Math.max(top, clip.top);
        bottom = Math.min(bottom, clip.bottom);
      }
      if (["hidden", "clip"].includes(style.overflowX)) {
        const clip = ancestor.getBoundingClientRect();
        left = Math.max(left, clip.left);
        right = Math.min(right, clip.right);
      }
      if (ancestor === root) break;
    }
    return (bottom - top) / bounds.height >= 0.9 && (right - left) / bounds.width >= 0.9;
  };
  const pane = root.querySelector('[data-scene-part="pane-results"] .kit-command-bar__row');
  const title = pane?.querySelector(".kit-command-bar__label") ?? null;
  const subtitle =
    pane?.querySelector(".kit-command-bar__subtitle, .kit-command-bar__meta") ?? null;
  const queryElement = root.querySelector('[data-scene-part="command-query"]');
  const queryText = queryElement?.textContent?.trim() ?? "";
  const hiddenQueryPercent =
    queryElement === null
      ? 100
      : Number(getComputedStyle(queryElement).clipPath.match(/inset\(\S+\s+([\d.]+)%/u)?.[1] ?? 0);
  const query = queryText.slice(0, Math.round(queryText.length * (1 - hiddenQueryPercent / 100)));
  return {
    time,
    query,
    paneVisible: visible(pane ?? null) && visible(title),
    paneSelected: pane?.hasAttribute("data-selected") ?? false,
    paneTitle: title?.textContent?.trim() ?? "",
    paneSubtitle: subtitle?.textContent?.trim() ?? "",
    subtitleVisible: visible(subtitle),
    recentVisible: visible(
      root.querySelector('[data-scene-part="recent-repositories"] .kit-command-bar__row'),
    ),
    shortcutVisible: visible(root.querySelector('[data-scene-part="command-shortcut"]')),
  };
}
