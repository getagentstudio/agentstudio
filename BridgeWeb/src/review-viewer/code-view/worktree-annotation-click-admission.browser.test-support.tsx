import {
	CodeView,
	InteractionManager,
	parseDiffFromFile,
	type CodeViewCoordinator,
	type CodeViewOptions,
	type SelectedLineRange,
} from '@pierre/diffs';
import { expect } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeMainCodeViewItem } from '../../core/comm-worker/bridge-main-render-snapshot-store.js';
import { makeBridgeReviewPackage } from '../../foundation/review-package/bridge-review-package-test-support.js';
import { RecordingAnnotationBrowserSurface } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import { runWithOwnedCleanup } from '../../worktree-annotations/worktree-annotation-click-admission-cleanup.browser.test-support.js';
import {
	hoverAndClickUtility,
	waitForSinglePierreUtility,
	pierreRowSelector,
	requirePierreElement,
} from '../../worktree-annotations/worktree-annotation-click-admission-pointer.browser.test-support.js';
import {
	PierreSlotPublicationFacts,
	actEvent,
	queryPierreElements,
	waitForPierreCondition,
} from '../../worktree-annotations/worktree-annotation-click-admission-render.browser.test-support.js';
import { ClickAdmissionResourceOwner } from '../../worktree-annotations/worktree-annotation-click-admission-resource-owner.browser.test-support.js';
import { PierreInteractionSetupFacts } from '../../worktree-annotations/worktree-annotation-click-admission-setup.browser.test-support.js';
import { WorktreeAnnotationSurfaceProvider } from '../../worktree-annotations/worktree-annotation-surface-provider.js';
import { buildBridgeReviewProjection } from '../navigation/review-projection.js';
import { BridgeCodeViewPanel } from './bridge-code-view-panel.js';

const composerSelector = '[aria-label="Write an annotation in Markdown"]';

interface ClickAdmissionHarnessProps {
	readonly holdInteractionSetup?: boolean;
	readonly isInitialReadinessReleased?: () => boolean;
	readonly recordInitialReadinessObserver?: (observer: MutationObserver) => void;
	readonly afterSetupBeforeHover?: ((codeView: CodeView) => void) | undefined;
	readonly beforeRender?: (() => void) | undefined;
	readonly metadataPublicationOwner: { publish: ((callback: () => void) => void) | undefined };
	readonly resources: ClickAdmissionResourceOwner;
	readonly recordDisposer?: ((dispose: () => Promise<void>) => void) | undefined;
	readonly registerFailureDiagnostic: (readSnapshot: () => object) => void;
}
export interface ClickAdmissionReviewHarness {
	readonly publishForProof: (callback: () => void) => void;
	readonly recordPendingWait: (kind: string) => void;
	readonly runEvent: (callback: () => void) => Promise<void>;
	readonly codeView: CodeView;
	readonly dispose: () => Promise<void>;
	readonly gutterAdmissions: RecordedGutterAdmission[];
	readonly interactionLifecycle: string[];
	readonly interactionSetup: PierreInteractionSetupFacts;
	readonly waitForUtility: () => Promise<HTMLElement>;
	readonly waitForInteractionSetup: (row: HTMLElement) => Promise<void>;
	readonly waitForComposer: (present: boolean) => Promise<void>;
	readonly hoverAndClickUtility: (row: HTMLElement, pointerId: number) => Promise<void>;
}

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

