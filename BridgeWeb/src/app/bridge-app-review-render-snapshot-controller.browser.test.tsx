import { act } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page, userEvent } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import './bridge-app.css';
import {
	buildBridgeWorkerReviewCandidateFailedEvent,
	buildBridgeWorkerReviewCandidateReadyEvent,
} from '../core/comm-worker/bridge-comm-worker-protocol.js';
import {
	bridgeWorkerReviewPublicationIdentity,
	bridgeWorkerReviewSourceContext,
} from '../core/comm-worker/bridge-worker-review-display.test-support.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	ReviewDirectDisplayProbe,
	ReviewRecoveryRetryProbe,
	hierarchicalReviewDisplayEvent,
	makeReviewSurfaceHarness,
	requireHTMLElement,
	reviewDisplayEvent,
	reviewDisplayEventWithContribution,
	reviewComparisonPanelChromeEvent,
	reviewComparisonPanelChromeEventForHarness,
	reviewComparisonLoadingPanelChromeEventForHarness,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';
import { performComparisonAction } from './bridge-review-comparison-control.browser.test-support.js';

const bridgeReviewNavigationCommandIsAlwaysEligible = (): boolean => true;

describe('useBridgeReviewRenderSnapshotController Browser Mode', () => {
	test('publishes real keyed Review facts and a later metadata window without a package adapter', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(<ReviewDirectDisplayProbe reviewClient={harness.reviewClient} />);
		await expect.element(rendered.getByTestId('review-direct-display-probe')).toBeInTheDocument();

		// Act
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
				}),
			);
		});
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-2',
					path: 'Sources/Later.swift',
					projectionRevision: 2,
					sequence: 2,
					startIndex: 1,
				}),
			);
		});

		// Assert
		await expect
			.element(rendered.getByTestId('review-direct-display-probe'))
			.toHaveAttribute('data-review-source-status', 'ready');
		await expect
			.element(rendered.getByTestId('review-direct-display-probe'))
			.toHaveAttribute('data-review-item-order-length', '2');
		await expect
			.element(rendered.getByTestId('review-direct-display-probe'))
			.toHaveAttribute('data-review-tree-row-order-length', '2');
		await expect
			.element(rendered.getByTestId('review-direct-display-probe'))
			.toHaveAttribute('data-review-later-row-path', 'Sources/Later.swift');
	});

	test('shows one Review metadata Retry and keeps the last good row while retrying both jobs', async () => {
		const harness = makeReviewSurfaceHarness();
		const target = {
			basis: 'commonCommit',
			branchName: 'master',
			kind: 'localDefaultBranch',
		} as const;
		const lastGoodReviewPath = 'Sources/LastGood.swift';
		harness.reviewClient.renderStore.applyReviewDisplayPatchEvent(
			reviewDisplayEvent({
				itemId: 'last-good-review-item',
				path: lastGoodReviewPath,
				projectionRevision: 1,
				sequence: 1,
				startIndex: 0,
			}),
		);
		const panelChromePatch = reviewComparisonPanelChromeEvent().patches[0];
		if (panelChromePatch?.slice !== 'panelChrome' || panelChromePatch.operation !== 'upsert') {
			throw new Error('Expected the Review comparison panel chrome patch.');
		}
		harness.reviewClient.renderStore.applyWorkerPatch(panelChromePatch);
		harness.reviewClient.renderStore.applyViewRecoveryStatusEvent({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'viewRecoveryStatus',
			view: { kind: 'review.metadata', subscriptionId: 'review-view-retry-1' },
			status: 'failedRetryable',
		});

		const rendered = await render(
			<ReviewRecoveryRetryProbe comparisonTarget={target} reviewClient={harness.reviewClient} />,
		);

		await expect
			.element(rendered.getByText("Review couldn't update. Showing the last version."))
			.toBeVisible();
		await expect.element(rendered.getByText(lastGoodReviewPath, { exact: true })).toBeVisible();
		expect(document.querySelectorAll('button[aria-label="Retry"]')).toHaveLength(1);
		const retryButton = rendered.getByRole('button', { name: 'Retry' }).element();
		expect(retryButton.tagName).toBe('BUTTON');
		expect(retryButton.getAttribute('type')).toBe('button');
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry' }).click();
		});
		await expect.element(rendered.getByText(lastGoodReviewPath, { exact: true })).toBeVisible();
		expect(harness.sentCommands.slice(-2).map((command) => command.command)).toEqual([
			'viewRecoveryRetry',
			'reviewComparisonUpdate',
		]);
		expect(harness.sentCommands.at(-2)).toMatchObject({
			command: 'viewRecoveryRetry',
			view: { kind: 'review.metadata', subscriptionId: 'review-view-retry-1' },
		});
		expect(harness.sentCommands.at(-1)).toMatchObject({
			command: 'reviewComparisonUpdate',
			target,
		});
		await page.screenshot({ path: '../../../tmp/bridgeweb-review-view-retry.png' });
	});

	test('emits one initial Review intake-ready command and does not duplicate it on rerender', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const onActiveSourceChange = vi.fn();
		const telemetryRecorderRef = { current: createBridgeTelemetryRecorder(null) };
		const viewerContextSwitcher = <div />;
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive={false}
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={onActiveSourceChange}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={telemetryRecorderRef}
				viewerContextSwitcher={viewerContextSwitcher}
			/>,
		);
		await expect.element(rendered.getByTestId('bridge-review-fallback-frame')).toBeInTheDocument();

		// Assert
		const initialIntakeReadyCommands = harness.sentCommands.filter(
			(command) => command.command === 'reviewIntakeReady',
		);
		expect(initialIntakeReadyCommands).toHaveLength(1);
		expect(initialIntakeReadyCommands[0]).toMatchObject({
			command: 'reviewIntakeReady',
			protocolId: 'review',
			reason: null,
			streamId: null,
		});

		// Act
		await act(async (): Promise<void> => {
			await rendered.rerender(
				<BridgeReviewViewerMode
					isActive={false}
					isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
					onActiveSourceChange={onActiveSourceChange}
					onNavigationSourceChange={vi.fn()}
					reviewClient={harness.reviewClient}
					telemetryRecorderRef={telemetryRecorderRef}
					viewerContextSwitcher={viewerContextSwitcher}
				/>,
			);
			await Promise.resolve();
		});

		// Assert
		expect(
			harness.sentCommands.filter((command) => command.command === 'reviewIntakeReady'),
		).toHaveLength(1);
	});

	test('shows the active symbolic target in the closed Review comparison control', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);

		// Act
		await act(async (): Promise<void> => {
			harness.publish(hierarchicalReviewDisplayEvent());
			await Promise.resolve();
			await Promise.resolve();
			harness.publish(reviewComparisonPanelChromeEvent());
			await Promise.resolve();
		});

		// Assert
		await expect
			.element(rendered.getByTestId('bridge-review-comparison-trigger'))
			.toHaveTextContent('master');
	});

	test('settles a rejected comparison-target query instead of leaving the picker loading', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);

		// Act
		await act(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		const queryRequest = Object.entries(harness.lifecycleStore.getSnapshot().requestsById).find(
			([, request]) => request.command === 'reviewComparisonTargetsQuery',
		);
		if (queryRequest === undefined) throw new Error('Expected a comparison-target query request.');
		await act(async (): Promise<void> => {
			harness.publish({
				direction: 'serverWorkerToMain',
				kind: 'health',
				message: 'Bridge comm worker failed to forward review.comparisonTargets.query.',
				requestId: queryRequest[0],
				status: 'degraded',
				transferDescriptors: [],
				wireVersion: 1,
			});
		});

		// Assert
		await expect.element(rendered.getByText('Comparison targets are unavailable.')).toBeVisible();
		await expect.element(rendered.getByRole('button', { name: 'Retry' })).toBeVisible();
	});

	test('keeps comparison meaning accessible while closed at the shared 24px control scale', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		await render(
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div data-testid="review-viewer-context-switcher" />}
			/>,
		);

		// Act
		await act(async (): Promise<void> => {
			harness.publish(hierarchicalReviewDisplayEvent());
			await Promise.resolve();
			await Promise.resolve();
			harness.publish(reviewComparisonPanelChromeEvent());
			await Promise.resolve();
		});

		// Assert
		const trigger = requireHTMLElement(
			document.querySelector('[data-testid="bridge-review-comparison-trigger"]'),
		);
		const topbar = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-content-topbar"]'),
		);
		const controls = requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-content-topbar-controls"]'),
		);
		const viewSettingsTrigger = requireHTMLElement(
			document.querySelector('[data-testid="bridge-review-view-settings-trigger"]'),
		);
		const contextSwitcher = requireHTMLElement(
			document.querySelector('[data-testid="review-viewer-context-switcher"]'),
		);
		const reviewType = requireHTMLElement(
			document.querySelector('[data-testid="bridge-review-mode-segmented-control"]'),
		);
		const descriptionId = trigger.getAttribute('aria-describedby');
		const topbarBox = topbar.getBoundingClientRect();
		const controlsBox = controls.getBoundingClientRect();
		const triggerBox = trigger.getBoundingClientRect();
		const viewSettingsBox = viewSettingsTrigger.getBoundingClientRect();
		expect(Math.round(topbarBox.height)).toBe(32);
		expect(Math.round(triggerBox.height)).toBe(24);
		expect(Math.round(viewSettingsBox.height)).toBe(24);
		expect(trigger.compareDocumentPosition(reviewType)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
		expect(reviewType.compareDocumentPosition(viewSettingsTrigger)).toBe(
			Node.DOCUMENT_POSITION_FOLLOWING,
		);
		expect(controls.contains(reviewType)).toBe(true);
		expect(controls.contains(contextSwitcher)).toBe(false);
		expect(
			contextSwitcher.closest('[data-testid="bridge-review-rail-toolbar-leading"]'),
		).not.toBeNull();
		expect(triggerBox.right).toBeLessThanOrEqual(viewSettingsBox.left);
		expect(triggerBox.top).toBeGreaterThanOrEqual(topbarBox.top);
		expect(triggerBox.bottom).toBeLessThanOrEqual(topbarBox.bottom);
		expect(controlsBox.right).toBeLessThanOrEqual(topbarBox.right);
		expect(trigger.getAttribute('aria-label')).toBe('Compare to: master');
		expect(descriptionId).not.toBeNull();
		expect(document.getElementById(descriptionId ?? '')?.textContent).toContain(
			'Changes only on master are excluded',
		);
		expect(document.querySelector('[data-testid="bridge-review-comparison-content"]')).toBeNull();
	});

	test('holds an affected promoted Review update in stable header chrome and applies it by keyboard', async () => {
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);

		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
					totalItemCount: 1,
				}),
			);
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
			await expect
				.poll(
					() =>
						harness.sentCommands.filter(
							(command) => command.command === 'reviewPublicationInstalled',
						).length,
				)
				.toBe(1);
			await Promise.resolve();
		});
		await expect.element(rendered.getByTestId('review-viewer-shell')).toBeVisible();
		const header = rendered.getByTestId('bridge-viewer-content-topbar').element();
		const headerHeight = header.getBoundingClientRect().height;

		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 2,
					publicationRevision: 2,
					sequence: 2,
					startIndex: 0,
					totalItemCount: 1,
				}),
				{
					candidateDisposition: {
						affectedStableFileIdentities: ['item-1'],
						kind: 'sameSource',
						presentationClass: { kind: 'promoted', reason: 'commits' },
					},
					completesReviewPublication: false,
				},
			);
			await Promise.resolve();
		});
		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Updating…');
		expect(header.getBoundingClientRect().height).toBe(headerHeight);

		await act(async (): Promise<void> => {
			harness.publish(
				buildBridgeWorkerReviewCandidateReadyEvent({
					epoch: 1,
					packageId: 'review-browser-harness-package',
					publicationId: '00000000-0000-7000-8000-000000000002',
					reviewGeneration: 1,
					revision: 2,
					sequence: 8,
					sourceIdentity: 'review-browser-harness-source',
				}),
			);
			await Promise.resolve();
		});
		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Update ready');
		const applyNow = rendered.getByRole('button', { name: 'Apply now' });
		const installedReceiptsBeforeApply = harness.sentCommands.filter(
			(command) => command.command === 'reviewPublicationInstalled',
		).length;
		await act(async (): Promise<void> => {
			applyNow.element().focus();
			await userEvent.keyboard('{Enter}');
			await expect
				.poll(
					() =>
						harness.sentCommands.filter(
							(command) => command.command === 'reviewPublicationInstalled',
						).length,
				)
				.toBe(installedReceiptsBeforeApply + 1);
			await expect
				.poll(() => rendered.getByTestId('bridge-review-refresh-header-group').query())
				.toBeNull();
			await settleRenderedReviewFrame();
			await Promise.resolve();
		});
		expect(header.getBoundingClientRect().height).toBe(headerHeight);
		expect(document.querySelector('[data-testid="bridge-review-refresh-status-row"]')).toBeNull();
		expect(
			harness.sentCommands.some((command) => command.command === 'reviewPublicationInstallAdmit'),
		).toBe(true);
		await act(async (): Promise<void> => {
			await rendered.unmount();
			await Promise.resolve();
		});
	});

	test('keeps active Review interactive while same-source comparison remains loading', async () => {
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<div className="h-[600px] w-full">
				<BridgeReviewViewerMode
					codeViewWorkerPoolEnabled={false}
					isActive
					isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
					onActiveSourceChange={vi.fn()}
					onNavigationSourceChange={vi.fn()}
					reviewClient={harness.reviewClient}
					telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
					viewerContextSwitcher={<div />}
				/>
			</div>,
		);
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEventWithContribution({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
					totalItemCount: 1,
				}),
			);
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
			harness.publish(reviewComparisonLoadingPanelChromeEventForHarness());
			await settleRenderedReviewFrame();
		});

		const canvas = rendered.getByTestId('bridge-review-canvas').element();
		const tree = rendered.getByTestId('bridge-review-rail-tree-slot').element();
		expect(canvas.hasAttribute('inert')).toBe(false);
		expect(tree.hasAttribute('inert')).toBe(false);
		expect(getComputedStyle(canvas).pointerEvents).not.toBe('none');
		expect(getComputedStyle(tree).pointerEvents).not.toBe('none');
		expect(rendered.getByTestId('bridge-review-comparison-status-banner').query()).toBeNull();

		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 2,
					publicationRevision: 2,
					sequence: 2,
					startIndex: 0,
					totalItemCount: 1,
				}),
				{
					candidateDisposition: {
						affectedStableFileIdentities: ['item-1'],
						kind: 'sameSource',
						presentationClass: { kind: 'promoted', reason: 'commits' },
					},
				},
			);
			await settleRenderedReviewFrame();
		});

		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Update ready');
		expect(canvas.hasAttribute('inert')).toBe(false);
		await act(async (): Promise<void> => {
			harness.reviewClient.renderStore.applyWorkerPatch({
				slice: 'panelChrome',
				operation: 'upsert',
				payload: {
					reviewComparison: {
						activeTarget: {
							basis: 'commonCommit',
							branchName: 'master',
							kind: 'localDefaultBranch',
						},
						attempt: { reviewGeneration: 1, status: 'settled' },
						displayedSnapshot: {
							packageId: 'review-browser-harness-package',
							reviewGeneration: 1,
							revision: 2,
							status: 'current',
						},
						repositoryDefaultTarget: null,
					},
				},
			});
		});
		expect(rendered.getByTestId('bridge-review-comparison-pending-icon').query()).toBeNull();
		expect(
			document
				.querySelector('[data-bridge-region="review-content"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document.querySelectorAll('[data-bridge-region="review-content"] [data-slot="skeleton"]'),
		).toHaveLength(6);
		await act(async (): Promise<void> => {
			expect(
				Object.keys(harness.reviewClient.renderStore.getSnapshot().codeViewItemsById),
			).toHaveLength(0);
			expect(
				[...document.querySelectorAll('diffs-container')].flatMap((container) => [
					...(container.shadowRoot?.querySelectorAll('[data-line][data-line-index]') ?? []),
				]),
			).toHaveLength(0);
			expect(
				rendered.getByTestId('bridge-review-sidebar').element().getBoundingClientRect().height,
			).toBe(600);
			await page.screenshot({ path: '../../../tmp/g1-review-held-single-indicator.png' });
		});
		expect(tree.hasAttribute('inert')).toBe(false);
		expect(getComputedStyle(canvas).pointerEvents).not.toBe('none');
		expect(getComputedStyle(tree).pointerEvents).not.toBe('none');
		expect(rendered.getByTestId('bridge-review-comparison-status-banner').query()).toBeNull();
	});

	test('keeps explicit comparison replacement loading blocked without same-source authority', async () => {
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEventWithContribution({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
					totalItemCount: 1,
				}),
			);
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
			harness.publish(
				reviewComparisonLoadingPanelChromeEventForHarness({
					activeTarget: { basis: 'commonCommit', kind: 'ref', name: 'feature/new-target' },
				}),
			);
			await settleRenderedReviewFrame();
		});

		const canvas = rendered.getByTestId('bridge-review-canvas').element();
		const tree = rendered.getByTestId('bridge-review-rail-tree-slot').element();
		expect(canvas.hasAttribute('inert')).toBe(true);
		expect(tree.hasAttribute('inert')).toBe(true);
		expect(getComputedStyle(canvas).pointerEvents).toBe('none');
		expect(getComputedStyle(tree).pointerEvents).toBe('none');
		await act(async (): Promise<void> => {
			await Promise.all(
				[canvas, tree]
					.flatMap((element) => element.getAnimations())
					.map((animation) => animation.finished),
			);
		});
		expect(getComputedStyle(canvas).opacity).toBe('1');
		expect(getComputedStyle(tree).opacity).toBe('1');
		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Updating…');
		expect(rendered.getByTestId('bridge-review-comparison-status-banner').query()).toBeNull();
	});

	test('automatically applies a held promoted Review update when Review attention leaves', async () => {
		const harness = makeReviewSurfaceHarness();
		const modeProps = {
			codeViewWorkerPoolEnabled: false,
			isNavigationCommandStillEligible: bridgeReviewNavigationCommandIsAlwaysEligible,
			onActiveSourceChange: vi.fn(),
			onNavigationSourceChange: vi.fn(),
			reviewClient: harness.reviewClient,
			telemetryRecorderRef: { current: createBridgeTelemetryRecorder(null) },
			viewerContextSwitcher: <div />,
		} as const;
		const rendered = await render(<BridgeReviewViewerMode {...modeProps} isActive />);
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
					totalItemCount: 1,
				}),
			);
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 2,
					publicationRevision: 2,
					sequence: 2,
					startIndex: 0,
					totalItemCount: 1,
				}),
				{
					candidateDisposition: {
						affectedStableFileIdentities: ['item-1'],
						kind: 'sameSource',
						presentationClass: { kind: 'promoted', reason: 'lines' },
					},
				},
			);
			await Promise.resolve();
		});
		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Update ready');
		const admissionsBeforeLeaving = harness.sentCommands.filter(
			(command) => command.command === 'reviewPublicationInstallAdmit',
		).length;

		await act(async (): Promise<void> => {
			await rendered.rerender(<BridgeReviewViewerMode {...modeProps} isActive={false} />);
			await Promise.resolve();
		});
		await expect
			.poll(
				() =>
					harness.sentCommands.filter(
						(command) => command.command === 'reviewPublicationInstallAdmit',
					).length,
			)
			.toBe(admissionsBeforeLeaving + 1);
		expect(rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
	});

	test('routes retryable promoted failure through the canonical active comparison target', async () => {
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		await act(async (): Promise<void> => {
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 1,
					sequence: 1,
					startIndex: 0,
					totalItemCount: 1,
				}),
			);
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
			harness.publish(reviewComparisonPanelChromeEventForHarness());
			harness.publish(
				reviewDisplayEvent({
					itemId: 'item-1',
					path: 'Sources/First.swift',
					projectionRevision: 2,
					publicationRevision: 2,
					sequence: 2,
					startIndex: 0,
					totalItemCount: 1,
				}),
				{
					candidateDisposition: {
						affectedStableFileIdentities: ['item-1'],
						kind: 'sameSource',
						presentationClass: { kind: 'promoted', reason: 'commits' },
					},
					completesReviewPublication: false,
				},
			);
			harness.publish(
				buildBridgeWorkerReviewCandidateFailedEvent({
					epoch: 1,
					packageId: 'review-browser-harness-package',
					publicationId: '00000000-0000-7000-8000-000000000002',
					retryable: true,
					reviewGeneration: 1,
					revision: 2,
					sequence: 8,
					sourceIdentity: 'review-browser-harness-source',
				}),
			);
			await Promise.resolve();
		});
		await expect
			.element(rendered.getByRole('alert'))
			.toHaveTextContent("Review couldn't update. Showing the last version.");
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry' }).click();
			await Promise.resolve();
		});
		expect(
			harness.sentCommands.findLast((command) => command.command === 'reviewComparisonUpdate'),
		).toMatchObject({
			command: 'reviewComparisonUpdate',
			target: { branchName: 'master', kind: 'localDefaultBranch' },
		});
	});

	test('applies an exact commit through the Review product command', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const exactCommitOID = 'c'.repeat(40);
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		await act(async (): Promise<void> => {
			harness.publish(hierarchicalReviewDisplayEvent());
			await Promise.resolve();
			await Promise.resolve();
			harness.publish(reviewComparisonPanelChromeEvent());
			await Promise.resolve();
		});

		// Act
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByTestId('bridge-review-comparison-trigger').click();
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Commit', exact: true }).click();
		});
		await act(async (): Promise<void> => {
			await rendered.getByRole('textbox', { name: 'Commit hash' }).fill(exactCommitOID);
		});
		await performComparisonAction(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Compare to this commit' }).click();
		});

		// Assert
		expect(harness.sentCommands).toContainEqual(
			expect.objectContaining({
				command: 'reviewComparisonUpdate',
				target: { kind: 'commit', oid: exactCommitOID },
			}),
		);
	});

	test('shows loaded Review chrome and explicit empty states for a ready zero-item source', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		await expect
			.element(rendered.getByTestId('bridge-review-metadata-loading-shell'))
			.toBeVisible();

		// Act
		await act(async (): Promise<void> => {
			harness.publish({
				direction: 'serverWorkerToMain',
				epoch: 1,
				kind: 'reviewDisplayPatch',
				reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentity(
					'review-package-browser-test',
					1,
					'review-source-browser-test',
				),
				patches: [
					{
						operation: 'upsert',
						payload: {
							...bridgeWorkerReviewSourceContext('review-package-browser-test'),
							metadataSourceId: 'review-source-browser-test',
							metadataWindowIdentity: 'review-window-empty',
							packageId: 'review-package-browser-test',
							reviewGeneration: 1,
							revision: 1,
							status: 'ready',
							summary: {
								additions: 0,
								deletions: 0,
								filesChanged: 0,
								hiddenFileCount: 0,
								visibleFileCount: 0,
							},
							totalItemCount: 0,
							totalTreeRowCount: 0,
						},
						slice: 'reviewSource',
					},
					{
						operation: 'batch',
						payload: { items: [], operations: [], reset: true, startIndex: 0 },
						slice: 'reviewItem',
					},
					{
						operation: 'batch',
						payload: { reset: true, windows: [] },
						slice: 'reviewTree',
					},
				],
				projectionRevision: 1,
				sequence: 1,
				surface: 'review',
				transferDescriptors: [],
				wireVersion: 1,
			});
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
		});

		// Assert
		await expect.element(rendered.getByTestId('review-viewer-shell')).toBeVisible();
		await expect.element(rendered.getByText('Nothing to review')).toBeVisible();
		await expect.element(rendered.getByText('No changed files')).toBeVisible();
		await expect
			.element(rendered.getByTestId('bridge-review-mode-segmented-control'))
			.toBeVisible();
		await expect.element(rendered.getByTestId('bridge-review-facet-menu-control')).toBeVisible();
		await expect.element(rendered.getByTestId('bridge-review-search-control')).toBeVisible();
		expect(document.querySelector('[data-testid="bridge-review-fallback-frame"]')).toBeNull();
		expect(
			document.querySelector('[data-testid="bridge-review-projection-pending-shell"]'),
		).toBeNull();
		expect(document.querySelector('[data-slot="skeleton"]')).toBeNull();
		expect(
			rendered
				.getByTestId('bridge-review-rail-tree-slot')
				.element()
				.querySelectorAll('[data-item-path]'),
		).toHaveLength(0);
	});
});
