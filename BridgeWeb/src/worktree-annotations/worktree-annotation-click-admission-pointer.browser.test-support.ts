import {
	actEvent,
	queryPierreElements,
	waitForPierreCondition,
} from './worktree-annotation-click-admission-render.browser.test-support.js';

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

export async function waitForSinglePierreUtility(signal: AbortSignal): Promise<HTMLElement> {
	await waitForPierreCondition(
		(): boolean => queryPierreElements('[data-utility-button]').length === 1,
		signal,
	);
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
	readonly signal: AbortSignal;
	readonly reportWait?: (kind: string) => void;
	readonly observeRetirement: (row: HTMLElement) => {
		readonly promise: Promise<void>;
		readonly dispose: () => void;
	};
	readonly waitForCurrentSetup: (row: HTMLElement) => Promise<void>;
	readonly waitForReplacementRow: () => Promise<void>;
}): Promise<void> {
	// Every continuation here is caused by utility appearance or a distinct observed pre retirement.
	while (true) {
		const currentRow = props.resolveRow();
		await props.waitForCurrentSetup(currentRow);
		const retirement = props.observeRetirement(currentRow);
		const utilityWaitController = new AbortController();
		const abortUtilityWait = (): void => utilityWaitController.abort();
		props.signal.addEventListener('abort', abortUtilityWait, { once: true });
		if (props.signal.aborted) abortUtilityWait();
		let utilityOutcome: Promise<'utility'> | undefined;
		try {
			props.reportWait?.('hover pointermove act');
			await actEvent((): void => {
				const target = props.resolveRow();
				if (target !== currentRow || !target.isConnected || !props.isRowReady(target)) {
					throw new Error(`Pierre hover ${props.pointerId} target changed before dispatch.`);
				}
				dispatchPointer(
					target,
					'pointermove',
					pointerAt(target.getBoundingClientRect(), props.pointerId),
				);
				props.onHoverDispatched(target);
			});
			props.reportWait?.('gutter utility appearance or hovered pre retirement');
			utilityOutcome = waitForSinglePierreUtility(utilityWaitController.signal).then(
				(): 'utility' => 'utility',
			);
			const outcome = await Promise.race([
				utilityOutcome,
				retirement.promise.then((): 'retired' => 'retired'),
			]);
			if (outcome === 'retired' || !currentRow.isConnected || !props.isRowReady(currentRow)) {
				props.reportWait?.('replacement pre setup after observed hover retirement');
				await props.waitForReplacementRow();
				continue;
			}
			await clickCurrentUtility(props.pointerId + 1, props.reportWait);
			props.reportWait?.('idle');
			return;
		} finally {
			retirement.dispose();
			utilityWaitController.abort();
			props.signal.removeEventListener('abort', abortUtilityWait);
			await utilityOutcome?.catch((): void => {});
		}
	}
}

export async function clickCurrentUtility(
	pointerId: number,
	reportWait?: (kind: string) => void,
): Promise<{
	readonly utilityPointerDownHit: PointerHitProbe;
	readonly utilityPointerUpHit: PointerHitProbe;
}> {
	const utility = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to expose one gutter utility.',
	);
	const bounds = utility.getBoundingClientRect();
	const utilityPointerDownHit = pointerHitProbe(utility, bounds);
	reportWait?.('utility pointerdown act');
	await actEvent((): void => {
		dispatchPointer(utility, 'pointerdown', pointerAt(bounds, pointerId));
	});
	const utilityAfterPointerDownPublication = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to retain its gutter utility after pointerdown publication.',
	);
	const finalBounds = utilityAfterPointerDownPublication.getBoundingClientRect();
	const utilityPointerUpHit = pointerHitProbe(utilityAfterPointerDownPublication, finalBounds);
	reportWait?.('utility pointerup act');
	await actEvent((): void => {
		dispatchPointer(
			utilityAfterPointerDownPublication,
			'pointerup',
			pointerAt(finalBounds, pointerId),
		);
	});
	return { utilityPointerDownHit, utilityPointerUpHit };
}
