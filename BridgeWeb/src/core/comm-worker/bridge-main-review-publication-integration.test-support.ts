import { vi } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryRecorder } from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	buildBridgeWorkerReviewCandidateReadyEvent,
	buildBridgeWorkerReviewCandidateFailedEvent,
	buildBridgeWorkerReviewCandidateStartedEvent,
	buildBridgeWorkerReviewPublicationInstallAdmissionEvent,
} from './bridge-comm-worker-protocol.js';
import { makeReviewPublication } from './bridge-main-render-fulfillment-coordinator.test-support.js';
import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainReviewPublicationIdentity,
} from './bridge-main-render-snapshot-store.js';
import {
	createBridgeMainReviewPublicationIntegration,
	type BridgeMainReviewPublicationIntegration,
} from './bridge-main-review-publication-integration.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewPierreRenderJobEvent,
	BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';
import { createBridgeWorkerRpcClient } from './bridge-worker-rpc-client.js';
import { createBridgeWorkerRpcLifecycleStore } from './bridge-worker-rpc-lifecycle-store.js';

export const ACTIVE = reviewIdentity(1, '11');
export const CANDIDATE = reviewIdentity(2, '12');
export const SUCCESSOR = reviewIdentity(3, '13');
export const LATEST = reviewIdentity(4, '14');

export interface ReviewIdentity {
	readonly packageId: string;
	readonly publicationId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
	readonly sourceIdentity: string;
}

export interface Harness {
	readonly requestWorkerReplacement: () => void;
	readonly commandKinds: readonly string[];
	readonly courierJobs: Array<BridgeWorkerReviewPierreRenderJobEvent['job']>;
	readonly integration: BridgeMainReviewPublicationIntegration;
	readonly rejectedItemIds: string[];
	readonly store: ReturnType<typeof createBridgeMainRenderSnapshotStore>;
	readonly telemetrySamples: readonly BridgeTelemetrySample[];
	readonly telemetryRecorderRef: { current: BridgeTelemetryRecorder };
	readonly ack: (command: BridgeWorkerMainToServerMessage) => void;
	readonly admit: (
		command: BridgeWorkerMainToServerMessage,
		identity: ReviewIdentity,
		status: 'admitted' | 'rejected',
	) => void;
	readonly dispose: () => void;
	readonly fail: (command: BridgeWorkerMainToServerMessage) => void;
	readonly nextCommand: (
		kind: BridgeWorkerMainToServerMessage['command'],
	) => Promise<BridgeWorkerMainToServerMessage>;
	readonly pendingCommandCount: (kind: BridgeWorkerMainToServerMessage['command']) => number;
	readonly receive: (message: BridgeWorkerServerToMainMessage) => void;
	readonly startCandidate: (
		identity: ReviewIdentity,
		presentationClass: 'ordinary' | 'promoted',
		affectedStableFileIdentities: readonly string[],
	) => void;
}

