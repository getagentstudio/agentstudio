import {
	CodeView,
	InteractionManager,
	parseDiffFromFile,
	type CodeViewCoordinator,
	type CodeViewLineSelection,
	type CodeViewOptions,
	type SelectedLineRange,
} from '@pierre/diffs';
import { afterEach, describe, expect, test, vi, type MockInstance } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeMainCodeViewItem } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import { BridgeCodeViewPanel } from '../review-viewer/code-view/bridge-code-view-panel.js';
import { buildBridgeReviewProjection } from '../review-viewer/navigation/review-projection.js';
import { RecordingAnnotationBrowserSurface } from './worktree-annotation-browser-test-support.js';
import {
	dispatchPointer,
	pointerAt,
	pointerHitProbe,
	type PointerHitProbe,
} from './worktree-annotation-click-admission-pointer.browser.test-support.js';
import {
	PierreSlotPublicationFacts,
	actEvent,
	observeTestFrameWait,
	proveHeldProductFrameIsolation,
	queryPierreElements,
	waitForPierreCondition,
} from './worktree-annotation-click-admission-render.browser.test-support.js';
import { PierreInteractionSetupFacts } from './worktree-annotation-click-admission-setup.browser.test-support.js';
import { WorktreeAnnotationSurfaceProvider } from './worktree-annotation-surface-provider.js';

const metadataPublicationOwner = vi.hoisted(() => ({
	publish: undefined as ((callback: () => void) => void) | undefined,
}));

vi.mock(
	import('../review-viewer/code-view/bridge-code-view-metadata-apply.js'),
	async (importOriginal) => {
		const metadataOwner = await importOriginal();
		function wrapCompletion(callback: () => void): () => void {
			return (): void => {
				if (metadataPublicationOwner.publish === undefined) callback();
				else metadataPublicationOwner.publish(callback);
			};
		}
		return {
			...metadataOwner,
			runBridgeCodeViewMetadataReconciliationInChunks: (props): void => {
				metadataOwner.runBridgeCodeViewMetadataReconciliationInChunks({
					...props,
					onComplete: wrapCompletion(props.onComplete),
				});
			},
			runBridgeCodeViewMetadataApplyInChunks: (props): void => {
				metadataOwner.runBridgeCodeViewMetadataApplyInChunks({
					...props,
					onComplete: wrapCompletion(props.onComplete),
				});
			},
		} satisfies typeof metadataOwner;
	},
);

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

function requirePierreElement(selector: string, message: string): HTMLElement {
	const element = queryPierreElements(selector)[0];
	if (!(element instanceof HTMLElement)) throw new Error(message);
	return element;
}

async function waitForSinglePierreUtility(): Promise<HTMLElement> {
	await waitForPierreCondition(
		(): boolean => queryPierreElements('[data-utility-button]').length === 1,
	);
	return requirePierreElement('[data-utility-button]', 'Expected one Pierre utility.');
}

