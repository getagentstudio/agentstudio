import {
	CodeView,
	InteractionManager,
	parseDiffFromFile,
	type CodeViewLineSelection,
	type CodeViewOptions,
	type SelectedLineRange,
} from '@pierre/diffs';
import { act } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeMainCodeViewItem } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import { BridgeCodeViewPanel } from '../review-viewer/code-view/bridge-code-view-panel.js';
import { buildBridgeReviewProjection } from '../review-viewer/navigation/review-projection.js';
import { RecordingAnnotationBrowserSurface } from './worktree-annotation-browser-test-support.js';
import { WorktreeAnnotationSurfaceProvider } from './worktree-annotation-surface-provider.js';

const composerSelector = '[aria-label="Write an annotation in Markdown"]';

interface RecordedGutterAdmission {
	readonly range: SelectedLineRange;
}

function recordGutterAdmissions(
	options: CodeViewOptions<undefined>,
	recordings: RecordedGutterAdmission[],
): CodeViewOptions<undefined> {
	const onGutterUtilityClick = options.onGutterUtilityClick;
	return {
		...options,
		onGutterUtilityClick: (range, context): void => {
			recordings.push({ range: { ...range } });
			if (context.type === 'file') onGutterUtilityClick?.(range, context);
			else onGutterUtilityClick?.(range, context);
		},
	};
}

function queryPierreElements(selector: string): Element[] {
	const elements: Element[] = [];
	const pendingRoots: ParentNode[] = [document];
	while (pendingRoots.length > 0) {
		const root = pendingRoots.shift();
		if (root === undefined) break;
		elements.push(...root.querySelectorAll(selector));
		for (const candidate of root.querySelectorAll('*')) {
			if (candidate.shadowRoot !== null) pendingRoots.push(candidate.shadowRoot);
		}
	}
	return elements;
}

function requirePierreElement(selector: string, message: string): HTMLElement {
	const element = queryPierreElements(selector)[0];
	if (!(element instanceof HTMLElement)) throw new Error(message);
	return element;
}

function dispatchPointer(
	target: EventTarget,
	type: 'pointerdown' | 'pointermove' | 'pointerup',
	init: PointerEventInit,
): void {
	target.dispatchEvent(
		new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }),
	);
}

async function nextAnimationFrame(): Promise<void> {
	await new Promise<void>((resolve): void => {
		requestAnimationFrame((): void => resolve());
	});
}

async function waitForSinglePierreUtility(): Promise<HTMLElement> {
	return await new Promise<HTMLElement>((resolve): void => {
		const observedRoots = new Set<Node>();

		function observeOpenShadowRoots(): void {
			const roots: ParentNode[] = [document];
			while (roots.length > 0) {
				const root = roots.shift();
				if (root === undefined) break;
				if (!observedRoots.has(root)) {
					observedRoots.add(root);
					observer.observe(root, { childList: true, subtree: true });
				}
				for (const candidate of root.querySelectorAll('*')) {
					if (candidate.shadowRoot !== null) roots.push(candidate.shadowRoot);
				}
			}
		}

		function resolveWhenUtilityAppears(): void {
			observeOpenShadowRoots();
			const utilities = queryPierreElements('[data-utility-button]');
			const utility = utilities[0];
			if (utilities.length !== 1 || !(utility instanceof HTMLElement)) return;
			observer.disconnect();
			resolve(utility);
		}

		const observer = new MutationObserver(resolveWhenUtilityAppears);
		resolveWhenUtilityAppears();
	});
}

async function settleBrowserCondition(
	predicate: () => boolean,
	failureMessage: string,
	remainingFrames = 60,
): Promise<void> {
	for (let remaining = remainingFrames; remaining > 0; remaining -= 1) {
		if (predicate()) return;
		await nextAnimationFrame();
	}
	throw new Error(failureMessage);
}

