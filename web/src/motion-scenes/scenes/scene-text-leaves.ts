/** A layout audit checks each element's own text, not only its ancestors. */
export function hasNonWhitespaceDirectText(element: Element): boolean {
  return Array.from(element.childNodes).some(
    (childNode) =>
      childNode.nodeType === Node.TEXT_NODE && (childNode.textContent ?? "").trim().length > 0,
  );
}

/** Includes mixed-content parents with direct text as well as text-only spans. */
export function collectSceneTextLeaves(container: HTMLElement): readonly HTMLElement[] {
  return [...container.querySelectorAll<HTMLElement>("*")].filter(hasNonWhitespaceDirectText);
}