describe('worktree annotation click admission through Pierre pointers', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
	});

	test('admits a right-side context-to-addition range on the first plus pointer cycle', async () => {
		const harness = await renderReviewHarness();
		try {
			// Selection reveal/programmatic scroll must not black out the next pointer gesture.
			await actEvent((): void => {
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
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			await harness.dispose();
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
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			await harness.dispose();
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
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			await harness.dispose();
		}
	});

	test('keeps repeated same-range and later new-range plus clicks admissible', async () => {
		const harness = await renderReviewHarness();
		try {
			const additionRow = requirePierreElement(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'Expected a right-side addition gutter row.',
			);
			await harness.hoverAndClickUtility(additionRow, 401);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();

			await clickCurrentUtility(402);
			await harness.waitForComposer(true);
			expect(document.querySelectorAll(composerSelector)).toHaveLength(1);

			await dismissComposer();
			await harness.waitForComposer(false);
			expect(document.querySelector(composerSelector)).toBeNull();

			const contextRow = requirePierreElement(
				'[data-additions] [data-column-number="3"][data-line-type="context"]',
				'Expected a later right-side context gutter row.',
			);
			await harness.hoverAndClickUtility(contextRow, 403);

			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 2, side: 'additions', start: 2 } },
				{ range: { end: 3, side: 'additions', start: 3 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			await harness.dispose();
		}
	});

	test('joins Escape dismissal without waiting for frame delivery', async () => {
		const harness = await renderReviewHarness();
		const heldFrames: FrameRequestCallback[] = [];
		let announceFrame: (() => void) | undefined;
		const frameRequested = new Promise<'frameRequested'>((resolve): void => {
			announceFrame = (): void => resolve('frameRequested');
		});
		let holdingTestFrame = false;
		const requestFrame = globalThis.requestAnimationFrame.bind(globalThis);
		let dismissal: Promise<void> | undefined;
		let frameSpy: MockInstance<typeof requestAnimationFrame> | undefined;
		try {
			const row = requirePierreElement(
				'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
				'Expected an addition row before testing dismissal.',
			);
			await harness.hoverAndClickUtility(row, 601);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
			frameSpy = vi
				.spyOn(globalThis, 'requestAnimationFrame')
				.mockImplementation((callback: FrameRequestCallback): number => {
					if (!holdingTestFrame) return requestFrame(callback);
					holdingTestFrame = false;
					heldFrames.push(callback);
					return heldFrames.length;
				});
			observeTestFrameWait((): void => {
				holdingTestFrame = true;
				announceFrame?.();
			});
			dismissal = dismissComposer();
			const outcome = await Promise.race([
				dismissal.then((): 'dismissed' => 'dismissed'),
				frameRequested,
			]);
			expect(outcome, 'Escape publication must complete without an unrelated frame.').toBe(
				'dismissed',
			);
			await harness.waitForComposer(false);
			expect(document.querySelector(composerSelector)).toBeNull();
		} finally {
			// Release and join the held act even when the regression assertion is red.
			frameSpy?.mockRestore();
			observeTestFrameWait(undefined);
			for (const callback of heldFrames.splice(0)) callback(0);
			await dismissal;
			await actEvent((): void => {
				for (const callback of heldFrames.splice(0)) callback(0);
			});
			await harness.dispose();
		}
	});

	test('disposes its outcome wait with product frames held and leaves later acts admissible', async () => {
		const harness = await renderReviewHarness();
		await proveHeldProductFrameIsolation({
			prepareUtility: async (): Promise<void> => {
				const row = requirePierreElement(
					'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
					'Expected an addition row for the held product frame proof.',
				);
				await harness.interactionSetup.waitForSetup(row);
				await actEvent((): void =>
					dispatchPointer(row, 'pointermove', pointerAt(row.getBoundingClientRect(), 701)),
				);
				await waitForSinglePierreUtility();
			},
			clickUtility: async (): Promise<void> => {
				await clickCurrentUtility(702);
			},
			waitForComposer: (): Promise<void> => harness.waitForComposer(true),
			dispose: (): Promise<void> => harness.dispose(),
		});
	});

	test('awaits interaction setup before its first hover on already-rendered rows', async () => {
		const harness = await renderReviewHarness(true);
		const row = requirePierreElement(
			'[data-additions] [data-column-number="2"][data-line-type="change-addition"]',
			'Expected rendered rows while interaction setup is held.',
		);
		const hover = harness.hoverAndClickUtility(row, 501);
		const firstAction = await harness.interactionSetup.firstHoverAction;
		try {
			expect(
				firstAction,
				'The hover must await its owner setup fact before dispatching a pointer.',
			).toBe('awaitingInteractionSetup');
			harness.interactionSetup.releaseSetup();
			await hover;
			expect(harness.gutterAdmissions).toEqual([
				{ range: { end: 2, side: 'additions', start: 2 } },
			]);
			await harness.waitForComposer(true);
			expect(document.querySelector(composerSelector)).not.toBeNull();
		} finally {
			harness.interactionSetup.releaseSetup();
			// Join the old helper on the red path after proving its first pointer was lost.
			if (firstAction === 'pointerMoveBeforeSetup') {
				await actEvent((): void => {
					dispatchPointer(row, 'pointermove', pointerAt(row.getBoundingClientRect(), 501));
				});
			}
			try {
				await hover;
			} finally {
				await harness.dispose();
			}
		}
	});
});