describe('worktree annotation click admission through Pierre pointers', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
	});

	test('admits a right-side context-to-addition range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		try {
			// Selection reveal/programmatic scroll must not black out the next pointer gesture.
			await act(async (): Promise<void> => {
				harness.codeView.scrollTo({ type: 'position', position: 0, behavior: 'instant' });
			});
			const gesture = await dragRangeAndClickFirstUtility(
				'[data-additions] [data-column-number="1"][data-line-type="context"]',
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				101,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(gesture.afterAnchorPublication).not.toContain('cleanup');
			expect(gesture.movePointerHit.lineNumber).toBe('2');
			expect(gesture.selectionAfterMove?.range).toEqual({
				end: 2,
				side: 'additions',
				start: 1,
			});
			expect(gesture.selectionAfterPointerUp?.range).toEqual({
				end: 2,
				side: 'additions',
				start: 1,
			});
			expect(gesture.utilityPointerDownHit.lineNumber).toBe('2');
			expect(gesture.utilityPointerUpHit.lineNumber).toBe('2');
			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 1 } },
			]);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			harness.dispose();
		}
	});

	test('admits a left-side context-to-deletion range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		try {
			await dragRangeAndClickFirstUtility(
				'[data-deletions] [data-column-number="1"][data-line-type="context"]',
				'[data-deletions] [data-column-number="2"][data-line-type="change-deletion"]',
				201,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'deletions', start: 1 } },
			]);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			harness.dispose();
		}
	});

	test('admits a backward right-side addition-to-context range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		try {
			await dragRangeAndClickFirstUtility(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'[data-additions] [data-column-number="1"][data-line-type="context"]',
				251,
				harness.interactionLifecycle,
				(): CodeViewLineSelection | null => harness.codeView.getSelectedLines(),
			);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 1 } },
			]);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			harness.dispose();
		}
	});

	test('keeps repeated same-range and later new-range plus clicks admissible', async () => {
		const harness = await renderReviewHarness();
		try {
			const additionRow = requirePierreElement(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'Expected a right-side addition gutter row.',
			);
			await hoverAndClickUtility(additionRow, 401);
			expect(document.querySelector(composerSelector)).not.toBeNull();

			await clickCurrentUtility(402);
			expect(document.querySelectorAll(composerSelector)).toHaveLength(1);

			await act(async (): Promise<void> => {
				document.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
				await nextAnimationFrame();
			});
			expect(document.querySelector(composerSelector)).toBeNull();

			const contextRow = requirePierreElement(
				'[data-additions] [data-column-number="3"][data-line-type="context"]',
				'Expected a later right-side context gutter row.',
			);
			await hoverAndClickUtility(contextRow, 403);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 3, side: 'additions', start: 3 } },
			]);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			harness.dispose();
		}
	});
});

async function renderReviewHarness(): Promise<{
	readonly codeView: CodeView;
	readonly dispose: () => void;
	readonly gutterAdmissions: RecordedGutterAdmission[];
	readonly interactionLifecycle: string[];
}> {
	const gutterAdmissions: RecordedGutterAdmission[] = [];
	const interactionLifecycle: string[] = [];
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalSetOptions = CodeView.prototype.setOptions;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalCodeViewSetup = CodeView.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalInteractionSetup = InteractionManager.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalInteractionCleanup = InteractionManager.prototype.cleanUp;
	CodeView.prototype.setOptions = function captureGutterAdmission(
		options: CodeViewOptions<undefined>,
	): void {
		originalSetOptions.call(this, recordGutterAdmissions(options, gutterAdmissions));
	};
	const codeViews: CodeView[] = [];
	CodeView.prototype.setup = function captureCodeView(root: HTMLElement): void {
		codeViews.push(this);
		originalCodeViewSetup.call(this, root);
	};
	InteractionManager.prototype.setup = function recordInteractionSetup(pre: HTMLPreElement): void {
		interactionLifecycle.push('setup');
		originalInteractionSetup.call(this, pre);
	};
	InteractionManager.prototype.cleanUp = function recordInteractionCleanup(): void {
		interactionLifecycle.push('cleanup');
		originalInteractionCleanup.call(this);
	};
	const surface = new RecordingAnnotationBrowserSurface('review');
	const reviewPackage = makeBridgeReviewPackage();
	const projection = buildBridgeReviewProjection({
		reviewPackage,
		request: { facets: [], mode: { kind: 'normalReview' } },
	});
	const coordinator = createBridgeMainRenderFulfillmentCoordinator({
		sendDisposition: (): void => {},
	});
	const reviewItem = makeReviewItem();
	await render(
		<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
			<div style={{ height: 600, width: 1200 }}>
				<BridgeCodeViewPanel
					presentationPositionKey="annotation-click-admission"
					projection={projection}
					renderFulfillmentCoordinator={coordinator}
					reviewPackage={reviewPackage}
					selectedCodeViewItem={reviewItem}
					selectedItemId="item-source"
					visibleCodeViewItems={[reviewItem]}
					workerPoolEnabled={false}
				/>
			</div>
		</WorktreeAnnotationSurfaceProvider>,
	);
	await settleBrowserCondition(
		(): boolean =>
			codeViews.length === 1 &&
			queryPierreElements('[data-deletions] [data-column-number]').length >= 3 &&
			queryPierreElements('[data-additions] [data-column-number]').length >= 3,
		'Expected Pierre split Review rows.',
	);
	const codeView = codeViews[0];
	if (codeView === undefined) throw new Error('Expected one mounted Pierre CodeView.');
	return {
		codeView,
		dispose: (): void => {
			CodeView.prototype.setOptions = originalSetOptions;
			CodeView.prototype.setup = originalCodeViewSetup;
			InteractionManager.prototype.setup = originalInteractionSetup;
			InteractionManager.prototype.cleanUp = originalInteractionCleanup;
			coordinator.dispose();
		},
		gutterAdmissions,
		interactionLifecycle,
	};
}

