import { createElement, type ReactElement, type ReactNode } from 'react';

import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainReviewPublicationIdentity,
} from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type {
	BridgeProductReviewAnnotationPublicationIdentity,
	BridgeProductWorktreeAnnotationOperation,
} from '../core/comm-worker/bridge-product-call-contracts.js';
import type { BridgeWorkerServerToMainMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeWorkerRpcCommandInput } from '../core/comm-worker/bridge-worker-rpc-client.js';
import { WorktreeAnnotationBrowserCommandReceiptFixture } from './worktree-annotation-browser-command-receipt-fixture.js';
import { reviewAnnotationPublicationIdentityForMainIdentity } from './worktree-annotation-review-application.js';
import type {
	WorktreeAnnotationCommandOutcome,
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationOutputHistorySummary,
	WorktreeAnnotationSessionSummary,
	WorktreeAnnotationThreadContext,
} from './worktree-annotation-surface-client.js';
import { WorktreeAnnotationSurfaceProvider } from './worktree-annotation-surface-provider.js';

export const annotationSessionId = '00000000-0000-7000-8000-000000000011';
export const annotationSecondSessionId = '00000000-0000-7000-8000-000000000014';
export const annotationHeadThreadId = '00000000-0000-7000-8000-000000000012';
export const annotationBaseThreadId = '00000000-0000-7000-8000-000000000013';
const annotationSubscriptionId = 'annotation-browser-subscription-1';

export interface WorktreeAnnotationBrowserProviderHarness {
	readonly surface: RecordingAnnotationBrowserSurface;
	readonly wrap: (children: ReactNode) => ReactElement;
}

export function createWorktreeAnnotationBrowserProviderHarness(
	surfaceKind: 'fileView' | 'review',
): WorktreeAnnotationBrowserProviderHarness {
	const surface = new RecordingAnnotationBrowserSurface(surfaceKind);
	return {
		surface,
		wrap: (children): ReactElement =>
			createElement(WorktreeAnnotationSurfaceProvider, {
				// oxlint-disable-next-line react/no-children-prop -- This shared test helper is a .ts module without JSX.
				children,
				surfaceClient: surface.client,
			}),
	};
}

type AnnotationCommandOutcome = WorktreeAnnotationCommandOutcome;
export type AnnotationSessionSummary = WorktreeAnnotationSessionSummary;
type AnnotationOutputCommandOutcome = Extract<
	AnnotationCommandOutcome['status'],
	{ readonly kind: 'output' }
>['outcome'];

interface AnnotationBrowserProjectionDeclaration {
	readonly expectedThreadCount: number;
	readonly recoveryStatus: 'available' | 'recovered_degraded' | 'unavailable';
	readonly revision: number;
}

type AnnotationBrowserProjectionEvent =
	| {
			readonly eventKind: 'message.batch';
			readonly payload: {
				readonly context: WorktreeAnnotationThreadContext;
				readonly isLastBatchForThread: boolean;
				readonly messages: readonly WorktreeAnnotationMessageEntry[];
				readonly revision: number;
			};
	  }
	| {
			readonly eventKind: 'projection.state';
			readonly payload: {
				readonly commandOutcomes: readonly AnnotationCommandOutcome[];
				readonly expectedThreadCount: number;
				readonly outputHistory: readonly WorktreeAnnotationOutputHistorySummary[];
				readonly recoveryStatus: 'available' | 'recovered_degraded' | 'unavailable';
				readonly revision: number;
				readonly sessions: readonly AnnotationSessionSummary[];
				readonly worktreeId: string;
			};
	  };

