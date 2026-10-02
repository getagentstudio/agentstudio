import { useMemo, type ReactElement } from 'react';
import { vi } from 'vitest';

import {
	buildBridgeWorkerReviewCandidateReadyEvent,
	buildBridgeWorkerReviewCandidateStartedEvent,
	buildBridgeWorkerReviewPublicationInstallAdmissionEvent,
} from '../core/comm-worker/bridge-comm-worker-protocol.js';
import {
	createBridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderFulfillmentCoordinator,
} from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { createBridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type {
	BridgeWorkerFileDisplayPatchEvent,
	BridgeWorkerReviewCandidateStartDisposition,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	bridgeWorkerReviewPublicationIdentity,
	bridgeWorkerReviewSourceContext,
} from '../core/comm-worker/bridge-worker-review-display.test-support.js';
import type { BridgeWorkerRpcCommandInput } from '../core/comm-worker/bridge-worker-rpc-client.js';
import {
	createBridgeWorkerRpcLifecycleStore,
	type BridgeWorkerRpcLifecycleStore,
} from '../core/comm-worker/bridge-worker-rpc-lifecycle-store.js';
import {
	bridgeFileViewerDisplayModelForSnapshot,
	type BridgeFileViewerDisplaySource,
} from '../file-viewer/bridge-file-viewer-display-model.js';
import { useBridgeFileViewerRenderSnapshotController } from '../file-viewer/bridge-file-viewer-render-snapshot-controller.js';
import { useBridgeFileViewerDisplaySourceReporter } from '../file-viewer/use-bridge-file-viewer-display-source-reporter.js';
import {
	hierarchicalReviewDisplayEvent,
	reviewDisplayItem,
} from './bridge-app-review-render-snapshot-controller.browser.test-support.js';
import {
	createBridgeReviewWorkerPierreCourier,
	useBridgeReviewRenderSnapshotController,
} from './bridge-app-review-render-snapshot-controller.js';
import { BridgePaneFailureMessage } from './bridge-region-presentation.js';
import type { BridgeReviewComparisonTarget } from './bridge-review-comparison-target.js';
import { BridgeViewerRecoveryRetryButton } from './bridge-viewer-recovery-retry-button.js';

export { hierarchicalReviewDisplayEvent };

const prepareNoActiveEditorsForInstallation = (): Promise<boolean> => Promise.resolve(true);

export function ReviewDirectDisplayProbe(props: {
	readonly reviewClient: BridgePaneSurfaceClient;
}): ReactElement {
	const pierreCourier = useMemo(() => createBridgeReviewWorkerPierreCourier(), []);
	const controller = useBridgeReviewRenderSnapshotController({
		pierreCourier,
		prepareActiveEditorsForInstallation: prepareNoActiveEditorsForInstallation,
		reviewClient: props.reviewClient,
	});
	return (
		<output
			data-review-item-order-length={controller.catalogSnapshot.itemOrderLength}
			data-review-later-row-path={controller.displayStore.getReviewTreeRowAtIndex(1)?.path ?? ''}
			data-review-source-status={controller.reviewSourceSlice?.status ?? 'absent'}
			data-review-tree-row-order-length={controller.catalogSnapshot.treeRowOrderLength}
			data-testid="review-direct-display-probe"
		/>
	);
}

export function ReviewRecoveryRetryProbe(props: {
	readonly comparisonTarget: BridgeReviewComparisonTarget | null;
	readonly reviewClient: BridgePaneSurfaceClient;
}): ReactElement {
	const pierreCourier = useMemo(() => createBridgeReviewWorkerPierreCourier(), []);
	const controller = useBridgeReviewRenderSnapshotController({
		pierreCourier,
		prepareActiveEditorsForInstallation: prepareNoActiveEditorsForInstallation,
		reviewClient: props.reviewClient,
	});
	return (
		<div>
			<BridgePaneFailureMessage
				entries={[
					{
						part: 'review',
						state:
							controller.viewRecoveryStatus?.status === 'failedRetryable'
								? {
										kind: 'failed',
										retainsContent: true,
										failure: { kind: 'retryable', scope: 'surface', message: 'Review failure' },
									}
								: { kind: 'content' },
						retry: (): void => controller.retryFailedMetadataView(props.comparisonTarget),
					},
				]}
				retryControl={(onClick): ReactElement => (
					<BridgeViewerRecoveryRetryButton surface="pane" onClick={onClick} />
				)}
			/>
			<output data-testid="last-good-review">
				{controller.displayStore.getReviewTreeRowAtIndex(0)?.path ?? ''}
			</output>
		</div>
	);
}

export function ReviewIntakeLifecycleProbe(props: {
	readonly pierreCourier?: ReturnType<typeof createBridgeReviewWorkerPierreCourier>;
	readonly reviewClient: BridgePaneSurfaceClient;
}): ReactElement {
	const defaultPierreCourier = useMemo(() => createBridgeReviewWorkerPierreCourier(), []);
	const controller = useBridgeReviewRenderSnapshotController({
		pierreCourier: props.pierreCourier ?? defaultPierreCourier,
		prepareActiveEditorsForInstallation: prepareNoActiveEditorsForInstallation,
		reviewClient: props.reviewClient,
	});
	return (
		<button
			data-testid="review-intake-lifecycle-probe"
			onClick={(): void => {
				controller.setReviewCodeViewVisibleItemIds(['item-after-intake']);
				controller.emitSelectedReviewItemIntent('item-after-intake', 'user');
			}}
			type="button"
		>
			Exercise later Review intents
		</button>
	);
}

export function FileDisplaySourceProbe(props: {
	readonly onDisplaySourceChange: (source: BridgeFileViewerDisplaySource | null) => void;
}): ReactElement {
	const renderSnapshotController = useBridgeFileViewerRenderSnapshotController({ selection: null });
	const displayModel = useMemo(
		() => bridgeFileViewerDisplayModelForSnapshot(renderSnapshotController.fileDisplaySnapshot),
		[renderSnapshotController.fileDisplaySnapshot],
	);
	useBridgeFileViewerDisplaySourceReporter({
		onDisplaySourceChange: props.onDisplaySourceChange,
		source: displayModel.source,
	});
	return <output data-testid="file-display-source-probe" />;
}

export interface ReviewSurfaceHarness {
	readonly lifecycleStore: BridgeWorkerRpcLifecycleStore;
	readonly publish: (
		message: BridgeWorkerServerToMainMessage,
		options?: {
			readonly candidateDisposition?: BridgeWorkerReviewCandidateStartDisposition;
			readonly completesReviewPublication?: boolean;
		},
	) => void;
	readonly reviewClient: BridgePaneSurfaceClient;
	readonly sentCommands: BridgeWorkerRpcCommandInput[];
}

export interface FileSurfaceHarness {
	readonly fileViewClient: BridgePaneSurfaceClient;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
}

export function makeFileSurfaceHarness(): FileSurfaceHarness {
	const displayStore = createBridgeMainRenderSnapshotStore();
	const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
	let messageListener: ((message: BridgeWorkerServerToMainMessage) => void) | null = null;
	return {
		fileViewClient: {
			requestWorkerReplacement: vi.fn(),
			lifecycle: lifecycleStore,
			renderFulfillmentCoordinator: createTestRenderFulfillmentCoordinator(),
			renderStore: displayStore,
			send: vi.fn((): string => 'file-request-1'),
			subscribeMessages: (listener): (() => void) => {
				messageListener = listener;
				return (): void => {
					messageListener = null;
				};
			},
			surface: 'fileView',
		},
		publish: (message): void => {
			if (messageListener === null) throw new Error('Expected the File message listener.');
			messageListener(message);
		},
	};
}

export function makeReviewSurfaceHarness(): ReviewSurfaceHarness {
	const displayStore = createBridgeMainRenderSnapshotStore();
	const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
	const sentCommands: BridgeWorkerRpcCommandInput[] = [];
	let messageListener: ((message: BridgeWorkerServerToMainMessage) => void) | null = null;
	return {
		lifecycleStore,
		publish: (message, options): void => {
			if (messageListener === null) throw new Error('Expected the Review message listener.');
			if (message.kind === 'reviewDisplayPatch' && message.reviewPublicationIdentity !== null) {
				const identity = message.reviewPublicationIdentity;
				const candidateSequence = message.sequence * 3;
				messageListener(
					buildBridgeWorkerReviewCandidateStartedEvent({
						disposition: options?.candidateDisposition ?? { kind: 'replacement' },
						epoch: message.epoch,
						packageId: identity.packageId,
						publicationId: identity.publicationId,
						reviewGeneration: identity.reviewGeneration,
						revision: identity.revision,
						sequence: candidateSequence,
						sourceIdentity: identity.sourceIdentity,
					}),
				);
				messageListener({ ...message, sequence: candidateSequence + 1 });
				if (options?.completesReviewPublication === false) return;
				messageListener(
					buildBridgeWorkerReviewCandidateReadyEvent({
						epoch: message.epoch,
						packageId: identity.packageId,
						publicationId: identity.publicationId,
						reviewGeneration: identity.reviewGeneration,
						revision: identity.revision,
						sequence: candidateSequence + 2,
						sourceIdentity: identity.sourceIdentity,
					}),
				);
				return;
			}
			messageListener(message);
		},
		reviewClient: {
			requestWorkerReplacement: vi.fn(),
			lifecycle: lifecycleStore,
			renderFulfillmentCoordinator: createTestRenderFulfillmentCoordinator(),
			renderStore: displayStore,
			send: vi.fn((command): string => {
				const requestId = `review-request-${sentCommands.length + 1}`;
				lifecycleStore.startRequest({
					command: command.command,
					requestId,
					surface: 'review',
				});
				sentCommands.push(command);
				if (command.command === 'reviewPublicationInstallAdmit') {
					queueMicrotask((): void => {
						messageListener?.(
							buildBridgeWorkerReviewPublicationInstallAdmissionEvent({
								candidatePublicationId: command.candidatePublicationId,
								requestId,
								status: 'admitted',
							}),
						);
					});
				} else if (command.command === 'reviewPublicationInstalled') {
					queueMicrotask((): void => {
						lifecycleStore.ackRequest({
							acknowledgedAtSequence: sentCommands.length,
							requestId,
						});
					});
				}
				return requestId;
			}),
			subscribeMessages: (listener): (() => void) => {
				messageListener = listener;
				return (): void => {
					messageListener = null;
				};
			},
			surface: 'review',
		},
		sentCommands,
	};
}

export function reviewIntakeReadyCommands(
	commands: readonly BridgeWorkerRpcCommandInput[],
): readonly Extract<BridgeWorkerRpcCommandInput, { readonly command: 'reviewIntakeReady' }>[] {
	return commands.filter(
		(
			command,
		): command is Extract<BridgeWorkerRpcCommandInput, { readonly command: 'reviewIntakeReady' }> =>
			command.command === 'reviewIntakeReady',
	);
}

export function reviewIntakeReadyRequestIds(
	lifecycleStore: BridgeWorkerRpcLifecycleStore,
): string[] {
	return Object.values(lifecycleStore.getSnapshot().requestsById)
		.filter((request) => request.command === 'reviewIntakeReady')
		.map((request) => request.requestId);
}

function createTestRenderFulfillmentCoordinator(): BridgeMainRenderFulfillmentCoordinator {
	return createBridgeMainRenderFulfillmentCoordinator({
		cancelAnimationFrame: (_frameHandle): void => {},
		nowMilliseconds: (): number => 0,
		requestAnimationFrame: (_callback): number => {
			throw new Error('Review Browser fixture must not schedule paint validation.');
		},
		sendDisposition: (_receipt): void => {},
	});
}

export function fileDisplayEvent(props: {
	readonly projectionRevision: number;
	readonly sequence: number;
}): BridgeWorkerFileDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: 1,
		kind: 'fileDisplayPatch',
		patches: [
			{
				operation: 'reset',
				payload: {
					sourceGeneration: 1,
					sourceId: 'source-1',
				},
				slice: 'fileTree',
			},
			{
				itemId: 'file-1',
				operation: 'upsert',
				payload: {
					availability: { kind: 'available' },
					displayPath: 'README.md',
					endsMidLine: false,
					endsWithNewline: true,
					extent: { kind: 'exactLineCount', lineCount: 1 },
					fileExtension: 'md',
					language: 'markdown',
					payloadByteCount: 6,
					payloadLineCount: 1,
					rowId: 'row-1',
					sizeBytes: 6,
					totalLineCount: 1,
					truncationKind: 'none',
				},
				slice: 'fileItem',
			},
		],
		projectionRevision: props.projectionRevision,
		sequence: props.sequence,
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function reviewDisplayEvent(props: {
	readonly itemId: string;
	readonly path: string;
	readonly publicationRevision?: number;
	readonly projectionRevision: number;
	readonly sequence: number;
	readonly startIndex: number;
	readonly totalItemCount?: number;
}): BridgeWorkerReviewDisplayPatchEvent {
	const totalItemCount = props.totalItemCount ?? 2;
	return {
		direction: 'serverWorkerToMain',
		epoch: 1,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentity(
			'review-browser-harness-package',
			props.publicationRevision ?? props.projectionRevision,
			'review-browser-harness-source',
		),
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext('review-browser-harness-package'),
					metadataSourceId: 'review-browser-harness-source',
					metadataWindowIdentity: `review-window-${props.projectionRevision}`,
					packageId: 'review-browser-harness-package',
					reviewGeneration: 1,
					revision: props.publicationRevision ?? props.projectionRevision,
					status: 'ready',
					summary: {
						additions: 1,
						deletions: 0,
						filesChanged: 2,
						hiddenFileCount: 0,
						visibleFileCount: 2,
					},
					totalItemCount,
					totalTreeRowCount: totalItemCount,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: [reviewDisplayItem(props.itemId, props.path)],
					operations: [],
					reset: props.startIndex === 0,
					startIndex: props.startIndex,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset: props.startIndex === 0,
					windows: [
						{
							rows: [
								{
									depth: 1,
									isDirectory: false,
									itemId: props.itemId,
									path: props.path,
									rowId: `row-${props.itemId}`,
								},
							],
							startIndex: props.startIndex,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision: props.projectionRevision,
		sequence: props.sequence,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function requireHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) throw new Error('Expected an HTML element.');
	return element;
}

export function requireDefined<TValue>(value: TValue | null | undefined, message: string): TValue {
	if (value === undefined || value === null) throw new Error(message);
	return value;
}

export async function settleRenderedReviewFrame(): Promise<void> {
	await Promise.resolve();
	await new Promise<void>((resolve) => {
		requestAnimationFrame((): void => resolve());
	});
	await Promise.resolve();
}

export function reviewDisplayEventWithContribution(
	props: Parameters<typeof reviewDisplayEvent>[0],
): ReturnType<typeof reviewDisplayEvent> {
	const event = reviewDisplayEvent(props);
	return {
		...event,
		// oxlint-disable-next-line no-map-spread -- The strict immutable fixture preserves every non-source patch while replacing one nested source payload.
		patches: event.patches.map((patch) =>
			patch.slice !== 'reviewSource' || patch.operation !== 'upsert'
				? patch
				: {
						...patch,
						payload: {
							...patch.payload,
							comparisonOrigin: {
								baseOID: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
								baseRole: 'commonCommit',
								comparedRole: 'capturedWorkingTree',
								kind: 'contribution',
								resolvedTargetOID: 'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm',
								reviewedHeadOID: 'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh',
								symbolicTarget: {
									basis: 'commonCommit',
									branchName: 'master',
									kind: 'localDefaultBranch',
								},
							},
						},
					},
		),
	};
}

const TEST_REVIEW_PUBLICATION_IDENTITY = {
	packageId: 'test-review-package',
	publicationId: '00000000-0000-7000-8000-000000000001',
	reviewGeneration: 1,
	revision: 1,
	sourceIdentity: 'test-review-source',
} as const;

export function reviewComparisonPanelChromeEvent(): Extract<
	BridgeWorkerServerToMainMessage,
	{ readonly kind: 'reviewRenderPatch' }
> {
	return {
		direction: 'serverWorkerToMain',
		kind: 'reviewRenderPatch',
		reviewPublicationIdentity: TEST_REVIEW_PUBLICATION_IDENTITY,
		patches: [
			{
				operation: 'upsert',
				payload: {
					reviewComparison: {
						activeTarget: {
							basis: 'commonCommit',
							branchName: 'master',
							kind: 'localDefaultBranch',
						},
						attempt: { reviewGeneration: 1, status: 'settled' },
						displayedSnapshot: { status: 'none' },
						repositoryDefaultTarget: null,
					},
				},
				slice: 'panelChrome',
			},
		],
		publicationSequence: 1,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
		workerDerivationEpoch: 1,
	};
}

export function reviewComparisonPanelChromeEventForHarness(): ReturnType<
	typeof reviewComparisonPanelChromeEvent
> {
	return {
		...reviewComparisonPanelChromeEvent(),
		reviewPublicationIdentity: {
			packageId: 'review-browser-harness-package',
			publicationId: '00000000-0000-7000-8000-000000000001',
			reviewGeneration: 1,
			revision: 1,
			sourceIdentity: 'review-browser-harness-source',
		},
	};
}

export function reviewComparisonLoadingPanelChromeEventForHarness(
	props: {
		readonly activeTarget?: BridgeReviewComparisonTarget;
	} = {},
): ReturnType<typeof reviewComparisonPanelChromeEvent> {
	const event = reviewComparisonPanelChromeEventForHarness();
	return {
		...event,
		// oxlint-disable-next-line no-map-spread -- The strict immutable fixture preserves every non-panel patch while replacing one nested panel payload.
		patches: event.patches.map((patch) =>
			patch.slice !== 'panelChrome' || patch.operation !== 'upsert'
				? patch
				: {
						...patch,
						payload: {
							reviewComparison: {
								activeTarget: props.activeTarget ?? {
									basis: 'commonCommit',
									branchName: 'master',
									kind: 'localDefaultBranch',
								},
								attempt: { reviewGeneration: 2, status: 'pending' },
								displayedSnapshot: {
									packageId: 'review-browser-harness-package',
									reviewGeneration: 1,
									revision: 1,
									status: 'current',
								},
								repositoryDefaultTarget: null,
							},
						},
					},
		),
	};
}