export async function createClickAdmissionReviewHarness(
	props: ClickAdmissionHarnessProps,
): Promise<ClickAdmissionReviewHarness> {
	const gutterAdmissions: RecordedGutterAdmission[] = [];
	const interactionLifecycle: string[] = [];
	const group = props.resources.createGroup('Review harness');
	const dispose = (): Promise<void> => props.resources.releaseGroup(group);
	props.recordDisposer?.(dispose);
	const interactionSetup = new PierreInteractionSetupFacts(
		props.holdInteractionSetup ?? false,
		props.resources,
		group,
	);
	const slotPublications = new PierreSlotPublicationFacts<
		Parameters<CodeViewCoordinator<undefined>['onSnapshotChange']>[0]
	>(props.resources, group);
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalSetSlotCoordinator = CodeView.prototype.setSlotCoordinator;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalSetOptions = CodeView.prototype.setOptions;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalCodeViewSetup = CodeView.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalInteractionSetup = InteractionManager.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Restored below; invoked with its original receiver.
	const originalInteractionCleanup = InteractionManager.prototype.cleanUp;
	let pendingWait = 'harness setup';
	let lastPointerId: number | null = null;
	let lastRow: HTMLElement | undefined;
	const readSnapshot = (): object => ({
		pendingWait,
		pointerId: lastPointerId,
		line: lastRow?.getAttribute('data-column-number') ?? null,
		lineType: lastRow?.getAttribute('data-line-type') ?? null,
		rowConnected: lastRow?.isConnected ?? null,
		rowSetupReady: lastRow === undefined ? null : interactionSetup.isReady(lastRow),
		utilityCount: queryPierreElements('[data-utility-button]').length,
		composerCount: document.querySelectorAll(composerSelector).length,
		selectedLines: codeViews[0]?.getSelectedLines() ?? null,
		gutterAdmissions: [...gutterAdmissions],
	});
	let disposalSnapshot: object | undefined;
	const codeViews: CodeView[] = [];
	let coordinator: ReturnType<typeof createBridgeMainRenderFulfillmentCoordinator> | undefined;
	try {
		props.registerFailureDiagnostic((): object => disposalSnapshot ?? readSnapshot());
		props.resources.patch({
			group,
			label: 'metadata publication adapter',
			target: props.metadataPublicationOwner,
			key: 'publish',
			value: (callback: () => void): void => slotPublications.publish(callback),
		});
		props.resources.patch({
			group,
			label: 'CodeView.prototype.setSlotCoordinator',
			target: CodeView.prototype,
			key: 'setSlotCoordinator',
			value: function wrapSlotPublication(this: CodeView, slotCoordinator): boolean {
				return originalSetSlotCoordinator.call(this, slotPublications.wrap(slotCoordinator));
			},
		});
		props.resources.patch({
			group,
			label: 'CodeView.prototype.setOptions',
			target: CodeView.prototype,
			key: 'setOptions',
			value: function captureGutterAdmission(options: CodeViewOptions<undefined>): void {
				originalSetOptions.call(this, recordGutterAdmissions(options, gutterAdmissions));
			},
		});
		props.resources.patch({
			group,
			label: 'CodeView.prototype.setup',
			target: CodeView.prototype,
			key: 'setup',
			value: function captureCodeView(this: CodeView, root: HTMLElement): void {
				codeViews.push(this);
				originalCodeViewSetup.call(this, root);
			},
		});
		props.resources.patch({
			group,
			label: 'InteractionManager.prototype.setup',
			target: InteractionManager.prototype,
			key: 'setup',
			value: function recordInteractionSetup(
				this: typeof InteractionManager.prototype,
				pre: HTMLPreElement,
			): void {
				interactionSetup.install(this, pre, (): void => {
					originalInteractionSetup.call(this, pre);
					interactionLifecycle.push('setup');
				});
			},
		});
		props.resources.patch({
			group,
			label: 'InteractionManager.prototype.cleanUp',
			target: InteractionManager.prototype,
			key: 'cleanUp',
			value: function recordInteractionCleanup(this: typeof InteractionManager.prototype): void {
				interactionSetup.retire(this);
				interactionLifecycle.push('cleanup');
				originalInteractionCleanup.call(this);
			},
		});
		const surface = new RecordingAnnotationBrowserSurface('review');
		const reviewPackage = makeBridgeReviewPackage();
		const projection = buildBridgeReviewProjection({
			reviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (): void => {},
		});
		props.resources.register({
			group,
			kind: 'root',
			label: 'render fulfillment coordinator',
			restore: (): void => coordinator?.dispose(),
		});
		props.resources.register({
			group,
			kind: 'root',
			label: 'React mounted roots and component timers/frames',
			restore: cleanup,
		});
		props.resources.register({
			group,
			kind: 'root',
			label: 'freeze pre-unmount diagnostics',
			restore: (): void => {
				disposalSnapshot = readSnapshot();
			},
		});
		const mountedCoordinator = coordinator;
		const reviewItem = makeReviewItem();
		props.beforeRender?.();
		await props.resources.track({
			group,
			label: 'React mount act',
			start: () =>
				render(
					<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
						<div style={{ height: 600, width: 1200 }}>
							<BridgeCodeViewPanel
								presentationPositionKey="annotation-click-admission"
								projection={projection}
								renderFulfillmentCoordinator={mountedCoordinator}
								reviewPackage={reviewPackage}
								selectedCodeViewItem={reviewItem}
								selectedItemId="item-source"
								visibleCodeViewItems={[reviewItem]}
								workerPoolEnabled={false}
							/>
						</div>
					</WorktreeAnnotationSurfaceProvider>,
				),
		});
		pendingWait = 'Pierre split rows';
		await waitForPierreCondition({
			predicate: (): boolean =>
				codeViews.length === 1 &&
				queryPierreElements('[data-deletions] [data-column-number]').length >= 3 &&
				queryPierreElements('[data-additions] [data-column-number]').length >= 3 &&
				(props.isInitialReadinessReleased?.() ?? true),
			resources: props.resources,
			group,
			recordObserver: props.recordInitialReadinessObserver,
		});
		pendingWait = 'initial publication join';
		await slotPublications.join();
		pendingWait = 'idle';
		const codeView = codeViews[0];
		if (codeView === undefined) throw new Error('Expected one mounted Pierre CodeView.');
		return {
			publishForProof: (callback: () => void): void => slotPublications.publish(callback),
			codeView,
			runEvent: (callback: () => void): Promise<void> => actEvent(props.resources, group, callback),
			recordPendingWait: (kind: string): void => {
				pendingWait = kind;
			},
			dispose,
			waitForUtility: (): Promise<HTMLElement> => {
				pendingWait = 'preparation gutter utility appearance';
				return waitForSinglePierreUtility(props.resources, group);
			},
			waitForInteractionSetup: (row: HTMLElement): Promise<void> => {
				pendingWait = 'preparation interaction setup';
				lastRow = row;
				return interactionSetup.waitForSetup(row);
			},
			waitForComposer: async (present: boolean): Promise<void> => {
				pendingWait = present ? 'composer appearance' : 'composer dismissal';
				await waitForPierreCondition({
					predicate: (): boolean => (document.querySelector(composerSelector) !== null) === present,
					resources: props.resources,
					group,
				});
				pendingWait = 'publication join after composer';
				await slotPublications.join();
				pendingWait = 'idle';
			},
			gutterAdmissions,
			interactionLifecycle,
			interactionSetup,
			hoverAndClickUtility: async (row: HTMLElement, pointerId: number): Promise<void> => {
				const selector = pierreRowSelector(row);
				lastRow = row;
				lastPointerId = pointerId;
				pendingWait = 'interaction setup';
				await interactionSetup.waitForSetup(row);
				if (props.afterSetupBeforeHover !== undefined) {
					await actEvent(props.resources, group, (): void =>
						props.afterSetupBeforeHover?.(codeView),
					);
				}
				pendingWait = 'current hover row appearance';
				await waitForPierreCondition({
					predicate: (): boolean => queryPierreElements(selector).length === 1,
					resources: props.resources,
					group,
				});
				const currentRow = requirePierreElement(
					selector,
					`Expected the current row for hover ${pointerId}.`,
				);
				lastRow = currentRow;
				pendingWait = 'current hover row interaction setup';
				await interactionSetup.waitForSetup(currentRow);
				await hoverAndClickUtility({
					resolveRow: (): HTMLElement => {
						lastRow = requirePierreElement(
							selector,
							`Expected the current row for hover ${pointerId}.`,
						);
						return lastRow;
					},
					isRowReady: (dispatchRow): boolean => interactionSetup.isReady(dispatchRow),
					pointerId,
					onHoverDispatched: (dispatchedRow): void => {
						lastRow = dispatchedRow;
						interactionSetup.recordCompletedHover(dispatchedRow);
					},
					resources: props.resources,
					group,
					reportWait: (kind): void => {
						pendingWait = kind;
					},
				});
			},
		};
	} catch (setupError) {
		return await runWithOwnedCleanup(async (): Promise<ClickAdmissionReviewHarness> => {
			throw setupError;
		}, dispose);
	}
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

export function captureClickAdmissionOriginals(
	metadataPublicationOwner: ClickAdmissionHarnessProps['metadataPublicationOwner'],
): {
	readonly assertRestored: () => void;
} {
	// oxlint-disable-next-line unbound-method -- Identity receipt; never invoked unbound.
	const setSlotCoordinator = CodeView.prototype.setSlotCoordinator;
	// oxlint-disable-next-line unbound-method -- Identity receipt; never invoked unbound.
	const setOptions = CodeView.prototype.setOptions;
	// oxlint-disable-next-line unbound-method -- Identity receipt; never invoked unbound.
	const codeViewSetup = CodeView.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Identity receipt; never invoked unbound.
	const interactionSetup = InteractionManager.prototype.setup;
	// oxlint-disable-next-line unbound-method -- Identity receipt; never invoked unbound.
	const interactionCleanup = InteractionManager.prototype.cleanUp;
	const metadataPublication = metadataPublicationOwner.publish;
	const requestFrame = globalThis.requestAnimationFrame;
	const cancelFrame = globalThis.cancelAnimationFrame;
	return {
		assertRestored: (): void => {
			// oxlint-disable-next-line unbound-method -- Compares method identity; never invoked.
			expect.soft(CodeView.prototype.setSlotCoordinator).toBe(setSlotCoordinator);
			// oxlint-disable-next-line unbound-method -- Compares method identity; never invoked.
			expect.soft(CodeView.prototype.setOptions).toBe(setOptions);
			// oxlint-disable-next-line unbound-method -- Compares method identity; never invoked.
			expect.soft(CodeView.prototype.setup).toBe(codeViewSetup);
			// oxlint-disable-next-line unbound-method -- Compares method identity; never invoked.
			expect.soft(InteractionManager.prototype.setup).toBe(interactionSetup);
			// oxlint-disable-next-line unbound-method -- Compares method identity; never invoked.
			expect.soft(InteractionManager.prototype.cleanUp).toBe(interactionCleanup);
			expect.soft(metadataPublicationOwner.publish).toBe(metadataPublication);
			expect.soft(globalThis.requestAnimationFrame).toBe(requestFrame);
			expect.soft(globalThis.cancelAnimationFrame).toBe(cancelFrame);
		},
	};
}
