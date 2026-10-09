import { parseDiffFromFile } from '@pierre/diffs';
import { act } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import './bridge-app.css';
import { buildBridgeWorkerViewRecoveryStatusEvent } from '../core/comm-worker/bridge-comm-worker-protocol.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import type { BridgeProductReviewTreeRow } from '../core/comm-worker/bridge-product-review-metadata-contracts.js';
import type {
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { buildBridgeWorkerPierreRenderJob } from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../core/comm-worker/bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from '../core/comm-worker/bridge-worker-render-fulfillment.test-support.js';
import { BridgeFileViewerSurfaceClientProvider } from '../file-viewer/bridge-file-viewer-render-snapshot-controller.js';
import { createBridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	FileDisplaySourceProbe,
	ReviewIntakeLifecycleProbe,
	fileDisplayEvent,
	hierarchicalReviewDisplayEvent,
	makeFileSurfaceHarness,
	makeReviewSurfaceHarness,
	requireDefined,
	requireHTMLElement,
	reviewDisplayEvent,
	reviewIntakeReadyCommands,
	reviewIntakeReadyRequestIds,
	settleRenderedReviewFrame,
} from './bridge-app-review-render-snapshot-controller.browser-harness.test-support.js';
import { reviewDisplayItem } from './bridge-app-review-render-snapshot-controller.browser.test-support.js';
import { createBridgeReviewWorkerPierreCourier } from './bridge-app-review-render-snapshot-controller.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';

const bridgeReviewNavigationCommandIsAlwaysEligible = (): boolean => true;

const TEST_REVIEW_PUBLICATION_IDENTITY = {
	packageId: 'test-review-package',
	publicationId: '00000000-0000-7000-8000-000000000001',
	reviewGeneration: 1,
	revision: 1,
	sourceIdentity: 'test-review-source',
} as const;

describe('useBridgeReviewRenderSnapshotController lifecycle Browser Mode', () => {
	test('render failure status preserves an installed Review CodeView and semantic item', async () => {
		const harness = makeReviewSurfaceHarness();
		let resolvePainted: (() => void) | undefined;
		const painted = new Promise<void>((resolve): void => {
			resolvePainted = resolve;
		});
		const coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (receipt): void => {
				if (receipt.disposition === 'painted') resolvePainted?.();
			},
		});
		const rendered = await render(
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={{ ...harness.reviewClient, renderFulfillmentCoordinator: coordinator }}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		try {
			await act(async (): Promise<void> => {
				harness.publish(hierarchicalReviewDisplayEvent());
				await import('../review-viewer/shell/review-viewer-shell.js');
			});
			await act(async (): Promise<void> => {
				for (const message of reviewContentReadyEvents()) harness.publish(message);
			});
			await act(async (): Promise<void> => painted);
			const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			const item = harness.reviewClient.renderStore.getReviewCodeViewItemSnapshot('item-1');
			expect(panel).not.toBeNull();
			expect(item?.bridgeMetadata.itemId).toBe('item-1');
			await act(async (): Promise<void> => {
				harness.reviewClient.renderStore.applyViewRecoveryStatusEvent(
					buildBridgeWorkerViewRecoveryStatusEvent({
						status: 'failedRetryable',
						view: { kind: 'review.metadata', subscriptionId: 'affected-render-view' },
					}),
				);
			});
			expect(document.querySelector('[data-testid="bridge-code-view-panel"]')).toBe(panel);
			expect(harness.reviewClient.renderStore.getReviewCodeViewItemSnapshot('item-1')).toBe(item);
			expect(
				document
					.querySelector('[data-testid="review-viewer-shell"]')
					?.getAttribute('data-selected-content-state'),
			).toBe('ready');
			expect(document.querySelectorAll('[data-testid="bridge-pane-failure-summary"]')).toHaveLength(
				1,
			);
			expect(rendered.getByRole('button', { name: 'Retry', exact: true }).all()).toHaveLength(1);
		} finally {
			await act(async (): Promise<void> => rendered.unmount());
			coordinator.dispose();
			harness.reviewClient.renderFulfillmentCoordinator.dispose();
			harness.reviewClient.renderStore.dispose();
			harness.lifecycleStore.dispose();
		}
	});

	test('settles a late existing-item publication after Review becomes inactive', async () => {
		// Arrange: establish an already-rendered item before the surface switch.
		const harness = makeReviewSurfaceHarness();
		const receipts: BridgeWorkerRenderDispositionReceipt[] = [];
		const coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (receipt): void => {
				receipts.push(receipt);
			},
		});
		const modeProps = {
			codeViewWorkerPoolEnabled: false,
			isNavigationCommandStillEligible: bridgeReviewNavigationCommandIsAlwaysEligible,
			onActiveSourceChange: vi.fn(),
			onNavigationSourceChange: vi.fn(),
			reviewClient: { ...harness.reviewClient, renderFulfillmentCoordinator: coordinator },
			telemetryRecorderRef: { current: createBridgeTelemetryRecorder(null) },
			viewerContextSwitcher: <div />,
		};
		const rendered = await render(<BridgeReviewViewerMode {...modeProps} isActive />);
		try {
			await act(async (): Promise<void> => {
				harness.publish(hierarchicalReviewDisplayEvent());
				await import('../review-viewer/shell/review-viewer-shell.js');
				await settleRenderedReviewFrame();
				for (const message of reviewContentReadyEvents()) harness.publish(message);
				await settleRenderedReviewFrame();
			});
			await expect
				.poll(() => receipts.some((receipt) => receipt.disposition === 'queued'))
				.toBe(true);

			// Act: a publication already in flight arrives after demand has stopped.
			await act(async (): Promise<void> => {
				await rendered.rerender(<BridgeReviewViewerMode {...modeProps} isActive={false} />);
				await settleRenderedReviewFrame();
				for (const message of reviewContentReadyEvents(3)) harness.publish(message);
				await settleRenderedReviewFrame();
			});

			// Assert: hidden content must not hold a worker publication position forever.
			await expect
				.poll(() =>
					receipts.some(
						(receipt) =>
							receipt.publicationSequence === 3 &&
							['queued', 'rejected', 'superseded'].includes(receipt.disposition),
					),
				)
				.toBe(true);
		} finally {
			await act(async (): Promise<void> => {
				await rendered.unmount();
			});
			coordinator.dispose();
		}
	});

	test('settles a late offscreen existing-item publication after Review becomes inactive', async () => {
		// Arrange: establish a large current catalog whose final item never enters the active viewport.
		const harness = makeReviewSurfaceHarness();
		const receipts: BridgeWorkerRenderDispositionReceipt[] = [];
		const coordinator = createBridgeMainRenderFulfillmentCoordinator({
			sendDisposition: (receipt): void => {
				receipts.push(receipt);
			},
		});
		const modeProps = {
			codeViewWorkerPoolEnabled: false,
			isNavigationCommandStillEligible: bridgeReviewNavigationCommandIsAlwaysEligible,
			onActiveSourceChange: vi.fn(),
			onNavigationSourceChange: vi.fn(),
			reviewClient: { ...harness.reviewClient, renderFulfillmentCoordinator: coordinator },
			telemetryRecorderRef: { current: createBridgeTelemetryRecorder(null) },
			viewerContextSwitcher: <div />,
		};
		const renderContainer = document.createElement('div');
		renderContainer.style.height = '240px';
		renderContainer.style.overflow = 'hidden';
		renderContainer.style.width = '960px';
		document.body.append(renderContainer);
		const rendered = await render(<BridgeReviewViewerMode {...modeProps} isActive />, {
			container: renderContainer,
		});
		const offscreenItemId = 'item-64';
		const offscreenPath = 'Sources/File-64.swift';
		try {
			await act(async (): Promise<void> => {
				harness.publish(largeReviewDisplayEvent(64));
				await import('../review-viewer/shell/review-viewer-shell.js');
				await settleRenderedReviewFrame();
				for (const message of reviewContentReadyEvents()) harness.publish(message);
				await settleRenderedReviewFrame();
				for (const message of reviewContentReadyEvents(
					2,
					offscreenItemId,
					offscreenPath,
					'nearby',
					'initial',
				)) {
					harness.publish(message);
				}
				await settleRenderedReviewFrame();
			});
			await expect
				.poll(() =>
					receipts.some(
						(receipt) =>
							receipt.publicationSequence === 2 &&
							receipt.itemId === offscreenItemId &&
							receipt.disposition === 'queued',
					),
				)
				.toBe(true);
			await act(async (): Promise<void> => {
				await settleRenderedReviewFrame();
			});
			expect(
				harness.reviewClient.renderStore.getReviewCodeViewItemSnapshot(offscreenItemId),
			).toMatchObject({
				bridgeMetadata: {
					cacheKey: 'pierre-content:item-64:initial:base|pierre-content:item-64:initial:head',
					contentState: 'hydrated',
				},
			});
			const finalActiveViewport = requireDefined(
				harness.sentCommands.findLast(
					(
						command,
					): command is Extract<
						(typeof harness.sentCommands)[number],
						{ readonly command: 'viewport' }
					> => command.command === 'viewport' && command.visibleItemIds.length > 0,
				),
				'Expected a settled nonempty Review viewport from constrained CodeView geometry.',
			);
			expect(finalActiveViewport.visibleItemIds).not.toContain(offscreenItemId);

			// Act: clear Review demand, then deliver a publication for the existing offscreen item.
			await act(async (): Promise<void> => {
				await rendered.rerender(<BridgeReviewViewerMode {...modeProps} isActive={false} />);
				await settleRenderedReviewFrame();
				for (const message of reviewContentReadyEvents(
					3,
					offscreenItemId,
					offscreenPath,
					'nearby',
					'replacement',
				)) {
					harness.publish(message);
				}
				await settleRenderedReviewFrame();
			});

			// Assert: non-visible existing content cannot retain an outstanding worker position.
			await expect
				.poll(() =>
					receipts.some(
						(receipt) =>
							receipt.publicationSequence === 3 &&
							receipt.itemId === offscreenItemId &&
							['queued', 'rejected', 'superseded'].includes(receipt.disposition),
					),
				)
				.toBe(true);
			expect(
				harness.reviewClient.renderStore.getReviewCodeViewItemSnapshot(offscreenItemId),
			).toMatchObject({
				bridgeMetadata: {
					cacheKey:
						'pierre-content:item-64:replacement:base|pierre-content:item-64:replacement:head',
					contentState: 'hydrated',
				},
			});
			const latestViewport = harness.sentCommands.findLast(
				(command) => command.command === 'viewport',
			);
			expect(latestViewport).toMatchObject({
				command: 'viewport',
				phase: 'settled',
				visibleItemIds: [],
			});
		} finally {
			await act(async (): Promise<void> => {
				await rendered.unmount();
			});
			coordinator.dispose();
			renderContainer.remove();
		}
	});

	test('retries timed-out Review intake-ready delivery until acknowledgement with newer shared epochs', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<ReviewIntakeLifecycleProbe reviewClient={harness.reviewClient} />,
		);
		await expect.element(rendered.getByTestId('review-intake-lifecycle-probe')).toBeInTheDocument();
		const initialRequestId = requireDefined(
			reviewIntakeReadyRequestIds(harness.lifecycleStore)[0],
			'Expected an initial Review intake-ready request.',
		);

		// Act: fail the flushed initial request after the component has already rendered.
		await act(async (): Promise<void> => {
			harness.lifecycleStore.timeoutRequest({ requestId: initialRequestId });
			await Promise.resolve();
		});

		// Assert: exactly one retry uses the next shared Review epoch.
		const retriedCommands = reviewIntakeReadyCommands(harness.sentCommands);
		expect(retriedCommands).toHaveLength(2);
		const initialCommand = requireDefined(
			retriedCommands[0],
			'Expected the initial Review intake-ready command.',
		);
		const retryCommand = requireDefined(
			retriedCommands[1],
			'Expected a retried Review intake-ready command.',
		);
		expect(retryCommand.epoch).toBeGreaterThan(initialCommand.epoch);
		const retryRequestId = requireDefined(
			reviewIntakeReadyRequestIds(harness.lifecycleStore)[1],
			'Expected a retried Review intake-ready request.',
		);

		// Act: acknowledge the retry, rerender, then exercise later select and viewport intents.
		await act(async (): Promise<void> => {
			harness.lifecycleStore.ackRequest({
				acknowledgedAtSequence: 1,
				requestId: retryRequestId,
			});
			await rendered.rerender(<ReviewIntakeLifecycleProbe reviewClient={harness.reviewClient} />);
			await Promise.resolve();
		});
		expect(reviewIntakeReadyCommands(harness.sentCommands)).toHaveLength(2);
		await act(async (): Promise<void> => {
			requireHTMLElement(
				document.querySelector('[data-testid="review-intake-lifecycle-probe"]'),
			).click();
			await Promise.resolve();
		});
		await expect
			.poll(() =>
				harness.sentCommands.some(
					(command) =>
						command.command === 'viewport' && command.visibleItemIds.includes('item-after-intake'),
				),
			)
			.toBe(true);

		// Assert: acknowledgement is terminal and subsequent Review intents remain newer.
		const retryEpoch = retryCommand.epoch;
		const laterSelectCommand = harness.sentCommands.findLast(
			(command) => command.command === 'select',
		);
		const laterViewportCommand = harness.sentCommands.findLast(
			(command) =>
				command.command === 'viewport' && command.visibleItemIds.includes('item-after-intake'),
		);
		expect(laterSelectCommand?.epoch).toBeGreaterThan(retryEpoch);
		expect(laterViewportCommand?.epoch).toBeGreaterThan(retryEpoch);
		expect(reviewIntakeReadyCommands(harness.sentCommands)).toHaveLength(2);
	});

	test('renews Review intake readiness when the publication integration lifetime changes', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const initialPierreCourier = createBridgeReviewWorkerPierreCourier();
		const replacementPierreCourier = createBridgeReviewWorkerPierreCourier();
		const rendered = await render(
			<ReviewIntakeLifecycleProbe
				pierreCourier={initialPierreCourier}
				reviewClient={harness.reviewClient}
			/>,
		);
		await expect.element(rendered.getByTestId('review-intake-lifecycle-probe')).toBeInTheDocument();
		const initialRequestId = requireDefined(
			reviewIntakeReadyRequestIds(harness.lifecycleStore)[0],
			'Expected an initial Review intake-ready request.',
		);
		await act(async (): Promise<void> => {
			harness.lifecycleStore.ackRequest({
				acknowledgedAtSequence: 1,
				requestId: initialRequestId,
			});
			await Promise.resolve();
		});

		// Act
		await act(async (): Promise<void> => {
			await rendered.rerender(
				<ReviewIntakeLifecycleProbe
					pierreCourier={replacementPierreCourier}
					reviewClient={harness.reviewClient}
				/>,
			);
			await Promise.resolve();
		});

		// Assert
		const intakeReadyCommands = reviewIntakeReadyCommands(harness.sentCommands);
		expect(intakeReadyCommands).toHaveLength(2);
		expect(intakeReadyCommands[1]?.epoch).toBeGreaterThan(intakeReadyCommands[0]?.epoch ?? 0);
	});

	test('bounds unacknowledged Review intake-ready delivery attempts', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const rendered = await render(
			<ReviewIntakeLifecycleProbe reviewClient={harness.reviewClient} />,
		);
		await expect.element(rendered.getByTestId('review-intake-lifecycle-probe')).toBeInTheDocument();

		// Act: exhaust each permitted attempt without acknowledging delivery.
		for (let attemptIndex = 0; attemptIndex < 3; attemptIndex += 1) {
			const requestId = requireDefined(
				reviewIntakeReadyRequestIds(harness.lifecycleStore)[attemptIndex],
				`Expected Review intake-ready request ${attemptIndex + 1}.`,
			);
			// oxlint-disable-next-line no-await-in-loop -- Each timeout synchronously creates the next bounded attempt.
			await act(async (): Promise<void> => {
				harness.lifecycleStore.timeoutRequest({ requestId });
				await Promise.resolve();
			});
		}
		await rendered.rerender(<ReviewIntakeLifecycleProbe reviewClient={harness.reviewClient} />);

		// Assert
		expect(reviewIntakeReadyCommands(harness.sentCommands)).toHaveLength(3);
	});
	test('keeps an inactive recovered Review mount stable across a streamed metadata-window burst', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const streamedWindowCount = 32;
		const rendered = await render(
			<BridgeReviewViewerMode
				isActive={false}
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={vi.fn()}
				onNavigationSourceChange={vi.fn()}
				reviewClient={harness.reviewClient}
				telemetryRecorderRef={{ current: createBridgeTelemetryRecorder(null) }}
				viewerContextSwitcher={<div />}
			/>,
		);
		await expect.element(rendered.getByTestId('bridge-review-fallback-frame')).toBeInTheDocument();
		// Act
		await act(async (): Promise<void> => {
			for (let windowIndex = 0; windowIndex < streamedWindowCount; windowIndex += 1) {
				harness.publish(
					reviewDisplayEvent({
						itemId: `item-${windowIndex + 1}`,
						path: `Sources/Streamed-${windowIndex + 1}.swift`,
						publicationRevision: streamedWindowCount,
						projectionRevision: windowIndex + 1,
						sequence: windowIndex + 1,
						startIndex: windowIndex,
						totalItemCount: streamedWindowCount,
					}),
					{ completesReviewPublication: windowIndex === streamedWindowCount - 1 },
				);
			}
			await Promise.resolve();
		});
		// Assert
		await expect.element(rendered.getByTestId('bridge-review-fallback-frame')).toBeInTheDocument();
		expect(document.querySelector('[data-testid="review-viewer-shell"]')).toBeNull();
		await expect
			.poll(() => harness.reviewClient.renderStore.getReviewCatalogSnapshot().revision)
			.toBe(streamedWindowCount);
		expect(harness.reviewClient.renderStore.getReviewCatalogSnapshot()).toMatchObject({
			itemOrderLength: streamedWindowCount,
			revision: streamedWindowCount,
			treeRowOrderLength: streamedWindowCount,
		});
		expect(
			harness.reviewClient.renderStore.getReviewTreeRowSnapshot(`row-item-${streamedWindowCount}`),
		).toMatchObject({
			itemId: `item-${streamedWindowCount}`,
			path: `Sources/Streamed-${streamedWindowCount}.swift`,
		});
		const viewportCommands = harness.sentCommands.filter(
			(command) => command.command === 'viewport',
		);
		expect(viewportCommands).toHaveLength(1);
		expect(viewportCommands[0]).toMatchObject({
			command: 'viewport',
			phase: 'settled',
			visibleItemIds: [],
		});
		expect(viewportCommands.filter((command) => command.visibleItemIds.length > 0)).toEqual([]);
	});
	test('reports a semantically stable File display source once across streamed patches', async () => {
		// Arrange
		const harness = makeFileSurfaceHarness();
		const reportedSources: Array<{ readonly generation: number; readonly sourceId: string }> = [];
		const rendered = await render(
			<BridgeFileViewerSurfaceClientProvider surfaceClient={harness.fileViewClient}>
				<FileDisplaySourceProbe
					onDisplaySourceChange={(source): void => {
						if (source !== null) reportedSources.push(source);
					}}
				/>
			</BridgeFileViewerSurfaceClientProvider>,
		);
		await expect.element(rendered.getByTestId('file-display-source-probe')).toBeInTheDocument();
		// Act
		for (let patchIndex = 0; patchIndex < 32; patchIndex += 1) {
			// oxlint-disable-next-line no-await-in-loop -- Separate React commits reproduce the passive-effect update boundary.
			await act(async (): Promise<void> => {
				harness.publish(
					fileDisplayEvent({
						projectionRevision: patchIndex + 1,
						sequence: patchIndex + 1,
					}),
				);
				await Promise.resolve();
			});
		}
		// Assert
		expect(reportedSources).toEqual([{ generation: 1, sourceId: 'source-1' }]);
	});
	test('mounts terminal Review content from worker display and Pierre messages', async () => {
		// Arrange
		const harness = makeReviewSurfaceHarness();
		const onActiveSourceChange = vi.fn();
		const telemetryRecorderRef = { current: createBridgeTelemetryRecorder(null) };
		const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (frameHandle): void => cancelAnimationFrame(frameHandle),
			nowMilliseconds: (): number => performance.now(),
			requestAnimationFrame: (callback): number => requestAnimationFrame(callback),
			sendDisposition: (): void => {},
		});
		const reviewClient = {
			...harness.reviewClient,
			renderFulfillmentCoordinator,
		};
		const renderContainer = document.createElement('div');
		renderContainer.style.height = '100vh';
		renderContainer.style.width = '100vw';
		document.body.append(renderContainer);
		const rendered = await render(
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive={true}
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				onActiveSourceChange={onActiveSourceChange}
				onNavigationSourceChange={vi.fn()}
				reviewClient={reviewClient}
				telemetryRecorderRef={telemetryRecorderRef}
				viewerContextSwitcher={<div />}
			/>,
			{ container: renderContainer },
		);

		// Act
		await act(async (): Promise<void> => {
			harness.publish(hierarchicalReviewDisplayEvent());
			await import('../review-viewer/shell/review-viewer-shell.js');
			await settleRenderedReviewFrame();
		});
		await expect
			.poll(() => harness.sentCommands.some((command) => command.command === 'select'))
			.toBe(true);
		await expect.element(rendered.getByTestId('bridge-review-trees-panel')).toBeInTheDocument();
		await act(async (): Promise<void> => {
			for (const message of reviewContentReadyEvents()) harness.publish(message);
			await settleRenderedReviewFrame();
		});

		// Assert
		const shell = rendered.getByTestId('review-viewer-shell');
		const codePanel = rendered.getByTestId('bridge-code-view-panel');
		await expect.element(rendered.getByTestId('bridge-review-trees-panel')).toBeInTheDocument();
		await expect.element(shell).toHaveAttribute('data-selected-content-state', 'ready');
		await expect
			.element(shell)
			.toHaveAttribute('data-selected-display-path', 'Sources/First.swift');
		await expect
			.element(codePanel)
			.toHaveAttribute('data-selected-display-path', 'Sources/First.swift');
		const codePanelElement = requireHTMLElement(
			document.querySelector('[data-testid="bridge-code-view-panel"]'),
		);
		expect(
			Number(codePanelElement.getAttribute('data-selected-content-character-count')),
		).toBeGreaterThan(0);
		expect(
			Number(codePanelElement.getAttribute('data-selected-content-line-count')),
		).toBeGreaterThan(0);
		expect(
			Number(codePanelElement.getAttribute('data-selected-content-cache-key-count')),
		).toBeGreaterThan(0);
		expect(document.querySelectorAll('[data-testid="review-viewer-shell"]')).toHaveLength(1);
		expect(document.querySelector('[data-testid="bridge-review-tree-scroll"]')).toBeNull();
		await expect
			.poll(() =>
				harness.sentCommands.some(
					(command) => command.command === 'viewport' && command.visibleItemIds.length > 0,
				),
			)
			.toBe(true);
		await act(async (): Promise<void> => {
			await settleRenderedReviewFrame();
		});
		const viewportCommandCountBeforeDeactivation = harness.sentCommands.filter(
			(command) => command.command === 'viewport',
		).length;
		const commandCountBeforeViewSettingChange = harness.sentCommands.length;
		const reviewShellElement = requireHTMLElement(
			document.querySelector('[data-testid="review-viewer-shell"]'),
		);
		const reviewIdentityBeforeViewSettingChange = {
			generation: reviewShellElement.getAttribute('data-review-metadata-generation'),
			packageId: reviewShellElement.getAttribute('data-review-metadata-id'),
			selectedPath: reviewShellElement.getAttribute('data-selected-display-path'),
		};
		const codePanelBeforeViewSettingChange = requireHTMLElement(
			document.querySelector('[data-testid="bridge-code-view-panel"]'),
		);

		// Act: change Review rendering through the real full-surface gear menu.
		await act(async (): Promise<void> => {
			requireHTMLElement(
				document.querySelector('[data-testid="bridge-review-view-settings-trigger"]'),
			).click();
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			const wordWrapRow = [...document.querySelectorAll<HTMLElement>('[role="switch"]')].find(
				(row): boolean => row.getAttribute('aria-label') === 'Word wrap',
			);
			if (wordWrapRow === undefined) throw new Error('Missing Review Word wrap setting');
			wordWrapRow.click();
			await settleRenderedReviewFrame();
		});

		// Assert: rendering changes without selection, source, session command, or shell replacement.
		expect(
			requireHTMLElement(document.querySelector('[data-testid="bridge-code-view-panel"]')),
		).toBe(codePanelBeforeViewSettingChange);
		expect({
			generation: reviewShellElement.getAttribute('data-review-metadata-generation'),
			packageId: reviewShellElement.getAttribute('data-review-metadata-id'),
			selectedPath: reviewShellElement.getAttribute('data-selected-display-path'),
		}).toEqual(reviewIdentityBeforeViewSettingChange);
		expect(harness.sentCommands).toHaveLength(commandCountBeforeViewSettingChange);
		await expect.element(codePanel).toHaveAttribute('data-bridge-code-view-overflow', 'scroll');

		// Act: retain the recovered shell while Review becomes inactive.
		await act(async (): Promise<void> => {
			await rendered.rerender(
				<BridgeReviewViewerMode
					codeViewWorkerPoolEnabled={false}
					isActive={false}
					isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
					onActiveSourceChange={onActiveSourceChange}
					onNavigationSourceChange={vi.fn()}
					reviewClient={reviewClient}
					telemetryRecorderRef={telemetryRecorderRef}
					viewerContextSwitcher={<div />}
				/>,
			);
			await settleRenderedReviewFrame();
		});

		// Assert: one transition clear replaces foreground Review demand.
		const viewportCommands = harness.sentCommands.filter(
			(command) => command.command === 'viewport',
		);
		const deactivationViewportCommands = viewportCommands.slice(
			viewportCommandCountBeforeDeactivation,
		);
		expect(deactivationViewportCommands).toHaveLength(1);
		expect(deactivationViewportCommands[0]).toMatchObject({
			command: 'viewport',
			phase: 'settled',
			visibleItemIds: [],
		});
		renderFulfillmentCoordinator.dispose();
	});
});