async function renderReviewHarness(holdInteractionSetup = false): Promise<{
	readonly codeView: CodeView;
	readonly dispose: () => Promise<void>;
	readonly gutterAdmissions: RecordedGutterAdmission[];
	readonly interactionLifecycle: string[];
	readonly interactionSetup: PierreInteractionSetupFacts;
	readonly waitForComposer: (present: boolean) => Promise<void>;
	readonly hoverAndClickUtility: (row: HTMLElement, pointerId: number) => Promise<void>;
}> {
	const gutterAdmissions: RecordedGutterAdmission[] = [];
	const interactionLifecycle: string[] = [];
	const interactionSetup = new PierreInteractionSetupFacts(holdInteractionSetup);
	const slotPublications = new PierreSlotPublicationFacts<
		Parameters<CodeViewCoordinator<undefined>['onSnapshotChange']>[0]
	>();
	metadataPublicationOwner.publish = (callback: () => void): void =>
		slotPublications.publish(callback);
	const outcomeController = new AbortController();
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalSetSlotCoordinator = CodeView.prototype.setSlotCoordinator;
	CodeView.prototype.setSlotCoordinator = function wrapSlotPublication(coordinator): boolean {
		return originalSetSlotCoordinator.call(this, slotPublications.wrap(coordinator));
	};
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
		interactionSetup.install(this, pre, (): void => {
			originalInteractionSetup.call(this, pre);
			interactionLifecycle.push('setup');
		});
	};
	InteractionManager.prototype.cleanUp = function recordInteractionCleanup(): void {
		interactionSetup.retire(this);
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
	await waitForPierreCondition(
		(): boolean =>
			codeViews.length === 1 &&
			queryPierreElements('[data-deletions] [data-column-number]').length >= 3 &&
			queryPierreElements('[data-additions] [data-column-number]').length >= 3,
	);
	await slotPublications.join();
	const codeView = codeViews[0];
	if (codeView === undefined) throw new Error('Expected one mounted Pierre CodeView.');
	return {
		codeView,
		dispose: async (): Promise<void> => {
			outcomeController.abort();
			metadataPublicationOwner.publish = undefined;
			await slotPublications.join();
			CodeView.prototype.setSlotCoordinator = originalSetSlotCoordinator;
			CodeView.prototype.setOptions = originalSetOptions;
			CodeView.prototype.setup = originalCodeViewSetup;
			InteractionManager.prototype.setup = originalInteractionSetup;
			InteractionManager.prototype.cleanUp = originalInteractionCleanup;
			coordinator.dispose();
			interactionSetup.dispose();
		},
		waitForComposer: async (present: boolean): Promise<void> => {
			await waitForPierreCondition(
				(): boolean => (document.querySelector(composerSelector) !== null) === present,
				outcomeController.signal,
			);
			await slotPublications.join();
		},
		gutterAdmissions,
		interactionLifecycle,
		interactionSetup,
		hoverAndClickUtility: async (row: HTMLElement, pointerId: number): Promise<void> => {
			await interactionSetup.waitForSetup(row);
			await hoverAndClickUtility(row, pointerId, (): void => {
				interactionSetup.recordCompletedHover(row);
			});
		},
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
	await actEvent((): void => {
		dispatchPointer(startRow, 'pointerdown', pointerAt(startBounds, pointerId));
	});
	const afterAnchorPublication = interactionLifecycle.slice(lifecycleCountBeforeAnchor);
	const endRowAfterAnchorPublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after anchor publication.',
	);
	const endBounds = endRowAfterAnchorPublication.getBoundingClientRect();
	const movePointerHit = pointerHitProbe(endRowAfterAnchorPublication, endBounds);
	await actEvent((): void => {
		dispatchPointer(endRowAfterAnchorPublication, 'pointermove', pointerAt(endBounds, pointerId));
	});
	const selectionAfterMove = getSelectedLines();
	const endRowAfterRangePublication = requirePierreElement(
		endSelector,
		'Expected the drag endpoint after range publication.',
	);
	const finalEndBounds = endRowAfterRangePublication.getBoundingClientRect();
	await actEvent((): void => {
		dispatchPointer(endRowAfterRangePublication, 'pointerup', pointerAt(finalEndBounds, pointerId));
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

async function hoverAndClickUtility(
	row: HTMLElement,
	pointerId: number,
	onHoverDispatched: () => void,
): Promise<void> {
	const bounds = row.getBoundingClientRect();
	await actEvent((): void => {
		dispatchPointer(row, 'pointermove', pointerAt(bounds, pointerId));
	});
	onHoverDispatched();
	await waitForSinglePierreUtility();
	await clickCurrentUtility(pointerId + 1);
}

async function dismissComposer(): Promise<void> {
	await actEvent((): void => {
		document.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
	});
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
	await actEvent((): void => {
		dispatchPointer(utility, 'pointerdown', pointerAt(bounds, pointerId));
	});
	const utilityAfterPointerDownPublication = requirePierreElement(
		'[data-utility-button]',
		'Expected Pierre to retain its gutter utility after pointerdown publication.',
	);
	const finalBounds = utilityAfterPointerDownPublication.getBoundingClientRect();
	const utilityPointerUpHit = pointerHitProbe(utilityAfterPointerDownPublication, finalBounds);
	await actEvent((): void => {
		dispatchPointer(
			utilityAfterPointerDownPublication,
			'pointerup',
			pointerAt(finalBounds, pointerId),
		);
	});
	return { utilityPointerDownHit, utilityPointerUpHit };
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
