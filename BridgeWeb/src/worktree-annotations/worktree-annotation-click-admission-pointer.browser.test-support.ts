import {
	actEvent,
	queryPierreElements,
	waitForPierreCondition,
} from './worktree-annotation-click-admission-render.browser.test-support.js';
import {
	ClickAdmissionResourceOwner,
	type ClickAdmissionResourceGroup,
} from './worktree-annotation-click-admission-resource-owner.browser.test-support.js';

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
export function requirePierreElement(selector: string, message: string): HTMLElement {
	const element = queryPierreElements(selector)[0];
	if (!(element instanceof HTMLElement)) throw new Error(message);
	return element;
}

export async function waitForSinglePierreUtility(
	resources: ClickAdmissionResourceOwner,
	group: ClickAdmissionResourceGroup,
): Promise<HTMLElement> {
	await waitForPierreCondition({
		predicate: (): boolean => queryPierreElements('[data-utility-button]').length === 1,
		resources,
		group,
	});
	return requirePierreElement('[data-utility-button]', 'Expected one Pierre utility.');
}

export function pierreRowSelector(row: HTMLElement): string {
	const lineNumber = row.getAttribute('data-column-number');
	const lineType = row.getAttribute('data-line-type');
	const side = row.closest('[data-additions]') !== null ? 'additions' : 'deletions';
	if (lineNumber === null || lineType === null) throw new Error('Expected a Pierre row identity.');
	return `[data-${side}] [data-column-number="${CSS.escape(lineNumber)}"][data-line-type="${CSS.escape(lineType)}"]`;
}

export async function hoverAndClickUtility(props: {
	readonly resolveRow: () => HTMLElement;
	readonly isRowReady: (row: HTMLElement) => boolean;
	readonly pointerId: number;
	readonly onHoverDispatched: (row: HTMLElement) => void;
	readonly resources: ClickAdmissionResourceOwner;
	readonly group: ClickAdmissionResourceGroup;
	readonly reportWait?: (kind: string) => void;
}): Promise<void> {
	props.reportWait?.('hover pointermove act');
	await actEvent(props.resources, props.group, (): void => {
		// Reconciliation may retire the pre across any preceding await. Resolve and
		// validate the current pointer target without yielding before dispatch.
		const currentRow = props.resolveRow();
		if (!currentRow.isConnected || !props.isRowReady(currentRow)) {
			throw new Error(
				`Pierre hover ${props.pointerId} target is detached or its current setup is not ready.`,
			);
		}
		dispatchPointer(
			currentRow,
			'pointermove',
			pointerAt(currentRow.getBoundingClientRect(), props.pointerId),
		);
		props.onHoverDispatched(currentRow);
	});
	props.reportWait?.('gutter utility appearance');
	await waitForSinglePierreUtility(props.resources, props.group);
	await clickCurrentUtility(props.resources, props.pointerId + 1, props.reportWait);
	props.reportWait?.('idle');
}

export async function clickCurrentUtility(
	resources: ClickAdmissionResourceOwner,
	pointerId: number,
	reportWait?: (kind: string) => void,
): Promise<{
	readonly utilityPointerDownHit: PointerHitProbe;
	readonly utilityPointerUpHit: PointerHitProbe;
}> {
	const group = resources.createGroup('utility event acts');
	const utility = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to expose one gutter utility.',
	);
	const bounds = utility.getBoundingClientRect();
	const utilityPointerDownHit = pointerHitProbe(utility, bounds);
	reportWait?.('utility pointerdown act');
	await actEvent(resources, group, (): void => {
		dispatchPointer(utility, 'pointerdown', pointerAt(bounds, pointerId));
	});
	const utilityAfterPointerDownPublication = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to retain its gutter utility after pointerdown publication.',
	);
	const finalBounds = utilityAfterPointerDownPublication.getBoundingClientRect();
	const utilityPointerUpHit = pointerHitProbe(utilityAfterPointerDownPublication, finalBounds);
	reportWait?.('utility pointerup act');
	await actEvent(resources, group, (): void => {
		dispatchPointer(
			utilityAfterPointerDownPublication,
			'pointerup',
			pointerAt(finalBounds, pointerId),
		);
	});
	return { utilityPointerDownHit, utilityPointerUpHit };
}