export class RecordingAnnotationBrowserSurface {
	readonly #listeners = new Set<(message: BridgeWorkerServerToMainMessage) => void>();
	readonly client: BridgePaneSurfaceClient;
	readonly sentOperations: BridgeProductWorktreeAnnotationOperation[] = [];
	readonly sentRecoveryCommands: Array<
		Extract<
			BridgeWorkerRpcCommandInput,
			{ readonly command: 'annotationProjectionRetry' | 'viewRecoveryRetry' }
		>
	> = [];
	readonly sentReviewPublicationIdentities: BridgeProductReviewAnnotationPublicationIdentity[] = [];
	readonly sentOutputInspectionAttemptIds: string[] = [];
	#reviewActiveIdentity: BridgeMainReviewPublicationIdentity = annotationReviewMainIdentity;
	readonly #pendingAnnotationCommands: Array<{
		readonly operation: BridgeProductWorktreeAnnotationOperation;
		readonly requestId: string;
	}> = [];
	#lastOutputInspectionRequestId: string | null = null;
	#nextRequest = 0;
	#outputHistory: readonly WorktreeAnnotationOutputHistorySummary[] = [];
	#pendingProjectionThreadsById = new Map<
		string,
		{
			readonly context: WorktreeAnnotationThreadContext;
			readonly messages: readonly WorktreeAnnotationMessageEntry[];
		}
	>();
	#projectionAssemblyPending = false;
	#projectionDeclaration: AnnotationBrowserProjectionDeclaration = {
		expectedThreadCount: 0,
		recoveryStatus: 'available',
		revision: 0,
	};
	#revision = 0;
	#sessions: readonly AnnotationSessionSummary[] = [];
	readonly #commandReceiptFixture = new WorktreeAnnotationBrowserCommandReceiptFixture(
		annotationHeadThreadId,
	);
	readonly #threadsById = new Map<
		string,
		{
			readonly context: WorktreeAnnotationThreadContext;
			readonly messages: readonly WorktreeAnnotationMessageEntry[];
		}
	>();

	constructor(
		surface: 'fileView' | 'review',
		props: { readonly failRootCreateWithConflict?: boolean } = {},
	) {
		const renderStore = createBridgeMainRenderSnapshotStore();
		if (surface === 'review') {
			Object.defineProperty(renderStore, 'getReviewRefreshPresentation', {
				value: () => ({ activeIdentity: this.#reviewActiveIdentity, candidate: null }),
			});
		}
		this.client = {
			requestWorkerReplacement: (): void => {},
			lifecycle: {
				getServerSnapshot: () => ({ requestsById: {} }),
				getSnapshot: () => ({ requestsById: {} }),
				subscribe: () => (): void => {},
			},
			// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- Browser annotation fixtures never exercise render fulfillment.
			renderFulfillmentCoordinator: {} as BridgePaneSurfaceClient['renderFulfillmentCoordinator'],
			renderStore,
			send: (command): string => {
				if (
					command.command === 'annotationProjectionRetry' ||
					command.command === 'viewRecoveryRetry'
				) {
					this.#nextRequest += 1;
					this.sentRecoveryCommands.push(command);
					return `worker-request-${this.#nextRequest}`;
				}
				if (
					command.command !== 'annotationCommand' &&
					command.command !== 'annotationOutputInspect'
				) {
					throw new Error(`Unexpected browser annotation command ${command.command}.`);
				}
				this.#nextRequest += 1;
				const requestId = `worker-request-${this.#nextRequest}`;
				if (command.command === 'annotationOutputInspect') {
					this.sentOutputInspectionAttemptIds.push(command.attemptId);
					this.#lastOutputInspectionRequestId = requestId;
					return requestId;
				}
				this.sentOperations.push(command.operation);
				if (this.client.surface === 'review') {
					const reviewPublicationIdentity = command.reviewPublicationIdentity;
					if (reviewPublicationIdentity === undefined) {
						throw new Error('Review annotation command is missing its publication identity.');
					}
					this.sentReviewPublicationIdentities.push(reviewPublicationIdentity);
				}
				const operation = command.operation;
				this.#pendingAnnotationCommands.push({ operation, requestId });
				if (props.failRootCreateWithConflict === true && command.operation.kind === 'root.create') {
					queueMicrotask((): void => this.#publishConflict(requestId));
				}
				return requestId;
			},
			subscribeMessages: (listener): (() => void) => {
				this.#listeners.add(listener);
				return (): void => {
					this.#listeners.delete(listener);
				};
			},
			surface,
		};
	}

	setReviewActiveIdentity(identity: BridgeMainReviewPublicationIdentity): void {
		this.#reviewActiveIdentity = identity;
	}

	publishProjection(revision: number, expectedThreadCount: number): void {
		this.publishProjectionState({
			expectedThreadCount,
			revision,
			sessions: [
				{
					completedAt: null,
					createdAt: 1,
					eligibleMessageCount: 0,
					eligibleWithoutInlinePlacementCount: 0,
					lifecycle: 'living',
					semanticRevision: revision,
					sessionId: annotationSessionId,
					sourceRelationship: 'applicable',
					updatedAt: revision,
				},
			],
		});
	}

	publishProjectionState(props: {
		readonly commandOutcomes?: readonly AnnotationCommandOutcome[];
		readonly expectedThreadCount: number;
		readonly outputHistory?: readonly WorktreeAnnotationOutputHistorySummary[];
		readonly recoveryStatus?: 'available' | 'recovered_degraded' | 'unavailable';
		readonly revision: number;
		readonly sessions: readonly AnnotationSessionSummary[];
		readonly subscriptionId?: string;
	}): void {
		this.#revision = props.revision;
		this.#sessions = props.sessions;
		this.#outputHistory = props.outputHistory ?? [];
		this.#publishAnnotationEvent(
			{
				eventKind: 'projection.state',
				payload: {
					commandOutcomes: props.commandOutcomes ?? [],
					expectedThreadCount: props.expectedThreadCount,
					outputHistory: this.#outputHistory,
					recoveryStatus: props.recoveryStatus ?? 'available',
					revision: props.revision,
					sessions: this.#sessions,
					worktreeId: 'worktree-1',
				},
			},
			props.subscriptionId,
		);
	}

	publishThread(props: {
		readonly context: WorktreeAnnotationThreadContext;
		readonly message: WorktreeAnnotationMessageEntry;
	}): void {
		const thread = { context: props.context, messages: [props.message] };
		this.#publishThreadEvent(thread);
	}

	publishThreadMessages(props: {
		readonly context: WorktreeAnnotationThreadContext;
		readonly messages: readonly WorktreeAnnotationMessageEntry[];
		readonly subscriptionId?: string;
	}): void {
		this.#publishThreadEvent(props, props.subscriptionId);
	}

	publishAnnotationEvent(event: AnnotationBrowserProjectionEvent, subscriptionId: string): void {
		this.#publishAnnotationEvent(event, subscriptionId);
	}

	publishRefreshing(): void {
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: null,
			state: { catalogAuthorityRetired: false, kind: 'refreshing' },
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	publishUnavailable(retryable = true): void {
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: null,
			state: { catalogAuthorityRetired: false, kind: 'unavailable', retryable },
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	publishHealth(requestId: string, status: 'degraded' | 'ready'): void {
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'health',
			requestId,
			status,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	settleMostRecentCommitted(
		sessionId: string = annotationSessionId,
		expectedThreadCount: number = this.#threadsById.size,
	): void {
		const pendingCommand = this.#takeMostRecentPendingAnnotationCommand();
		const workerRequestId = pendingCommand.requestId;
		const productRequestId = `product-${workerRequestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			productRequestId,
			requestId: workerRequestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
		this.#revision += 1;
		const receipt = this.#commandReceiptFixture.receiptForCommittedOperation({
			committedSessionId: sessionId,
			committedSessionRevision: this.#revision,
			operation: pendingCommand.operation,
			projectedThreadsById: this.#threadsById,
		});
		this.publishProjectionState({
			commandOutcomes: [
				{
					...(receipt === undefined ? {} : { receipt }),
					requestId: productRequestId,
					sessionId,
					status: { kind: 'committed' },
					surface: this.client.surface === 'fileView' ? 'file' : 'review',
				},
			],
			expectedThreadCount,
			outputHistory: this.#outputHistory,
			revision: this.#revision,
			sessions: this.#sessions,
		});
	}

	settleMostRecentCommittedWithoutProjection(
		sessionId: string = annotationSessionId,
		operationKind?: BridgeProductWorktreeAnnotationOperation['kind'],
	): WorktreeAnnotationCommandOutcome['receipt'] {
		const pendingCommand = this.#takeMostRecentPendingAnnotationCommand(operationKind);
		const workerRequestId = pendingCommand.requestId;
		const productRequestId = `product-${workerRequestId}`;
		this.#revision += 1;
		const receipt = this.#commandReceiptFixture.receiptForCommittedOperation({
			committedSessionId: sessionId,
			committedSessionRevision: this.#revision,
			operation: pendingCommand.operation,
			projectedThreadsById: this.#threadsById,
		});
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				...(receipt === undefined ? {} : { receipt }),
				requestId: productRequestId,
				sessionId,
				status: { kind: 'committed' },
				surface: this.client.surface === 'fileView' ? 'file' : 'review',
			},
			productRequestId,
			requestId: workerRequestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
		return receipt;
	}

	settleMostRecentConflict(operationKind?: BridgeProductWorktreeAnnotationOperation['kind']): void {
		const pendingCommand = this.#takeMostRecentPendingAnnotationCommand(operationKind);
		const productRequestId = `product-${pendingCommand.requestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				requestId: productRequestId,
				sessionId: annotationSessionId,
				status: { code: 'conflict', kind: 'failed' },
				surface: this.client.surface === 'fileView' ? 'file' : 'review',
			},
			productRequestId,
			requestId: pendingCommand.requestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	settleMostRecentViewed(committedSessionRevision: number): void {
		const pendingCommand = this.#takeMostRecentPendingAnnotationCommand('message.viewed.mark');
		if (pendingCommand.operation.kind !== 'message.viewed.mark') {
			throw new Error('Expected message.viewed.mark.');
		}
		const productRequestId = `product-${pendingCommand.requestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome: {
				receipt: undefined,
				requestId: productRequestId,
				sessionId: pendingCommand.operation.sessionId,
				status: {
					kind: 'viewed',
					results: pendingCommand.operation.items.map((item) => ({
						committedSessionRevision,
						disposition: 'changed',
						kind: 'viewed',
						messageId: item.messageId,
						savedRevision: item.expectedSavedRevision,
					})),
				},
				surface: this.client.surface === 'fileView' ? 'file' : 'review',
			},
			productRequestId,
			requestId: pendingCommand.requestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	settleMostRecentAdmissionRequired(props: {
		readonly candidateSessionIds: readonly string[];
		readonly reason: 'applicable_session_choice' | 'uncertain_continuity_choice';
	}): void {
		const workerRequestId = this.#takeMostRecentPendingAnnotationCommand().requestId;
		const productRequestId = `product-${workerRequestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			productRequestId,
			requestId: workerRequestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
		this.#revision += 1;
		this.publishProjectionState({
			commandOutcomes: [
				{
					requestId: productRequestId,
					sessionId: null,
					status: {
						candidateSessionIds: [...props.candidateSessionIds],
						kind: 'admission_required',
						reason: props.reason,
					},
					surface: this.client.surface === 'fileView' ? 'file' : 'review',
				},
			],
			expectedThreadCount: this.#threadsById.size,
			outputHistory: this.#outputHistory,
			revision: this.#revision,
			sessions: this.#sessions,
		});
	}

	settleMostRecentOutput(outcome: AnnotationOutputCommandOutcome): void {
		const workerRequestId = this.#takeMostRecentPendingAnnotationCommand().requestId;
		const productRequestId = `product-${workerRequestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			productRequestId,
			requestId: workerRequestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
		this.#revision += 1;
		const sessions =
			outcome.kind === 'succeeded' || outcome.kind === 'partial_success'
				? this.#sessions.map((session) =>
						session.sessionId === outcome.summary.sessionId
							? {
									...session,
									semanticRevision: session.semanticRevision + 1,
									updatedAt: session.updatedAt + 1,
								}
							: session,
					)
				: this.#sessions;
		this.publishProjectionState({
			commandOutcomes: [
				{
					requestId: productRequestId,
					sessionId: annotationSessionId,
					status: { kind: 'output', outcome },
					surface: this.client.surface === 'fileView' ? 'file' : 'review',
				},
			],
			expectedThreadCount: this.#threadsById.size,
			outputHistory: this.#outputHistory,
			revision: this.#revision,
			sessions,
		});
		for (const thread of this.#threadsById.values()) this.#publishThreadEvent(thread);
	}

	#takeMostRecentPendingAnnotationCommand(
		operationKind?: BridgeProductWorktreeAnnotationOperation['kind'],
	): {
		readonly operation: BridgeProductWorktreeAnnotationOperation;
		readonly requestId: string;
	} {
		const pendingCommandIndex =
			operationKind === undefined
				? this.#pendingAnnotationCommands.length - 1
				: this.#pendingAnnotationCommands.findLastIndex(
						(candidate) => candidate.operation.kind === operationKind,
					);
		const [pendingCommand] =
			pendingCommandIndex < 0 ? [] : this.#pendingAnnotationCommands.splice(pendingCommandIndex, 1);
		if (pendingCommand === undefined) throw new Error('No annotation command is pending.');
		return pendingCommand;
	}

	settleMostRecentInspection(props: {
		readonly attemptId: string;
		readonly content: string;
		readonly outputKind: 'clipboard_markdown' | 'json_file';
	}): void {
		if (this.#lastOutputInspectionRequestId === null) {
			throw new Error('No annotation output inspection is pending.');
		}
		const exactBytes = new TextEncoder().encode(props.content);
		const exactBuffer = exactBytes.buffer.slice(
			exactBytes.byteOffset,
			exactBytes.byteOffset + exactBytes.byteLength,
		);
		const descriptorBase = {
			attemptId: props.attemptId,
			contentKind: 'annotation.output' as const,
			declaredByteLength: exactBytes.byteLength,
			descriptorId: `annotation-output-${props.attemptId}`,
			encoding: 'utf-8' as const,
			expectedSha256: 'a'.repeat(64),
			formatVersion: 1 as const,
			maximumBytes: exactBytes.byteLength,
			surface: this.client.surface === 'fileView' ? ('file' as const) : ('review' as const),
		};
		const descriptor =
			props.outputKind === 'clipboard_markdown'
				? {
						...descriptorBase,
						contentType: 'text/markdown; charset=utf-8' as const,
						outputKind: 'clipboard_markdown' as const,
					}
				: {
						...descriptorBase,
						contentType: 'application/json; charset=utf-8' as const,
						outputKind: 'json_file' as const,
					};
		this.#publish({
			descriptor,
			direction: 'serverWorkerToMain',
			exactBytes: exactBuffer,
			kind: 'annotationOutputInspection',
			requestId: this.#lastOutputInspectionRequestId,
			surface: this.client.surface,
			transferDescriptors: [
				{
					byteLength: exactBytes.byteLength,
					fieldPath: ['exactBytes'],
					messageKind: 'annotationOutputInspection',
					mode: 'transfer',
				},
			],
			wireVersion: 1,
		});
		this.#lastOutputInspectionRequestId = null;
	}

	#publishThreadEvent(
		props: {
			readonly context: WorktreeAnnotationThreadContext;
			readonly messages: readonly WorktreeAnnotationMessageEntry[];
		},
		subscriptionId?: string,
	): void {
		this.#publishAnnotationEvent(
			{
				eventKind: 'message.batch',
				payload: {
					context: props.context,
					isLastBatchForThread: true,
					messages: props.messages,
					revision: this.#revision,
				},
			},
			subscriptionId,
		);
	}

	#publishConflict(workerRequestId: string): void {
		const productRequestId = `product-${workerRequestId}`;
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			productRequestId,
			requestId: workerRequestId,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
		const outcome = {
			requestId: productRequestId,
			sessionId: annotationSessionId,
			status: { code: 'conflict', kind: 'failed' },
			surface: this.client.surface === 'fileView' ? 'file' : 'review',
		} satisfies AnnotationCommandOutcome;
		this.#revision += 1;
		this.#publishAnnotationEvent({
			eventKind: 'projection.state',
			payload: {
				commandOutcomes: [outcome],
				expectedThreadCount: this.#threadsById.size,
				outputHistory: [],
				recoveryStatus: 'available',
				revision: this.#revision,
				sessions: this.#sessions,
				worktreeId: 'worktree-1',
			},
		});
	}

	#publishAnnotationEvent(
		event: AnnotationBrowserProjectionEvent,
		_subscriptionId: string = annotationSubscriptionId,
	): void {
		if (event.eventKind === 'projection.state') {
			this.#revision = event.payload.revision;
			this.#sessions = event.payload.sessions;
			this.#outputHistory = event.payload.outputHistory;
			this.#projectionDeclaration = {
				expectedThreadCount: event.payload.expectedThreadCount,
				recoveryStatus: event.payload.recoveryStatus,
				revision: event.payload.revision,
			};
			this.#projectionAssemblyPending = true;
			this.#pendingProjectionThreadsById.clear();
			for (const outcome of event.payload.commandOutcomes) this.#publishCommandOutcome(outcome);
			this.#publishOutputHistory(event.payload.outputHistory);
		} else {
			this.#revision = event.payload.revision;
			const destination = this.#projectionAssemblyPending
				? this.#pendingProjectionThreadsById
				: this.#threadsById;
			destination.set(event.payload.context.threadId, {
				context: event.payload.context,
				messages: event.payload.messages,
			});
		}
		this.#publishProjectionSnapshotIfComplete();
	}

	#publishProjectionSnapshotIfComplete(): void {
		const projectionThreadsById = this.#projectionAssemblyPending
			? this.#pendingProjectionThreadsById
			: this.#threadsById;
		if (projectionThreadsById.size < this.#projectionDeclaration.expectedThreadCount) return;
		if (projectionThreadsById.size > this.#projectionDeclaration.expectedThreadCount) {
			throw new Error(
				`Browser annotation fixture received ${projectionThreadsById.size} threads for projection ${this.#projectionDeclaration.revision}, which declared ${this.#projectionDeclaration.expectedThreadCount}.`,
			);
		}
		if (this.#projectionAssemblyPending) {
			this.#threadsById.clear();
			for (const [threadId, thread] of projectionThreadsById) {
				this.#threadsById.set(threadId, thread);
			}
			this.#projectionAssemblyPending = false;
		}
		const completeThreads = [...this.#threadsById.values()];
		this.#publishCatalog(this.#projectionDeclaration.revision);
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationProjectionConvergence',
			operationCorrelationId: 'a'.repeat(64),
			state: {
				contentSessionIds: this.#sessions.map((session) => session.sessionId),
				kind: 'ready',
				stageAttempt: 0,
				...(this.client.surface === 'review'
					? {
							reviewPublicationIdentity: reviewAnnotationPublicationIdentityForMainIdentity(
								this.#reviewActiveIdentity,
							),
						}
					: {}),
				snapshot: {
					expectedMessageCount: completeThreads.reduce(
						(sum, thread) => sum + thread.messages.length,
						0,
					),
					expectedSessionCount: this.#sessions.length,
					expectedThreadCount: this.#projectionDeclaration.expectedThreadCount,
					projectionRevision: this.#projectionDeclaration.revision,
					recoveryStatus: this.#projectionDeclaration.recoveryStatus,
					sessions: this.#sessions,
					sourceGeneration: this.#projectionDeclaration.revision,
					threads: completeThreads,
					worktreeId: 'worktree-1',
				},
			},
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	#publishCatalog(catalogRevision: number): void {
		const transferId = `browser-annotation-catalog-${catalogRevision}`;
		const sessionEntries = this.#sessions.map((session) => ({
			kind: 'session' as const,
			semanticRevision: session.semanticRevision,
			sessionId: session.sessionId,
		}));
		const nextThreadOrdinalBySessionId = new Map<string, number>();
		const descendantEntries = [...this.#threadsById.values()].flatMap((thread) => {
			const sessionId = thread.messages[0]?.sessionId;
			if (sessionId === undefined) {
				throw new Error('Browser annotation fixture threads require one message-owned session.');
			}
			const createdOrdinal = nextThreadOrdinalBySessionId.get(sessionId) ?? 0;
			nextThreadOrdinalBySessionId.set(sessionId, createdOrdinal + 1);
			return [
				{
					createdOrdinal,
					kind: 'thread' as const,
					scope: thread.context.scope,
					sessionId,
					threadId: thread.context.threadId,
				},
				...thread.messages.map((message) => ({
					kind: 'message' as const,
					messageId: message.messageId,
					ordinal: message.ordinal,
					threadId: thread.context.threadId,
				})),
			];
		});
		const entries = [...sessionEntries, ...descendantEntries];
		const common = {
			authority: {
				subscriptionId: `${this.client.surface}-browser-annotation-subscription`,
				workerDerivationEpoch: 1,
				worktreeId: 'worktree-1',
			},
			direction: 'serverWorkerToMain' as const,
			kind: 'annotationCatalogStaging' as const,
			operationCorrelationId: 'a'.repeat(64),
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1 as const,
		};
		this.#publish({
			...common,
			transfer: {
				catalogRevision,
				expectedEntryCount: entries.length,
				kind: 'catalog.begin',
				transferId,
			},
		});
		if (entries.length > 0) {
			this.#publish({
				...common,
				transfer: {
					catalogRevision,
					entries,
					kind: 'catalog.window',
					transferId,
					windowOrdinal: 0,
				},
			});
		}
		this.#publish({
			...common,
			transfer: {
				catalogRevision,
				entryCount: entries.length,
				kind: 'catalog.commit',
				transferId,
				windowCount: entries.length === 0 ? 0 : 1,
			},
		});
	}

	#publishCommandOutcome(outcome: AnnotationCommandOutcome): void {
		this.#publish({
			direction: 'serverWorkerToMain',
			kind: 'annotationCommandAccepted',
			outcome,
			productRequestId: outcome.requestId,
			requestId: `outcome-${outcome.requestId}`,
			surface: this.client.surface,
			transferDescriptors: [],
			wireVersion: 1,
		});
	}

	#publishOutputHistory(history: readonly WorktreeAnnotationOutputHistorySummary[]): void {
		this.#publishCommandOutcome({
			requestId: `history-${this.#revision}`,
			sessionId: null,
			status: { kind: 'history', summaries: history },
			surface: this.client.surface === 'fileView' ? 'file' : 'review',
		});
	}

	#publish(message: BridgeWorkerServerToMainMessage): void {
		for (const listener of this.#listeners) listener(message);
	}
}