export function createHarness(
	options: {
		readonly prepareActiveEditorsForInstallation?: () => Promise<boolean>;
		readonly synchronousAdmissionStatus?: 'admitted' | 'rejected';
		readonly renderFulfillmentCoordinator?: Parameters<
			typeof createBridgeMainReviewPublicationIntegration
		>[0]['renderFulfillmentCoordinator'];
	} = {},
): Harness {
	let commandEpoch = 100;
	const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
	const commandQueue: BridgeWorkerMainToServerMessage[] = [];
	const commandWaiters = new Map<
		BridgeWorkerMainToServerMessage['command'],
		Array<(command: BridgeWorkerMainToServerMessage) => void>
	>();
	const commandKinds: string[] = [];
	let receiveSynchronousAdmission = (_command: BridgeWorkerMainToServerMessage): void => {};
	const rpcClient = createBridgeWorkerRpcClient({
		dispatch: (command): void => {
			commandKinds.push(command.command);
			const waiter = commandWaiters.get(command.command)?.shift();
			if (waiter === undefined) commandQueue.push(command);
			else waiter(command);
			if (
				command.command === 'reviewPublicationInstallAdmit' &&
				options.synchronousAdmissionStatus !== undefined
			) {
				receiveSynchronousAdmission(command);
			}
		},
		lifecycleStore,
		requestTimeoutMilliseconds: 60_000,
		surface: 'review',
	});
	receiveSynchronousAdmission = (command): void => {
		if (command.command !== 'reviewPublicationInstallAdmit') return;
		rpcClient.receive(
			buildBridgeWorkerReviewPublicationInstallAdmissionEvent({
				candidatePublicationId: command.candidatePublicationId,
				requestId: command.requestId,
				status: options.synchronousAdmissionStatus ?? 'rejected',
			}),
		);
	};
	const store = createBridgeMainRenderSnapshotStore();
	const courierJobs: Array<BridgeWorkerReviewPierreRenderJobEvent['job']> = [];
	const rejectedItemIds: string[] = [];
	const telemetrySamples: BridgeTelemetrySample[] = [];
	const telemetryRecorderRef = { current: recordingTelemetryRecorder(telemetrySamples) };
	const requestWorkerReplacement = vi.fn<() => void>();
	const publicationClient = {
		lifecycle: {
			getSnapshot: rpcClient.getLifecycleSnapshot,
			subscribe: lifecycleStore.subscribe,
		},
		requestWorkerReplacement,
		send: rpcClient.send,
	};
	const integration = createBridgeMainReviewPublicationIntegration({
		client: publicationClient,
		nextCommandEpoch: (): number => {
			commandEpoch += 1;
			return commandEpoch;
		},
		pierreCourier: {
			submit: (job): void => {
				courierJobs.push(job);
			},
		},
		prepareActiveEditorsForInstallation:
			options.prepareActiveEditorsForInstallation ??
			((): Promise<boolean> => Promise.resolve(true)),
		renderFulfillmentCoordinator: options.renderFulfillmentCoordinator ?? {
			acceptPublication: (): 'accepted' => 'accepted',
			bindPublicationItem: vi.fn(),
			isBoundFinalItem: (): boolean => false,
			markPublicationQueued: vi.fn(),
			holdPublication: vi.fn(),
			rejectPublication: (publication): void => {
				rejectedItemIds.push(publication.job.itemId);
			},
		},
		store,
		telemetryRecorderRef,
	});
	integration.start();
	const unsubscribe = rpcClient.subscribe((message): void => {
		integration.handleMessage(message);
	});
	const receiveRaw = (message: BridgeWorkerServerToMainMessage): void => {
		rpcClient.receive(message);
	};
	const startCandidate = (
		identity: ReviewIdentity,
		presentationClass: 'ordinary' | 'promoted',
		affectedStableFileIdentities: readonly string[],
	): void => {
		receiveRaw(candidateStarted(identity, presentationClass, affectedStableFileIdentities));
	};
	const receive = (message: BridgeWorkerServerToMainMessage): void => {
		if (message.kind === 'reviewDisplayPatch' && message.reviewPublicationIdentity !== null) {
			startCandidate(message.reviewPublicationIdentity, 'ordinary', []);
		}
		receiveRaw(message);
	};
	return {
		requestWorkerReplacement,
		ack: (command): void => {
			receive({
				direction: 'serverWorkerToMain',
				kind: 'health',
				requestId: command.requestId,
				status: 'ready',
				transferDescriptors: [],
				wireVersion: 1,
			});
		},
		admit: (command, identity, status): void => {
			receive(
				buildBridgeWorkerReviewPublicationInstallAdmissionEvent({
					candidatePublicationId: identity.publicationId,
					requestId: command.requestId,
					status,
				}),
			);
		},
		commandKinds,
		courierJobs,
		dispose: (): void => {
			integration.dispose();
			unsubscribe();
			rpcClient.dispose();
			store.dispose();
			lifecycleStore.dispose();
		},
		fail: (command): void => {
			receive({
				direction: 'serverWorkerToMain',
				kind: 'health',
				message: 'worker replaced',
				requestId: command.requestId,
				status: 'degraded',
				transferDescriptors: [],
				wireVersion: 1,
			});
		},
		integration,
		nextCommand: (kind): Promise<BridgeWorkerMainToServerMessage> => {
			const queuedIndex = commandQueue.findIndex((command) => command.command === kind);
			if (queuedIndex >= 0) {
				const queuedCommand = commandQueue.splice(queuedIndex, 1)[0];
				if (queuedCommand === undefined) throw new Error('Expected queued Bridge command.');
				return Promise.resolve(queuedCommand);
			}
			return new Promise((resolve) => {
				const waiters = commandWaiters.get(kind) ?? [];
				waiters.push(resolve);
				commandWaiters.set(kind, waiters);
			});
		},
		pendingCommandCount: (kind): number =>
			commandQueue.filter((command) => command.command === kind).length,
		receive,
		startCandidate,
		rejectedItemIds,
		store,
		telemetrySamples,
		telemetryRecorderRef,
	};
}