async function dragRangeAndClickFirstUtility(
	startSelector: string,
	endSelector: string,
	pointerId: number,
	interactionLifecycle: string[],
	getSelectedLines: () => CodeViewLineSelection | null,
): Promise<{
	readonly afterAnchorPublication: readonly string[];
	readonly selectionAfterMove: CodeViewLineSelection | null;
	readonly selectionAfterPointerUp: CodeViewLineSelection | null;
	readonly movePointerHit: PointerHitProbe;
	readonly utilityPointerDownHit: PointerHitProbe;
	readonly utilityPointerUpHit: PointerHitProbe;
}> {
	const startRow = requirePierreElement(startSelector, 'Expected the drag anchor gutter row.');
	const startBounds = startRow.getBoundingClientRect();
	const lifecycleCountBeforeAnchor = interactionLifecycle.length;
	await act(async (): Promise<void> => {
		dispatchPointer(startRow, 'pointerdown', pointerAt(startBounds, pointerId));
		await nextAnimationFrame();
	});
	const afterAnchorPublication = interactionLifecycle.slice(lifecycleCountBeforeAnchor);
	const endRowAfterAnchorPublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after anchor publication.',
	);
	const endBounds = endRowAfterAnchorPublication.getBoundingClientRect();
	const movePointerHit = pointerHitProbe(endRowAfterAnchorPublication, endBounds);
	await act(async (): Promise<void> => {
		dispatchPointer(endRowAfterAnchorPublication, 'pointermove', pointerAt(endBounds, pointerId));
		await nextAnimationFrame();
	});
	const selectionAfterMove = getSelectedLines();
	const endRowAfterRangePublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after range publication.',
	);
	const finalEndBounds = endRowAfterRangePublication.getBoundingClientRect();
	await act(async (): Promise<void> => {
		dispatchPointer(endRowAfterRangePublication, 'pointerup', pointerAt(finalEndBounds, pointerId));
		await nextAnimationFrame();
	});
	const selectionAfterPointerUp = getSelectedLines();
	const utilityGesture = await clickCurrentUtility(pointerId + 1);
	return {
		afterAnchorPublication,
		movePointerHit,
		selectionAfterMove,
		selectionAfterPointerUp,
		...utilityGesture,
	};
}

async function hoverAndClickUtility(row: HTMLElement, pointerId: number): Promise<void> {
	const bounds = row.getBoundingClientRect();
	await act(async (): Promise<void> => {
		dispatchPointer(row, 'pointermove', pointerAt(bounds, pointerId));
	});
	await waitForSinglePierreUtility();
	await clickCurrentUtility(pointerId + 1);
}

async function clickCurrentUtility(pointerId: number): Promise<{
	readonly utilityPointerDownHit: PointerHitProbe;
	readonly utilityPointerUpHit: PointerHitProbe;
}> {
	const utility = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to expose one gutter utility.',
	);
	const bounds = utility.getBoundingClientRect();
	const utilityPointerDownHit = pointerHitProbe(utility, bounds);
	await act(async (): Promise<void> => {
		dispatchPointer(utility, 'pointerdown', pointerAt(bounds, pointerId));
		await nextAnimationFrame();
	});
	const utilityAfterPointerDownPublication = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to retain its gutter utility after pointerdown publication.',
	);
	const finalBounds = utilityAfterPointerDownPublication.getBoundingClientRect();
	const utilityPointerUpHit = pointerHitProbe(utilityAfterPointerDownPublication, finalBounds);
	await act(async (): Promise<void> => {
		dispatchPointer(
			utilityAfterPointerDownPublication,
			'pointerup',
			pointerAt(finalBounds, pointerId),
		);
		await nextAnimationFrame();
	});
	return { utilityPointerDownHit, utilityPointerUpHit };
}

interface PointerHitProbe {
	readonly bounds: string;
	readonly hitUtilityButton: boolean;
	readonly lineNumber: string | null;
	readonly targetTagName: string | null;
	readonly targetDescription: string | null;
}

function pointerHitProbe(utility: HTMLElement, bounds: DOMRect): PointerHitProbe {
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

function pointerAt(bounds: DOMRect, pointerId: number): PointerEventInit {
	return {
		clientX: bounds.left + bounds.width / 2,
		clientY: bounds.top + bounds.height / 2,
		pointerId,
		pointerType: 'mouse',
	};
}

function makeReviewItem(): BridgeMainCodeViewItem {
	const baseContents = ['let stable = 1', 'let reviewed = "before"', 'let tail = 3'].join('\n');
	const headContents = ['let stable = 1', 'let reviewed = "after"', 'let tail = 3'].join('\n');
	return {
		bridgeMetadata: {
			cacheKey: 'review-base|review-head',
			contentRoles: ['base', 'head'],
			contentState: 'hydrated',
			displayPath: 'Sources/App/View.swift',
			itemId: 'item-source',
			lineCount: 3,
			sourceDescriptorIdsByRole: {
				base: 'handle-item-source-base',
				diff: null,
				file: null,
				head: 'handle-item-source-head',
			},
		},
		fileDiff: parseDiffFromFile(
			{ cacheKey: 'review-base', contents: baseContents, name: 'Sources/App/View.swift' },
			{ cacheKey: 'review-head', contents: headContents, name: 'Sources/App/View.swift' },
		),
		id: 'item-source',
		type: 'diff',
		version: 1,
	};
}