function largeReviewDisplayEvent(itemCount: number): BridgeWorkerReviewDisplayPatchEvent {
	const baseline = hierarchicalReviewDisplayEvent();
	const items = Array.from({ length: itemCount }, (_, index) => {
		const itemOrdinal = index + 1;
		return reviewDisplayItem(`item-${itemOrdinal}`, `Sources/File-${itemOrdinal}.swift`);
	});
	const rows: BridgeProductReviewTreeRow[] = [
		{
			depth: 0,
			isDirectory: true,
			itemId: null,
			path: 'Sources',
			rowId: 'row-sources',
		},
		...items.map((item, index) => ({
			depth: 1,
			isDirectory: false,
			itemId: item.metadata.itemId,
			path: `Sources/File-${index + 1}.swift`,
			rowId: `row-${index + 1}`,
		})),
	];
	return {
		...baseline,
		patches: baseline.patches.map(
			(patch): BridgeWorkerReviewDisplayPatchEvent['patches'][number] => {
				if (patch.slice === 'reviewSource' && patch.operation === 'upsert') {
					return Object.assign({}, patch, {
						payload: {
							...patch.payload,
							summary: {
								additions: itemCount,
								deletions: 0,
								filesChanged: itemCount,
								hiddenFileCount: 0,
								visibleFileCount: itemCount,
							},
							totalItemCount: itemCount,
							totalTreeRowCount: rows.length,
						},
					});
				}
				if (patch.slice === 'reviewItem' && patch.operation === 'batch') {
					return Object.assign({}, patch, {
						payload: { ...patch.payload, items },
					});
				}
				if (patch.slice === 'reviewTree' && patch.operation === 'batch') {
					return Object.assign({}, patch, {
						payload: { ...patch.payload, windows: [{ rows, startIndex: 0 }] },
					});
				}
				return patch;
			},
		),
	};
}