export function recordingTelemetryRecorder(
	samples: BridgeTelemetrySample[],
): BridgeTelemetryRecorder {
	return {
		flush: (): boolean => true,
		isEnabled: (): boolean => true,
		measure: <TResult>(props: { readonly operation: () => TResult }): TResult => props.operation(),
		record: (sample): void => {
			samples.push(sample);
		},
	};
}

export async function installPublication(
	harness: Harness,
	identity: ReviewIdentity,
	itemId: string,
): Promise<void> {
	harness.receive(reviewDisplayEvent(identity, itemId));
	harness.receive(candidateReady(identity, 'ordinary', []));
	const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
	harness.admit(admission, identity, 'admitted');
	const installed = await harness.nextCommand('reviewPublicationInstalled');
	harness.ack(installed);
	await harness.integration.whenSettled();
}

export function reviewIdentity(reviewGeneration: number, suffix: string): ReviewIdentity {
	return {
		packageId: `package-${reviewGeneration}`,
		publicationId: `00000000-0000-7000-8000-${suffix.padStart(12, '0')}`,
		reviewGeneration,
		revision: 1,
		sourceIdentity: 'same-source',
	};
}

export function mainIdentity(identity: ReviewIdentity): BridgeMainReviewPublicationIdentity {
	return {
		generation: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		revision: identity.revision,
		sourceIdentity: identity.sourceIdentity,
	};
}

export function candidateReady(
	identity: ReviewIdentity,
	_presentationClass: 'ordinary' | 'promoted',
	_affectedStableFileIdentities: readonly string[],
): ReturnType<typeof buildBridgeWorkerReviewCandidateReadyEvent> {
	return buildBridgeWorkerReviewCandidateReadyEvent({
		epoch: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		reviewGeneration: identity.reviewGeneration,
		revision: identity.revision,
		sequence: identity.reviewGeneration * 2 + 1,
		sourceIdentity: identity.sourceIdentity,
	});
}

export function candidateFailed(
	identity: ReviewIdentity,
	retryable: boolean,
): ReturnType<typeof buildBridgeWorkerReviewCandidateFailedEvent> {
	return buildBridgeWorkerReviewCandidateFailedEvent({
		epoch: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		retryable,
		reviewGeneration: identity.reviewGeneration,
		revision: identity.revision,
		sequence: identity.reviewGeneration * 2 + 1,
		sourceIdentity: identity.sourceIdentity,
	});
}

