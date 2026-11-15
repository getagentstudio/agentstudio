export function visibleTextIncludingOpenShadowRoots(
	root: Element | ShadowRoot,
	viewport: DOMRect,
): string {
	const textFragments: string[] = [];
	const textWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	let currentNode = textWalker.nextNode();
	while (currentNode !== null) {
		const text = currentNode.textContent ?? '';
		if (text.trim().length > 0 && textNodeIntersectsViewport(currentNode, viewport)) {
			textFragments.push(text);
		}
		currentNode = textWalker.nextNode();
	}
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot !== null) {
			textFragments.push(visibleTextIncludingOpenShadowRoots(descendant.shadowRoot, viewport));
		}
	}
	return textFragments.join('\n');
}

function textNodeIntersectsViewport(textNode: Node, viewport: DOMRect): boolean {
	const range = document.createRange();
	range.selectNodeContents(textNode);
	const bounds = range.getBoundingClientRect();
	return (
		bounds.width > 0 &&
		bounds.height > 0 &&
		bounds.bottom > viewport.top &&
		bounds.top < viewport.bottom &&
		bounds.right > viewport.left &&
		bounds.left < viewport.right
	);
}

export function queryBridgeReviewRecoveryWitnessOpenShadowRoots(
	root: Element | ShadowRoot,
	selector: string,
): readonly Element[] {
	const matches = [...root.querySelectorAll(selector)];
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot === null) continue;
		matches.push(
			...queryBridgeReviewRecoveryWitnessOpenShadowRoots(descendant.shadowRoot, selector),
		);
	}
	return matches;
}

export function textIncludingOpenShadowRoots(root: Element | ShadowRoot): string {
	const textFragments: string[] = [];
	const textWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	let currentNode = textWalker.nextNode();
	while (currentNode !== null) {
		textFragments.push(currentNode.textContent ?? '');
		currentNode = textWalker.nextNode();
	}
	if (root instanceof Element && root.shadowRoot !== null) {
		textFragments.push(textIncludingOpenShadowRoots(root.shadowRoot));
	}
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot !== null) {
			textFragments.push(textIncludingOpenShadowRoots(descendant.shadowRoot));
		}
	}
	return textFragments.join('\n');
}