function reviewContentReadyEvents(
	publicationSequence = 2,
	itemId = 'item-1',
	displayPath = 'Sources/First.swift',
	bridgeDemandLane: Parameters<
		typeof buildBridgeWorkerPierreRenderJob
	>[0]['bridgeDemandRank']['lane'] = 'selected',
	contentVariant: string | null = null,
): readonly BridgeWorkerServerToMainMessage[] {
	const cacheIdentity = contentVariant === null ? itemId : `${itemId}:${contentVariant}`;
	const baseCacheKey = `pierre-content:${cacheIdentity}:base`;
	const headCacheKey = `pierre-content:${cacheIdentity}:head`;
	const job = buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank: { lane: bridgeDemandLane, priority: 0 },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		contentCacheKey: `${baseCacheKey}|${headCacheKey}`,
		contentHash: `review-content-${cacheIdentity}`,
		itemId,
		language: 'swift',
		payload: {
			item: {
				bridgeMetadata: {
					cacheKey: `${baseCacheKey}|${headCacheKey}`,
					contentRoles: ['base', 'head'],
					contentState: 'hydrated',
					displayPath,
					itemId,
					lineCount: 2,
				},
				fileDiff: parseDiffFromFile(
					{
						cacheKey: baseCacheKey,
						contents: 'let answer = 41\n',
						name: displayPath,
					},
					{
						cacheKey: headCacheKey,
						contents: 'let answer = 42\n',
						name: displayPath,
					},
				),
				id: itemId,
				type: 'diff',
				version: 1,
			},
			kind: 'codeViewDiffItem',
		},
		renderKind: 'reviewDiff',
		window: { endLine: 2, startLine: 1, totalLineCount: 2 },
	});
	return [
		{
			direction: 'serverWorkerToMain',
			job,
			kind: 'reviewPierreRenderJob',
			reviewPublicationIdentity: TEST_REVIEW_PUBLICATION_IDENTITY,
			publicationSequence,
			renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
				itemId: job.itemId,
				publicationSequence,
				surface: 'review',
				workerDerivationEpoch: 1,
			}),
			surface: 'review',
			transferDescriptors: [
				{
					byteLength: job.payloadByteLength,
					fieldPath: ['job', 'payload'],
					messageKind: 'reviewPierreRenderJob',
					mode: 'clone',
				},
			],
			wireVersion: 1,
			workerDerivationEpoch: 1,
		},
		{
			direction: 'serverWorkerToMain',
			kind: 'reviewRenderPatch',
			reviewPublicationIdentity: TEST_REVIEW_PUBLICATION_IDENTITY,
			patches: [
				{
					itemId,
					operation: 'upsert',
					payload: { contentCacheKey: `${baseCacheKey}|${headCacheKey}` },
					slice: 'rowPaint',
				},
				{
					itemId,
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
			publicationSequence,
			surface: 'review',
			transferDescriptors: [],
			wireVersion: 1,
			workerDerivationEpoch: 1,
		},
	];
}
