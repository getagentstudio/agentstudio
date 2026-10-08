export function dispatchPointer(
	target: EventTarget,
	type: 'pointerdown' | 'pointermove' | 'pointerup',
	init: PointerEventInit,
): void {
	target.dispatchEvent(
		new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }),
	);
}

export interface PointerHitProbe {
	readonly bounds: string;
	readonly hitUtilityButton: boolean;
	readonly lineNumber: string | null;
	readonly targetTagName: string | null;
	readonly targetDescription: string | null;
}

export function pointerHitProbe(utility: HTMLElement, bounds: DOMRect): PointerHitProbe {
	const point = pointerAt(bounds, 0);
	const root = utility.getRootNode();
	const target =
		root instanceof ShadowRoot
			? root.elementFromPoint(point.clientX ?? 0, point.clientY ?? 0)
			: document.elementFromPoint(point.clientX ?? 0, point.clientY ?? 0);
	return {
		bounds: `${bounds.left},${bounds.top} ${bounds.width}x${bounds.height}`,
		hitUtilityButton: target !== null && target.closest('[data-utility-button]') !== null,
		lineNumber: target?.closest('[data-column-number]')?.getAttribute('data-column-number') ?? null,
		targetTagName: target?.tagName ?? null,
		targetDescription: target?.outerHTML.slice(0, 450) ?? null,
	};
}

export function pointerAt(bounds: DOMRect, pointerId: number): PointerEventInit {
	return {
		clientX: bounds.left + bounds.width / 2,
		clientY: bounds.top + bounds.height / 2,
		pointerId,
		pointerType: 'mouse',
	};
}
