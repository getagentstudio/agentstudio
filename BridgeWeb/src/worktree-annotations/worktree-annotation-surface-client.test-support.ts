import type { BridgeWorkerAnnotationProjectionSnapshot } from '../core/comm-worker/bridge-comm-worker-annotation-projection-decoder.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { createBridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { createBridgeWorkerRpcLifecycleStore } from '../core/comm-worker/bridge-worker-rpc-lifecycle-store.js';
import type { BridgeTelemetrySample } from '../foundation/telemetry/bridge-telemetry-event.js';
import { createWorktreeAnnotationSurfaceClient } from './worktree-annotation-surface-client.js';

export const sessionId = '00000000-0000-7000-8000-000000000011';
export const siblingSessionId = '00000000-0000-7000-8000-000000000014';
export const threadId = '00000000-0000-7000-8000-000000000012';
export const messageId = '00000000-0000-7000-8000-000000000013';

export function createSurfaceClientHarness(
	workerRequestIds: readonly string[] = ['worker-save-1'],
	surface: 'fileView' | 'review' = 'fileView',
	hasInstalledReviewIdentity = true,
): {
	readonly client: ReturnType<typeof createWorktreeAnnotationSurfaceClient>;
	readonly fireWorkerReplacement: () => void;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly sentCommands: Array<Parameters<BridgePaneSurfaceClient['send']>[0]>;
	readonly telemetrySamples: BridgeTelemetrySample[];
} {
	let listener: ((message: BridgeWorkerServerToMainMessage) => void) | null = null;
	const workerReplacementListeners = new Set<() => void>();
	let nextWorkerRequestIndex = 0;
	let catalogStaged = false;
	const sentCommands: Parameters<BridgePaneSurfaceClient['send']>[0][] = [];
	const telemetrySamples: BridgeTelemetrySample[] = [];
	const renderStore = createBridgeMainRenderSnapshotStore();
	if (surface === 'review' && hasInstalledReviewIdentity) {
		Object.defineProperty(renderStore, 'getReviewRefreshPresentation', {
			value: () => ({ activeIdentity: reviewMainIdentity, candidate: null }),
		});
	}
	const surfaceClient = {
		requestWorkerReplacement: (): void => {},
		lifecycle: createBridgeWorkerRpcLifecycleStore(),
		renderFulfillmentCoordinator: createBridgeMainRenderFulfillmentCoordinator({
			cancelAnimationFrame: (): void => {},
			requestAnimationFrame: (): number => 1,
			sendDisposition: (): void => {},
		}),
		renderStore,
		send: (command): string => {
			sentCommands.push(command);
			const requestId = workerRequestIds[nextWorkerRequestIndex];
			nextWorkerRequestIndex += 1;
			return requestId ?? `worker-save-${nextWorkerRequestIndex.toString()}`;
		},
		subscribeMessages: (
			nextListener: (message: BridgeWorkerServerToMainMessage) => void,
		): (() => void) => {
			listener = nextListener;
			return (): void => {
				listener = null;
			};
		},
		subscribeWorkerReplacement: (replacementListener: () => void): (() => void) => {
			workerReplacementListeners.add(replacementListener);
			return (): void => {
				workerReplacementListeners.delete(replacementListener);
			};
		},
		surface,
	} satisfies BridgePaneSurfaceClient;
	return {
		client: createWorktreeAnnotationSurfaceClient(surfaceClient, {
			flush: (): boolean => true,
			isEnabled: (): boolean => true,
			measure: (props) => props.operation(),
			record: (sample): void => {
				telemetrySamples.push(sample);
			},
		}),
		fireWorkerReplacement: (): void => {
			for (const replacementListener of workerReplacementListeners) replacementListener();
		},
		publish: (message): void => {
			if (
				!catalogStaged &&
				message.kind === 'annotationProjectionConvergence' &&
				message.state.kind === 'ready' &&
				message.surface === surface
			) {
				catalogStaged = true;
				for (const catalogMessage of catalogStagingMessages(
					message.state.snapshot.projectionRevision,
					surface,
				)) {
					listener?.(catalogMessage);
				}
			}
			listener?.(message);
		},
		sentCommands,
		telemetrySamples,
	};
}

