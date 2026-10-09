import { act, type ReactElement } from 'react';
import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise mounted production Review recovery presentation.
import './bridge-app.css';
import type { BridgeMainCodeViewItem } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeMainReviewPublicationIdentity } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeMainPanelChromeSlice } from '../core/comm-worker/bridge-main-review-comparison-presentation.js';
import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import { createTestViewScopeOwner } from '../core/comm-worker/bridge-product-view-scope-owner.test-support.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import { parseBridgeCodeViewDiffForBrowserTest } from '../review-viewer/code-view/bridge-code-view-browser-test-diff.js';
import {
	makeReviewSurfaceHarness,
	reviewDisplayEventWithContribution,
	settleRenderedReviewFrame,
	type ReviewSurfaceHarness,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';

const installedView = {
	subscriptionId: 'review-recovery-e3',
	handle: 'review-recovery-view',
	incarnation: 'review-recovery-view',
	scopeRevision: 0,
} as const;
const retryTarget = { kind: 'ref', name: 'feature/retry', basis: 'commonCommit' } as const;
const retainedItemId = 'retained-review-item';
const retainedPath = 'Sources/Retained.swift';

interface InstalledReviewFixture {
	readonly harness: ReviewSurfaceHarness;
	readonly host: (isActive: boolean) => ReactElement;
	readonly owner: ReturnType<typeof createTestViewScopeOwner>;
	readonly releaseResnapshot: ReturnType<typeof createBridgeProductDeferred<void>>;
	readonly rendered: Awaited<ReturnType<typeof render>>;
	readonly retainedItem: BridgeMainCodeViewItem;
}

test.each(['ready', 'metadataFailure', 'installationFailure'] as const)(
	'pane Retry dispatches the comparison job with %s',
	async (failure): Promise<void> => {
		const fixture = await mountInstalledReview();
		try {
			await act(async (): Promise<void> => {
				if (failure === 'metadataFailure')
					fixture.owner.failRenderView(installedView.subscriptionId);
				if (failure === 'installationFailure') {
					const identity = {
						generation: 1,
						packageId: 'review-browser-harness-package',
						publicationId: '00000000-0000-7000-8000-000000000002',
						revision: 2,
						sourceIdentity: 'review-browser-harness-source',
					} satisfies BridgeMainReviewPublicationIdentity;
					const store = fixture.harness.reviewClient.renderStore;
					expect(
						store.startReviewCandidate({ disposition: { kind: 'replacement' }, identity }),
					).toBe(true);
					expect(store.markReviewCandidateReady({ identity, role: 'installing' })).toBe(true);
					expect(store.failReviewInstallation(identity)).toBe(true);
				}
				publishComparison(fixture.harness, {
					status: 'unavailable',
					failureKind: 'refreshUnavailable',
					retryable: true,
				});
			});
			expect(fixture.owner.recoveryState(installedView.subscriptionId)?.status).toBe(
				failure === 'metadataFailure' ? 'failedRetryable' : 'ready',
			);
			await expect.element(fixture.rendered.getByRole('alert')).toBeVisible();
			const commandStart = fixture.harness.sentCommands.length;
			await act(async (): Promise<void> => {
				await fixture.rendered.getByRole('button', { name: 'Retry', exact: true }).click();
			});
			expect(fixture.harness.sentCommands.slice(commandStart)).toEqual([
				...(failure === 'ready'
					? []
					: [
							expect.objectContaining({
								command: 'viewRecoveryRetry',
								view: { kind: 'review.metadata', subscriptionId: installedView.subscriptionId },
							}),
						]),
				expect.objectContaining({ command: 'reviewComparisonUpdate', target: retryTarget }),
			]);
			await act(async (): Promise<void> => {
				if (failure !== 'ready') {
					fixture.harness.reviewClient.renderStore.clearReviewCandidateFailure();
					fixture.owner.recordCertifiedInstall(installedView);
				}
				publishComparison(fixture.harness, { status: 'pending', reviewGeneration: 2 });
			});
			expectRetainedRegions('updating');
			await expect.element(fixture.rendered.getByText('Updating…', { exact: true })).toBeVisible();
		} finally {
			fixture.owner.retire(installedView.subscriptionId);
			await act(async (): Promise<void> => {
				await fixture.rendered.unmount();
			});
			fixture.harness.reviewClient.renderStore.dispose();
		}
	},
);

test('real W2 resnapshot recovery marks the retained bank Updating until certified install', async (): Promise<void> => {
	const fixture = await mountInstalledReview();
	let recovery = Promise.resolve();
	try {
		await act(async (): Promise<void> => {
			recovery = fixture.owner.resnapshot(installedView.subscriptionId);
		});
		expect(
			fixture.harness.reviewClient.renderStore.getReviewRefreshPresentation().candidate,
		).toBeNull();
		expect(fixture.owner.recoveryState(installedView.subscriptionId)?.status).toBe('recovering');
		expectRetainedRegions('updating');
		await expect.element(fixture.rendered.getByText('Updating…', { exact: true })).toBeVisible();
		expect(
			fixture.harness.reviewClient.renderStore.getReviewCodeViewItemSnapshot(retainedItemId),
		).toBe(fixture.retainedItem);
		await act(async (): Promise<void> => {
			await page.screenshot({ path: '../../../tmp/pr1-package-3/recovering.png' });
		});
		await act(async (): Promise<void> => {
			await fixture.rendered.rerender(fixture.host(false));
			await settleRenderedReviewFrame();
		});
		expectRetainedRegions('updating');
		expect(fixture.rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
		await act(async (): Promise<void> => {
			await fixture.rendered.rerender(fixture.host(true));
			fixture.releaseResnapshot.resolve();
			await recovery;
			fixture.owner.recordCertifiedInstall(installedView);
			await settleRenderedReviewFrame();
		});
		expectRetainedRegions('content');
		expect(fixture.rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
	} finally {
		fixture.releaseResnapshot.resolve();
		await recovery;
		fixture.owner.retire(installedView.subscriptionId);
		await act(async (): Promise<void> => {
			await fixture.rendered.unmount();
		});
		fixture.harness.reviewClient.renderStore.dispose();
	}
});

async function mountInstalledReview(): Promise<InstalledReviewFixture> {
	const harness = makeReviewSurfaceHarness();
	const releaseResnapshot = createBridgeProductDeferred<void>();
	const owner = createTestViewScopeOwner({
		createIdentifier: (): string => installedView.handle,
		maximumConsecutiveResnapshots: 2,
		onViewRecoveryStatus: (status): void => {
			harness.reviewClient.renderStore.applyViewRecoveryStatusEvent({
				...status,
				kind: 'viewRecoveryStatus',
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
			});
		},
		controlMux: {
			setViewScope: async (): Promise<never> => {
				throw new Error('No scope change expected.');
			},
			resnapshotView: async (request) => {
				await releaseResnapshot.promise;
				return {
					...request,
					kind: 'subscription.resnapshotAccepted' as const,
					paneSessionId: 'pane',
					requestId: 'recovery',
					requestSequence: 1,
					wireVersion: 2 as const,
					workerInstanceId: 'worker',
				};
			},
		},
	});
	owner.register({
		scope: { kind: 'review', interests: [] },
		subscriptionId: installedView.subscriptionId,
		subscriptionKind: 'review.metadata',
	});
	const host = (isActive: boolean): ReactElement => (
		<div className="h-[600px] w-[720px]">
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive={isActive}
				isNavigationCommandStillEligible={(): boolean => true}
				onActiveSourceChange={(): void => {}}
				onNavigationSourceChange={(): void => {}}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<span>Review</span>}
			/>
		</div>
	);
	const rendered = await render(host(true));
	const retainedItem = {
		bridgeMetadata: {
			cacheKey: 'retained-review-cache',
			contentRoles: ['base', 'head'] as const,
			contentState: 'hydrated' as const,
			displayPath: retainedPath,
			itemId: retainedItemId,
			lineCount: 2,
		},
		fileDiff: parseBridgeCodeViewDiffForBrowserTest(
			{ contents: 'let retained = 1\n', name: retainedPath },
			{ contents: 'let retained = 2\n', name: retainedPath },
		),
		id: retainedItemId,
		type: 'diff' as const,
		version: 1,
	};
	await act(async (): Promise<void> => {
		harness.publish(
			reviewDisplayEventWithContribution({
				itemId: retainedItemId,
				path: retainedPath,
				projectionRevision: 1,
				sequence: 1,
				startIndex: 0,
				totalItemCount: 1,
			}),
		);
		await import('../review-viewer/shell/review-viewer-shell.js');
		await settleRenderedReviewFrame();
	});
	await act(async (): Promise<void> => {
		harness.reviewClient.renderStore.setWorkerCodeViewItem({
			itemId: retainedItemId,
			item: retainedItem,
		});
		harness.reviewClient.renderStore.applyWorkerPatch({
			slice: 'contentAvailability',
			operation: 'upsert',
			itemId: retainedItemId,
			payload: { state: 'ready' },
		});
		harness.reviewClient.renderStore.setLocalSelection({
			selectedItemId: retainedItemId,
			source: 'user',
		});
		publishComparison(harness, { status: 'settled', reviewGeneration: 1 });
		owner.recordCertifiedInstall(installedView);
	});
	await expect.element(rendered.getByTestId('review-viewer-shell')).toBeVisible();
	expectRetainedRegions('content');
	return { harness, host, owner, releaseResnapshot, rendered, retainedItem };
}

function publishComparison(
	harness: ReviewSurfaceHarness,
	attempt: NonNullable<BridgeMainPanelChromeSlice['reviewComparison']>['attempt'],
): void {
	harness.reviewClient.renderStore.applyWorkerPatch({
		slice: 'panelChrome',
		operation: 'upsert',
		payload: {
			reviewComparison: {
				activeTarget: retryTarget,
				attempt,
				displayedSnapshot: {
					packageId: 'review-browser-harness-package',
					reviewGeneration: 1,
					revision: 1,
					status: 'current',
				},
				repositoryDefaultTarget: null,
			},
		},
	});
}

function expectRetainedRegions(state: 'content' | 'updating'): void {
	for (const region of ['review-content', 'review-tree']) {
		const element = document.querySelector(`[data-bridge-region="${region}"]`);
		expect(element?.getAttribute('data-presentation-state')).toBe(state);
		expect(element?.getAttribute('data-content-current')).toBe(
			state === 'content' ? 'true' : 'false',
		);
	}
}
