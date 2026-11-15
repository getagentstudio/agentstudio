import {
	CodeView,
	parseDiffFromFile,
	type CodeViewItem,
	type CodeViewOptions,
} from '@pierre/diffs';
import { act } from 'react';
import { describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { userEvent } from 'vitest/browser';

import { runBridgeTransitionFramesInAct } from '../../tests/test-support/bridge-transition-dom-fact.browser.test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeMainCodeViewItem } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeFileViewerSelectedCodeViewItem } from '../file-viewer/bridge-file-viewer-code-view-items.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import { BridgeCodeViewPanel } from '../review-viewer/code-view/bridge-code-view-panel.js';
import { worktreeAnnotationMetadataForPierreAnnotation } from '../review-viewer/code-view/worktree-annotation-pierre-adapter.js';
import {
	installReviewAnimationFrameClock,
	waitForReviewControl,
} from '../review-viewer/code-view/worktree-annotation-pierre-review.browser.test-support.js';
import { buildBridgeReviewProjection } from '../review-viewer/navigation/review-projection.js';
import {
	annotationBaseThreadId,
	annotationHeadThreadId,
	annotationMessage,
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import {
	completeCleanup,
	runWithOwnedCleanup,
} from './worktree-annotation-click-admission-cleanup.browser.test-support.js';
import type { WorktreeAnnotationThreadContext } from './worktree-annotation-surface-client.js';
import { WorktreeAnnotationSurfaceProvider } from './worktree-annotation-surface-provider.js';

const headMessageId = '00000000-0000-7000-8000-000000000021';
const baseMessageId = '00000000-0000-7000-8000-000000000022';

describe('worktree annotation Pierre Review integration', () => {
	test('publishes completed Review batches through updateItem without remounting or losing collapse', async (context) => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const mountedCodeViews: CodeView[] = [];
		const appliedOptions: CodeViewOptions<undefined>[] = [];
		const annotationAttentionSnapshots: string[][] = [];
		const annotationEditorAttentionSnapshots: string[][] = [];
		const updatedItems: CodeViewItem[] = [];
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetOptions = CodeView.prototype.setOptions;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalUpdateItem = CodeView.prototype.updateItem;
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			mountedCodeViews.push(this);
			originalSetup.call(this, root);
		};
		CodeView.prototype.setOptions = function captureOptions(
			options: CodeViewOptions<undefined> | undefined,
		): void {
			if (options !== undefined) appliedOptions.push(options);
			originalSetOptions.call(this, options);
		};
		CodeView.prototype.updateItem = function captureUpdate(item: CodeViewItem): boolean {
			updatedItems.push(item);
			return originalUpdateItem.call(this, item);
		};

		const reviewPackage = makeBridgeReviewPackage();
		const projection = buildBridgeReviewProjection({
			reviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		let animationFrames = installReviewAnimationFrameClock(context.signal);
		const coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (): void => {},
		});
		const reviewCodeViewItem = makeReviewCodeViewItem();
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				const rendered = await render(
					<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
						<BridgeCodeViewPanel
							onAnnotationAttentionItemIdsChange={(itemIds): void => {
								annotationAttentionSnapshots.push([...itemIds]);
							}}
							onAnnotationEditorAttentionItemIdsChange={(itemIds): void => {
								annotationEditorAttentionSnapshots.push([...itemIds]);
							}}
							presentationPositionKey="annotation-browser-review"
							projection={projection}
							renderFulfillmentCoordinator={coordinator}
							reviewPackage={reviewPackage}
							selectedCodeViewItem={reviewCodeViewItem}
							selectedItemId="item-source"
							visibleCodeViewItems={[reviewCodeViewItem]}
							workerPoolEnabled={false}
						/>
					</WorktreeAnnotationSurfaceProvider>,
				);
				await animationFrames.settleCondition(
					(): boolean => mountedCodeViews[0]?.getItem('item-source') !== undefined,
					'Expected one mounted Review Pierre item.',
				);
				const codeView = requireCodeView(mountedCodeViews[0]);

				await act(async (): Promise<void> => {
					surface.publishProjectionState({
						expectedThreadCount: 2,
						recoveryStatus: 'recovered_degraded',
						revision: 1,
						sessions: [annotationSessionSummary({ revision: 1, sessionId: annotationSessionId })],
					});
					await Promise.resolve();
				});
				await animationFrames.drain();
				expect(
					document.querySelector(
						'[data-testid="bridge-code-view-panel"] [data-testid="worktree-annotation-session-surface"]',
					),
				).toBeNull();
				const updatesBeforeMessages = updatedItems.length;
				await act(async (): Promise<void> => {
					surface.publishThread({
						context: annotationContext({
							diffSide: 'additions',
							endLine: 2,
							sourceRole: 'review_head',
							threadId: annotationHeadThreadId,
						}),
						message: annotationMessage({
							messageId: headMessageId,
							threadId: annotationHeadThreadId,
						}),
					});
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean => (codeView.getItem('item-source')?.annotations ?? []).length === 0,
					'Expected an incomplete projection to retain the empty annotation publication.',
				);
				expect(
					updatedItems
						.slice(updatesBeforeMessages)
						.every((item): boolean => (item.annotations ?? []).length === 0),
				).toBe(true);
				expect(codeView.getItem('item-source')?.annotations ?? []).toEqual([]);

				await act(async (): Promise<void> => {
					surface.publishThread({
						context: annotationContext({
							diffSide: 'deletions',
							endLine: 2,
							sourceRole: 'review_base',
							threadId: annotationBaseThreadId,
						}),
						message: annotationMessage({
							messageId: baseMessageId,
							threadId: annotationBaseThreadId,
						}),
					});
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						document.querySelectorAll('[data-testid="worktree-annotation-thread"]').length === 2,
					'Expected both Review threads to publish atomically into Pierre annotation slots.',
				);
				await animationFrames.settleCondition((): boolean => {
					const threadIdentities = new Set(
						(codeView.getItem('item-source')?.annotations ?? []).flatMap(
							(annotation): readonly string[] => {
								const metadata = worktreeAnnotationMetadataForPierreAnnotation(annotation);
								return metadata?.kind === 'thread'
									? [`${metadata.threadId}:${metadata.range.side ?? 'none'}`]
									: [];
							},
						),
					);
					return (
						threadIdentities.has(`${annotationHeadThreadId}:additions`) &&
						threadIdentities.has(`${annotationBaseThreadId}:deletions`)
					);
				}, 'Expected the live selected CodeView item to apply both exact Review threads.');
				const updatesBeforeEqualRefresh = updatedItems.length;
				await act(async (): Promise<void> => {
					surface.publishRefreshing();
					surface.publishProjection(1, 2);
					surface.publishThread({
						context: annotationContext({
							diffSide: 'additions',
							endLine: 2,
							sourceRole: 'review_head',
							threadId: annotationHeadThreadId,
						}),
						message: annotationMessage({
							messageId: headMessageId,
							threadId: annotationHeadThreadId,
						}),
					});
					surface.publishThread({
						context: annotationContext({
							diffSide: 'deletions',
							endLine: 2,
							sourceRole: 'review_base',
							threadId: annotationBaseThreadId,
						}),
						message: annotationMessage({
							messageId: baseMessageId,
							threadId: annotationBaseThreadId,
						}),
					});
					await Promise.resolve();
				});
				await animationFrames.drain();
				expect(updatedItems.slice(updatesBeforeEqualRefresh)).toEqual([]);
				await act(async (): Promise<void> => {
					surface.publishProjection(2, 2);
					surface.publishThread({
						context: annotationContext({
							diffSide: 'additions',
							endLine: 2,
							sourceRole: 'review_head',
							threadId: annotationHeadThreadId,
						}),
						message: annotationMessage({
							messageId: headMessageId,
							sessionRevision: 2,
							threadId: annotationHeadThreadId,
						}),
					});
					surface.publishThread({
						context: annotationContext({
							diffSide: 'deletions',
							endLine: 2,
							sourceRole: 'review_base',
							threadId: annotationBaseThreadId,
						}),
						message: annotationMessage({
							messageId: baseMessageId,
							sessionRevision: 2,
							threadId: annotationBaseThreadId,
						}),
					});
					await Promise.resolve();
				});
				await animationFrames.drain();
				// Resize/highlight completion can request a frame after the simulated
				// queue drains. Keep real frames running until Reply is committed.
				animationFrames.restore();
				try {
					await runBridgeTransitionFramesInAct(async (): Promise<void> => {
						const replyButtons = rendered.getByRole('button', {
							name: 'Reply to annotation thread',
						});
						await waitForReviewControl({
							panel: rendered.getByTestId('bridge-code-view-panel').element(),
							signal: context.signal,
							label: 'both Review thread Reply controls',
							isReady: (): boolean =>
								replyButtons.all().length === 2 &&
								replyButtons.all().every((button): boolean => {
									const element = button.element();
									return element.checkVisibility() && !element.matches(':disabled');
								}),
						});
						expect(replyButtons.all()).toHaveLength(2);
						await act(async (): Promise<void> => {
							await replyButtons.first().click();
						});
					});
				} finally {
					animationFrames = installReviewAnimationFrameClock(context.signal);
				}
				await animationFrames.settleCondition(
					(): boolean => annotationEditorAttentionSnapshots.at(-1)?.[0] === 'item-source',
					'Expected an existing-thread editor to publish its owning Review item.',
				);
				expect(annotationEditorAttentionSnapshots.at(-1)).toEqual(['item-source']);
				await act(async (): Promise<void> => {
					await userEvent.keyboard('{Escape}');
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean => annotationEditorAttentionSnapshots.at(-1)?.length === 0,
					'Expected closing the existing-thread editor to clear editor attention.',
				);
				expect(codeView.getItem('item-source')?.annotations).toEqual([
					{
						lineNumber: 2,
						metadata: {
							kind: 'thread',
							presentationIdentity: expect.any(String),
							range: { end: 2, endSide: 'additions', side: 'additions', start: 2 },
							threadId: annotationHeadThreadId,
						},
						side: 'additions',
					},
					{
						lineNumber: 2,
						metadata: {
							kind: 'thread',
							presentationIdentity: expect.any(String),
							range: { end: 2, endSide: 'deletions', side: 'deletions', start: 2 },
							threadId: annotationBaseThreadId,
						},
						side: 'deletions',
					},
				]);
				expect(mountedCodeViews).toHaveLength(1);

				const beforeCollapse = requireCodeViewItem(codeView.getItem('item-source'));
				await act(async (): Promise<void> => {
					codeView.updateItem({
						...beforeCollapse,
						collapsed: true,
						version: (beforeCollapse.version ?? 0) + 1,
					});
					await Promise.resolve();
					surface.publishProjection(2, 1);
					await Promise.resolve();
					surface.publishThread({
						context: annotationContext({
							diffSide: 'additions',
							endLine: 2,
							sourceRole: 'review_head',
							threadId: annotationHeadThreadId,
						}),
						message: annotationMessage({
							messageId: headMessageId,
							sessionRevision: 2,
							threadId: annotationHeadThreadId,
						}),
					});
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean => codeView.getItem('item-source')?.annotations?.length === 1,
					'Expected the next annotation projection to settle.',
				);
				expect(codeView.getItem('item-source')?.collapsed).toBe(true);
				expect(mountedCodeViews).toHaveLength(1);

				await act(async (): Promise<void> => {
					surface.publishProjection(3, 0);
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean => codeView.getItem('item-source')?.annotations?.length === 0,
					'Expected the fresh projection to clear the prior thread before composer admission.',
				);
				const collapsedItem = requireCodeViewItem(codeView.getItem('item-source'));
				await act(async (): Promise<void> => {
					codeView.updateItem({
						...collapsedItem,
						collapsed: false,
						version: (collapsedItem.version ?? 0) + 1,
					});
					await Promise.resolve();
				});
				await animationFrames.drain();
				const latestOptions = requireCodeViewOptions(appliedOptions.at(-1));
				const currentItem = requireCodeViewItem(codeView.getItem('item-source'));
				await act(async (): Promise<void> => {
					invokeGutterAdmission(
						latestOptions,
						{ start: 2, end: 2, side: 'additions' },
						currentItem,
					);
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						codeView
							.getItem('item-source')
							?.annotations?.some(
								(annotation): boolean =>
									worktreeAnnotationMetadataForPierreAnnotation(annotation)?.kind === 'composer',
							) === true,
					'Expected the Review item to receive the pending composer annotation.',
				);
				expect(codeView.getItem('item-source')?.collapsed).toBe(false);
				const headComposer = rendered.getByRole('textbox', {
					name: 'Write an annotation in Markdown',
				});
				// Drain Pierre's queued slot publication before reading the composer.
				await animationFrames.settleCondition(
					(): boolean => headComposer.query()?.checkVisibility() === true,
					'Expected the head-side root composer to become visible.',
				);
				await expect.element(headComposer).toBeVisible();
				expect(annotationAttentionSnapshots.at(-1)).toEqual(['item-source']);
				expect(annotationEditorAttentionSnapshots.at(-1)).toEqual(['item-source']);
				await act(async (): Promise<void> => {
					await headComposer.fill('Head-side comment');
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						surface.sentOperations.filter((operation) => operation.kind === 'root.create')
							.length === 1,
					'Expected one Review head-side root operation.',
				);
				expect(
					surface.sentOperations.find((operation) => operation.kind === 'root.create'),
				).toMatchObject({
					origin: { diffSide: 'additions', sourceRole: 'reviewHead' },
				});
				await act(async (): Promise<void> => {
					invokeLineSelection(latestOptions, null, currentItem);
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						document.querySelector('[aria-label="Write an annotation in Markdown"]') === null,
					'Expected clearing Pierre selection to close the root composer.',
				);
				expect(annotationAttentionSnapshots.at(-1)).toEqual([]);
				expect(annotationEditorAttentionSnapshots.at(-1)).toEqual([]);
				await act(async (): Promise<void> => {
					invokeGutterAdmission(
						latestOptions,
						{ start: 2, end: 2, side: 'deletions' },
						currentItem,
					);
					await Promise.resolve();
				});
				await animationFrames.drain();
				const baseComposer = rendered.getByRole('textbox', {
					name: 'Write an annotation in Markdown',
				});
				await act(async (): Promise<void> => {
					await baseComposer.fill('Base-side comment');
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						surface.sentOperations.filter((operation) => operation.kind === 'root.create')
							.length === 2,
					'Expected one Review base-side root operation.',
				);
				expect(
					surface.sentOperations.findLast((operation) => operation.kind === 'root.create'),
				).toMatchObject({
					origin: { diffSide: 'deletions', sourceRole: 'reviewBase' },
				});
			},
			async (): Promise<void> => {
				await completeCleanup([
					animationFrames.drain,
					async (): Promise<void> => {
						await act(async (): Promise<void> => {
							await cleanup();
						});
					},
					animationFrames.drain,
					animationFrames.restore,
					(): void => {
						CodeView.prototype.setup = originalSetup;
						CodeView.prototype.setOptions = originalSetOptions;
						CodeView.prototype.updateItem = originalUpdateItem;
						coordinator.dispose();
					},
				]);
			},
		);
	});

	test('releases a committed Review root draft before projection convergence', async (context) => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const mountedCodeViews: CodeView[] = [];
		const appliedOptions: CodeViewOptions<undefined>[] = [];
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetup = CodeView.prototype.setup;
		// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
		const originalSetOptions = CodeView.prototype.setOptions;
		CodeView.prototype.setup = function captureMountedCodeView(root: HTMLElement): void {
			mountedCodeViews.push(this);
			originalSetup.call(this, root);
		};
		CodeView.prototype.setOptions = function captureOptions(
			options: CodeViewOptions<undefined> | undefined,
		): void {
			if (options !== undefined) appliedOptions.push(options);
			originalSetOptions.call(this, options);
		};

		const reviewPackage = makeBridgeReviewPackage();
		const projection = buildBridgeReviewProjection({
			reviewPackage,
			request: { facets: [], mode: { kind: 'normalReview' } },
		});
		const animationFrames = installReviewAnimationFrameClock(context.signal);
		const coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (): void => {},
		});
		const reviewCodeViewItem = makeReviewCodeViewItem();
		await runWithOwnedCleanup(
			async (): Promise<void> => {
				const rendered = await render(
					<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
						<BridgeCodeViewPanel
							presentationPositionKey="annotation-browser-review-release"
							projection={projection}
							renderFulfillmentCoordinator={coordinator}
							reviewPackage={reviewPackage}
							selectedCodeViewItem={reviewCodeViewItem}
							selectedItemId="item-source"
							visibleCodeViewItems={[reviewCodeViewItem]}
							workerPoolEnabled={false}
						/>
					</WorktreeAnnotationSurfaceProvider>,
				);
				await animationFrames.settleCondition(
					(): boolean => mountedCodeViews[0]?.getItem('item-source') !== undefined,
					'Expected one mounted Review Pierre item.',
				);
				await act(async (): Promise<void> => {
					surface.publishProjection(1, 0);
					await Promise.resolve();
				});
				await animationFrames.drain();
				const codeView = requireCodeView(mountedCodeViews[0]);
				const currentItem = requireCodeViewItem(codeView.getItem('item-source'));
				await act(async (): Promise<void> => {
					invokeGutterAdmission(
						requireCodeViewOptions(appliedOptions.at(-1)),
						{ end: 2, side: 'additions', start: 2 },
						currentItem,
					);
					await Promise.resolve();
				});
				await animationFrames.drain();
				const composer = rendered.getByRole('textbox', {
					name: 'Write an annotation in Markdown',
				});
				await act(async (): Promise<void> => {
					await composer.fill('Committed Review draft awaiting projection.');
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						surface.sentOperations.some((operation) => operation.kind === 'root.create'),
					'Expected the Review root draft command.',
				);
				await act(async (): Promise<void> => {
					surface.settleMostRecentCommittedWithoutProjection(annotationSessionId, 'root.create');
					await Promise.resolve();
				});
				const draftStatus = rendered.getByText('Draft', { exact: true });
				await animationFrames.settleCondition(
					(): boolean => draftStatus.query()?.checkVisibility() === true,
					'Expected the committed root draft status to become visible.',
				);
				await expect.element(draftStatus).toBeVisible();
				await act(async (): Promise<void> => {
					await userEvent.keyboard('{Escape}');
					await Promise.resolve();
				});
				await animationFrames.settleCondition(
					(): boolean =>
						surface.sentOperations.some((operation) => operation.kind === 'draft.edit.release'),
					'Expected collapsed Review root draft to release its edit token.',
				);
				expect(
					surface.sentOperations.filter((operation) => operation.kind === 'draft.edit.release'),
				).toHaveLength(1);
				expect(
					surface.sentOperations.find((operation) => operation.kind === 'draft.edit.release'),
				).toMatchObject({
					expectedDraftRevision: 0,
					expectedMessageRevision: 0,
					messageId: '00000000-0000-7000-8000-000000000031',
					sessionId: annotationSessionId,
				});
			},
			async (): Promise<void> => {
				await completeCleanup([
					animationFrames.drain,
					async (): Promise<void> => {
						await act(async (): Promise<void> => {
							await cleanup();
						});
					},
					animationFrames.drain,
					animationFrames.restore,
					(): void => {
						CodeView.prototype.setup = originalSetup;
						CodeView.prototype.setOptions = originalSetOptions;
						coordinator.dispose();
					},
				]);
			},
		);
	});
});

function annotationContext(
	props:
		| {
				readonly diffSide: 'deletions';
				readonly endLine: number;
				readonly sourceRole: 'review_base';
				readonly threadId: string;
		  }
		| {
				readonly diffSide: 'additions';
				readonly endLine: number;
				readonly sourceRole: 'review_head';
				readonly threadId: string;
		  },
): WorktreeAnnotationThreadContext {
	const commonContext = {
		endLine: props.endLine,
		path: 'Sources/App/View.swift',
		placement: 'exact',
		resolution: 'open',
		scope: 'located',
		sourceIdentity:
			props.sourceRole === 'review_base' ? 'handle-item-source-base' : 'handle-item-source-head',
		startLine: props.endLine,
		threadId: props.threadId,
	} as const;
	return props.sourceRole === 'review_base'
		? { ...commonContext, diffSide: props.diffSide, sourceRole: 'review_base' }
		: { ...commonContext, diffSide: props.diffSide, sourceRole: 'review_head' };
}

function makeReviewCodeViewItem(): BridgeMainCodeViewItem {
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
			{
				cacheKey: 'review-base',
				contents: baseContents,
				name: 'Sources/App/View.swift',
			},
			{
				cacheKey: 'review-head',
				contents: headContents,
				name: 'Sources/App/View.swift',
			},
		),
		id: 'item-source',
		type: 'diff',
		version: 1,
	};
}

function makeFileItem(
	props: {
		readonly displayPath?: string;
		readonly fileId?: string;
		readonly sourceDescriptorId?: string;
	} = {},
): BridgeFileViewerSelectedCodeViewItem {
	const displayPath = props.displayPath ?? 'Sources/App/View.swift';
	const fileId = props.fileId ?? 'file-1';
	const sourceDescriptorId = props.sourceDescriptorId ?? 'descriptor-file-1';
	return {
		bridgeMetadata: {
			cacheKey: `file-cache-${fileId}`,
			contentRoles: ['file'],
			contentState: 'hydrated',
			displayPath,
			itemId: fileId,
			lineCount: 8,
			sourceDescriptorId,
		},
		file: {
			cacheKey: `file-cache-${fileId}`,
			contents: Array.from(
				{ length: 8 },
				(_, index): string => `let line${index + 1} = ${index + 1}`,
			).join('\n'),
			lang: 'swift',
			name: displayPath,
		},
		id: `file:${fileId}`,
		type: 'file',
		version: 1,
	};
}

function invokeLineSelection(
	options: CodeViewOptions<undefined>,
	range: {
		readonly end: number;
		readonly endSide?: 'additions' | 'deletions';
		readonly side?: 'additions' | 'deletions';
		readonly start: number;
	} | null,
	item: Readonly<{ id: string }>,
): void {
	const callback = options.onLineSelectionEnd;
	if (callback === undefined) throw new Error('Expected a Pierre line-selection callback.');
	Reflect.apply(callback, undefined, [range, { item }]);
}

function invokeGutterAdmission(
	options: CodeViewOptions<undefined>,
	range: {
		readonly end: number;
		readonly endSide?: 'additions' | 'deletions';
		readonly side?: 'additions' | 'deletions';
		readonly start: number;
	},
	item: Readonly<{ id: string }>,
): void {
	const gutterCallback = options.onGutterUtilityClick;
	const selectionEndCallback = options.onLineSelectionEnd;
	if (gutterCallback === undefined || selectionEndCallback === undefined) {
		throw new Error('Expected Pierre gutter and line-selection callbacks.');
	}
	Reflect.apply(gutterCallback, undefined, [range, { item }]);
	Reflect.apply(selectionEndCallback, undefined, [range, { item }]);
}

function requireCodeView(value: CodeView | undefined): CodeView {
	if (value === undefined) throw new Error('Expected mounted Pierre CodeView.');
	return value;
}

function requireCodeViewItem(value: CodeViewItem | undefined): CodeViewItem {
	if (value === undefined) throw new Error('Expected current Pierre item.');
	return value;
}

function requireCodeViewOptions(
	value: CodeViewOptions<undefined> | undefined,
): CodeViewOptions<undefined> {
	if (value === undefined) throw new Error('Expected current Pierre options.');
	return value;
}

void makeFileItem;