export function candidateStarted(
	identity: ReviewIdentity,
	presentationClass: 'ordinary' | 'promoted',
	affectedStableFileIdentities: readonly string[],
): ReturnType<typeof buildBridgeWorkerReviewCandidateStartedEvent> {
	return buildBridgeWorkerReviewCandidateStartedEvent({
		disposition: {
			affectedStableFileIdentities,
			kind: 'sameSource',
			presentationClass:
				presentationClass === 'ordinary'
					? { kind: 'ordinary' }
					: { kind: 'promoted', reason: 'files' },
		},
		epoch: identity.reviewGeneration,
		packageId: identity.packageId,
		publicationId: identity.publicationId,
		reviewGeneration: identity.reviewGeneration,
		revision: identity.revision,
		sequence: identity.reviewGeneration * 2 - 1,
		sourceIdentity: identity.sourceIdentity,
	});
}

export function reviewDisplayEvent(
	identity: ReviewIdentity,
	itemId: string,
): BridgeWorkerReviewDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: identity.reviewGeneration,
		kind: 'reviewDisplayPatch',
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext(identity.packageId),
					metadataSourceId: identity.sourceIdentity,
					metadataWindowIdentity: `window-${identity.publicationId}`,
					packageId: identity.packageId,
					reviewGeneration: identity.reviewGeneration,
					revision: identity.revision,
					status: 'ready',
					summary: {
						additions: 1,
						deletions: 0,
						filesChanged: 1,
						hiddenFileCount: 0,
						visibleFileCount: 1,
					},
					totalItemCount: 1,
					totalTreeRowCount: 1,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: [reviewItem(itemId)],
					operations: [],
					reset: true,
					startIndex: 0,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset: true,
					windows: [
						{
							rows: [
								{
									depth: 0,
									isDirectory: false,
									itemId,
									path: `${itemId}.ts`,
									rowId: `row-${itemId}`,
								},
							],
							startIndex: 0,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision: identity.reviewGeneration,
		reviewPublicationIdentity: identity,
		sequence: identity.reviewGeneration * 2,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

export function reviewItem(itemId: string): BridgeWorkerReviewDisplayItem {
	return {
		contentFacts: [],
		extentFacts: [],
		metadata: {
			additions: 1,
			deletions: 0,
			basePath: `${itemId}.ts`,
			changeKind: 'modified' as const,
			contentDescriptorIdsByRole: {},
			contentHashesByRole: {},
			contentRoles: [],
			extension: 'ts',
			fileClass: 'source' as const,
			headPath: `${itemId}.ts`,
			isHiddenByDefault: false,
			itemId,
			language: 'typescript',
			mimeTypes: ['text/typescript'],
			provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
			reviewPriority: 'normal' as const,
			reviewState: 'unreviewed' as const,
		},
		metadataWindowIdentity: `window-${itemId}`,
	};
}

export function reviewRenderPatch(
	identity: ReviewIdentity,
	itemId: string,
): Extract<BridgeWorkerServerToMainMessage, { readonly kind: 'reviewRenderPatch' }> {
	return {
		direction: 'serverWorkerToMain',
		kind: 'reviewRenderPatch',
		patches: [
			{
				itemId,
				operation: 'upsert',
				payload: { state: 'ready' },
				slice: 'contentAvailability',
			},
		],
		publicationSequence: identity.reviewGeneration,
		reviewPublicationIdentity: identity,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
		workerDerivationEpoch: identity.reviewGeneration,
	};
}

export function reviewPierrePublication(
	identity: ReviewIdentity,
	itemId: string,
	publicationSequence: number,
): BridgeWorkerReviewPierreRenderJobEvent {
	const publication = makeReviewPublication({
		itemId,
		publicationSequence,
		reviewPublicationIdentity: identity,
	});
	return {
		...publication,
		publicationSequence,
		renderReceiptIdentity: {
			...publication.renderReceiptIdentity,
			publicationSequence,
			workerDerivationEpoch: identity.reviewGeneration,
		},
		workerDerivationEpoch: identity.reviewGeneration,
	};
}