const annotationReviewMainIdentity = {
	generation: 7,
	packageId: 'package-installed',
	publicationId: '00000000-0000-7000-8000-000000000041',
	revision: 3,
	sourceIdentity: 'source-installed',
} as const;

export function annotationSessionSummary(props: {
	readonly eligibleMessageCount?: number;
	readonly eligibleWithoutInlinePlacementCount?: number;
	readonly lifecycle?: 'completed' | 'living';
	readonly revision: number;
	readonly sessionId: string;
	readonly sourceRelationship?: 'applicable' | 'detached' | 'uncertain';
}): AnnotationSessionSummary {
	return {
		completedAt: props.lifecycle === 'completed' ? props.revision : null,
		createdAt: props.revision,
		eligibleMessageCount: props.eligibleMessageCount ?? 0,
		eligibleWithoutInlinePlacementCount: props.eligibleWithoutInlinePlacementCount ?? 0,
		lifecycle: props.lifecycle ?? 'living',
		semanticRevision: props.revision,
		sessionId: props.sessionId,
		sourceRelationship: props.sourceRelationship ?? 'applicable',
		updatedAt: props.revision,
	};
}

export function annotationMessage(props: {
	readonly messageId: string;
	readonly ordinal?: number;
	readonly sessionRevision?: number;
	readonly threadId: string;
	readonly threadRevision?: number;
}): WorktreeAnnotationMessageEntry {
	return {
		attentionState: 'not_applicable',
		authorKind: 'human',
		createdAt: props.ordinal ?? 0,
		draft: null,
		handled: false,
		messageId: props.messageId,
		messageRevision: 1,
		ordinal: props.ordinal ?? 0,
		savedBody: `## Comment ${props.messageId.at(-1)}`,
		savedRevision: 1,
		sessionId: annotationSessionId,
		sessionRevision: props.sessionRevision ?? 1,
		status: 'editable',
		threadId: props.threadId,
		threadRevision: props.threadRevision ?? 1,
	};
}