export function catalogStagingMessages(
	catalogRevision: number,
	surface: 'fileView' | 'review',
	includeSession = true,
): readonly Extract<
	BridgeWorkerServerToMainMessage,
	{ readonly kind: 'annotationCatalogStaging' }
>[] {
	const authority = {
		subscriptionId: `${surface}-annotation-subscription-1`,
		workerDerivationEpoch: 1,
		worktreeId: 'worktree-1',
	} as const;
	const transferId = `${surface}-annotation-catalog-${catalogRevision}`;
	const entries = includeSession
		? [
				{ kind: 'session' as const, semanticRevision: catalogRevision, sessionId },
				{
					createdOrdinal: 0,
					kind: 'thread' as const,
					scope: 'located' as const,
					sessionId,
					threadId,
				},
				{ kind: 'message' as const, messageId, ordinal: 0, threadId },
			]
		: [];
	const common = {
		authority,
		direction: 'serverWorkerToMain' as const,
		kind: 'annotationCatalogStaging' as const,
		surface,
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
	return [
		{
			...common,
			transfer: {
				catalogRevision,
				expectedEntryCount: entries.length,
				kind: 'catalog.begin',
				transferId,
			},
		},
		...(entries.length === 0
			? []
			: [
					{
						...common,
						transfer: {
							catalogRevision,
							entries,
							kind: 'catalog.window' as const,
							transferId,
							windowOrdinal: 0,
						},
					},
				]),
		{
			...common,
			transfer: {
				catalogRevision,
				entryCount: entries.length,
				kind: 'catalog.commit',
				transferId,
				windowCount: entries.length === 0 ? 0 : 1,
			},
		},
	];
}

export const reviewPublicationIdentity = {
	packageId: 'package-installed',
	publicationId: '00000000-0000-7000-8000-000000000041',
	reviewGeneration: 7,
	revision: 3,
	sourceIdentity: 'source-installed',
} as const;

export const reviewMainIdentity = {
	generation: reviewPublicationIdentity.reviewGeneration,
	packageId: reviewPublicationIdentity.packageId,
	publicationId: reviewPublicationIdentity.publicationId,
	revision: reviewPublicationIdentity.revision,
	sourceIdentity: reviewPublicationIdentity.sourceIdentity,
} as const;

export function projectionSnapshot(
	projectionRevision: number,
	sourceGeneration: number,
): BridgeWorkerAnnotationProjectionSnapshot {
	return {
		expectedMessageCount: 1,
		expectedSessionCount: 1,
		expectedThreadCount: 1,
		projectionRevision,
		recoveryStatus: 'available',
		sessions: [
			{
				completedAt: null,
				createdAt: 1,
				eligibleMessageCount: 1,
				eligibleWithoutInlinePlacementCount: 0,
				lifecycle: 'living',
				semanticRevision: projectionRevision,
				sessionId,
				sourceRelationship: 'applicable',
				updatedAt: 2,
			},
		],
		sourceGeneration,
		threads: [
			{
				context: {
					diffSide: null,
					endLine: 4,
					path: 'Sources/App.swift',
					placement: 'exact',
					resolution: 'open',
					scope: 'located',
					sourceIdentity: 'source-1',
					sourceRole: 'file',
					startLine: 3,
					threadId,
				},
				messages: [
					{
						attentionState: 'not_applicable',
						authorKind: 'human',
						createdAt: 2,
						draft: null,
						handled: false,
						messageId,
						messageRevision: 1,
						ordinal: 0,
						savedBody: 'Comment',
						savedRevision: 1,
						sessionId,
						sessionRevision: projectionRevision,
						status: 'locked',
						threadId,
						threadRevision: 1,
					},
				],
			},
		],
		worktreeId: 'worktree-1',
	};
}
