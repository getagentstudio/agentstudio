import { act } from 'react';

import type { BridgeCommWorkerPort } from '../core/comm-worker/bridge-comm-worker-entry.js';
import { encodeBridgeWorkerActiveViewerModeUpdateCommand } from '../core/comm-worker/bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from '../core/comm-worker/bridge-comm-worker-runtime-protocol.js';
import { createIdleWorktreeAnnotationSubscription } from '../core/comm-worker/bridge-comm-worker-runtime-protocol.worker-test-support.js';
import { createBridgeMainRenderSnapshotStore } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type {
	BridgePaneCommWorkerDispatcher,
	BridgePaneCommWorkerNativeBootstrap,
} from '../core/comm-worker/bridge-pane-comm-worker-session.js';
import type {
	BridgePaneSessionPort,
	CreateBridgePaneRuntimeProps,
} from '../core/comm-worker/bridge-pane-runtime.js';
import { BridgeProductBoundedAsyncQueue } from '../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeProductBatchFrameSinks } from '../core/comm-worker/bridge-product-batch-frame-router.js';
import {
	bridgeProductFileWorktreeAnnotationCommandRequestSchema,
	bridgeProductReviewWorktreeAnnotationCommandRequestSchema,
	type BridgeProductCallResult,
} from '../core/comm-worker/bridge-product-call-contracts.js';
import {
	bridgeProductFileContentDescriptorSchema,
	type BridgeProductContentFrameFor,
} from '../core/comm-worker/bridge-product-content-contracts.js';
import { bridgeProductFileMetadataApplicationProtocol } from '../core/comm-worker/bridge-product-metadata-application-registry.js';
import type { BridgeProductMetadataApplicationSubscription } from '../core/comm-worker/bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from '../core/comm-worker/bridge-product-transport.js';
import { createTestMetadataReopenPort } from '../core/comm-worker/bridge-product-view-reopen.test-support.js';
import {
	bridgeWorkerServerToMainWireMessageSchema,
	type BridgeWorkerFileQueryOutcomeEvent,
	type BridgeWorkerMainToServerMessage,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { bridgeWorkerPierreRenderPolicy } from '../core/demand/bridge-content-demand-policy.js';
import { waitForBridgeViewerAnimationFrame } from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import type { BridgeFileViewerBrowserTestProductSession } from './bridge-file-viewer-browser-test-app.js';
import type {
	BrowserFileViewScope,
	PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import { fileContentSha256Hex } from './bridge-file-viewer-browser-test-fixtures.js';

export interface BridgeFileViewerBrowserTestPaneSessionFactory {
	(): BridgePaneSessionPort;
	readonly renderStoreFactory: NonNullable<CreateBridgePaneRuntimeProps['renderStoreFactory']>;
}

export interface BridgeFileViewerBrowserPreparedQueryCompletion {
	readonly cancel: () => void;
	readonly promise: Promise<void>;
}

export interface BridgeFileViewerBrowserQueryCompletion {
	readonly dispose: () => void;
	readonly observeCommand: (message: BridgeWorkerMainToServerMessage) => void;
	readonly observeOutcome: (message: BridgeWorkerFileQueryOutcomeEvent) => void;
	readonly observePublishedTransaction: (transactionId: string) => void;
	readonly prepareNextQueryCompletion: () => BridgeFileViewerBrowserPreparedQueryCompletion;
}

interface BridgeFileViewerBrowserWorkerMessageDrain {
	readonly waitForPublicationQueue: () => Promise<void>;
	readonly wait: () => Promise<void>;
}

const activeBridgeFileViewerBrowserWorkerMessageDrains =
	new Set<BridgeFileViewerBrowserWorkerMessageDrain>();
const activeBridgeFileViewerBrowserQueryCompletions =
	new Set<BridgeFileViewerBrowserQueryCompletion>();
const pendingBridgeFileViewerBrowserWorkerQueueJoins = new Set<Promise<void>>();
const bridgeFileViewerBrowserWorkerDrainRequestPrefix = 'browser-file-worker-drain-';
let activeBridgeFileViewerBrowserInteractionActCount = 0;
let resolveBridgeFileViewerBrowserInteractionActs: (() => void) | null = null;
let bridgeFileViewerBrowserInteractionActs = Promise.resolve();

export function beginBridgeFileViewerBrowserInteractionAct(): () => void {
	if (activeBridgeFileViewerBrowserInteractionActCount === 0) {
		bridgeFileViewerBrowserInteractionActs = new Promise<void>((resolve): void => {
			resolveBridgeFileViewerBrowserInteractionActs = resolve;
		});
	}
	activeBridgeFileViewerBrowserInteractionActCount += 1;
	let hasEnded = false;
	return (): void => {
		if (hasEnded) return;
		hasEnded = true;
		activeBridgeFileViewerBrowserInteractionActCount -= 1;
		if (activeBridgeFileViewerBrowserInteractionActCount !== 0) return;
		resolveBridgeFileViewerBrowserInteractionActs?.();
		resolveBridgeFileViewerBrowserInteractionActs = null;
	};
}

export async function waitForBridgeFileViewerWorkerMessageDrain(): Promise<void> {
	await Promise.all([
		...Array.from(activeBridgeFileViewerBrowserWorkerMessageDrains, (drain) => drain.wait()),
		...pendingBridgeFileViewerBrowserWorkerQueueJoins,
	]);
}

export async function waitForBridgeFileViewerWorkerPublicationQueue(): Promise<void> {
	await Promise.all(
		Array.from(activeBridgeFileViewerBrowserWorkerMessageDrains, (drain) =>
			drain.waitForPublicationQueue(),
		),
	);
}

export function prepareNextBridgeFileViewerBrowserQueryCompletion(): BridgeFileViewerBrowserPreparedQueryCompletion {
	const activeCompletions = [...activeBridgeFileViewerBrowserQueryCompletions];
	if (activeCompletions.length === 0) {
		throw new Error('No active File Viewer browser query completion owner.');
	}
	const preparedCompletions = activeCompletions.map((completion) =>
		completion.prepareNextQueryCompletion(),
	);
	return {
		cancel: (): void => {
			for (const completion of preparedCompletions) completion.cancel();
		},
		promise: Promise.all(preparedCompletions.map((completion) => completion.promise)).then(
			(): void => {},
		),
	};
}

export function createBridgeFileViewerBrowserTestPaneSessionFactory(props: {
	readonly activateFileViewerOnInstall?: boolean;
	readonly productSessionRef: {
		readonly current: BridgeFileViewerBrowserTestProductSession | undefined;
	};
}): BridgeFileViewerBrowserTestPaneSessionFactory {
	const queryCompletion = createBridgeFileViewerBrowserQueryCompletion();
	let workerMessageActQueue: Promise<void> = Promise.resolve();
	let fileSourceDiscoveryCompleted = false;
	let pendingFileDisplayPatchCount = 0;
	let pendingMetadataInterestUpdateCount = 0;
	let pendingSettledContentPierreJobCount = 0;
	let pendingSettledContentTerminalPatchCount = 0;
	const pendingFileDisplayPatchWaiters = new Set<() => void>();
	let waitForWorkerToMainPortDrain: (() => Promise<void>) | null = null;
	const waitForStableWorkerMessageDrain = async (stableFrameCount = 0): Promise<void> => {
		if (
			!fileSourceDiscoveryCompleted ||
			pendingFileDisplayPatchCount > 0 ||
			pendingMetadataInterestUpdateCount > 0 ||
			pendingSettledContentPierreJobCount > 0 ||
			pendingSettledContentTerminalPatchCount > 0
		) {
			await new Promise<void>((resolve): void => {
				pendingFileDisplayPatchWaiters.add(resolve);
			});
		}
		await waitForWorkerToMainPortDrain?.();
		const observedActQueue = workerMessageActQueue;
		await observedActQueue;
		await act(async (): Promise<void> => {
			await waitForBridgeViewerAnimationFrame();
		});
		await waitForWorkerToMainPortDrain?.();
		const finalActQueue = workerMessageActQueue;
		await finalActQueue;
		await Promise.resolve();
		if (
			fileSourceDiscoveryCompleted &&
			pendingFileDisplayPatchCount === 0 &&
			pendingMetadataInterestUpdateCount === 0 &&
			pendingSettledContentPierreJobCount === 0 &&
			pendingSettledContentTerminalPatchCount === 0 &&
			finalActQueue === workerMessageActQueue
		) {
			if (stableFrameCount >= 1) return;
			await waitForStableWorkerMessageDrain(stableFrameCount + 1);
			return;
		}
		await waitForStableWorkerMessageDrain(0);
	};
	const workerMessageDrain: BridgeFileViewerBrowserWorkerMessageDrain = {
		wait: waitForStableWorkerMessageDrain,
		waitForPublicationQueue: async (): Promise<void> => {
			for (;;) {
				const observedQueue = workerMessageActQueue;
				await observedQueue;
				await Promise.resolve();
				if (observedQueue === workerMessageActQueue) return;
			}
		},
	};
	const publishWorkerMessagesInAct = (publishProps: {
		readonly messages: readonly BridgeWorkerServerToMainMessage[];
		readonly publishWorkerMessages: (messages: readonly BridgeWorkerServerToMainMessage[]) => void;
	}): void => {
		const publishCompletion = workerMessageActQueue.then(async (): Promise<void> => {
			await bridgeFileViewerBrowserInteractionActs;
			await act(async (): Promise<void> => {
				publishProps.publishWorkerMessages(publishProps.messages);
				await Promise.resolve();
			});
		});
		workerMessageActQueue = publishCompletion.catch((error: unknown) => {
			queueMicrotask((): void => {
				throw error;
			});
		});
	};
	const sessionFactory = (): BridgePaneSessionPort => ({
		createDispatcher: (dispatcherProps): BridgePaneCommWorkerDispatcher => {
			const channel = new MessageChannel();
			let workerDrainRequestSequence = 0;
			const workerDrainWaiters = new Map<string, () => void>();
			waitForWorkerToMainPortDrain = (): Promise<void> => {
				workerDrainRequestSequence += 1;
				const requestId = `${bridgeFileViewerBrowserWorkerDrainRequestPrefix}${workerDrainRequestSequence}`;
				const completion = new Promise<void>((resolve): void => {
					workerDrainWaiters.set(requestId, resolve);
				});
				channel.port2.postMessage({
					direction: 'serverWorkerToMain',
					kind: 'health',
					requestId,
					status: 'ready',
					transferDescriptors: [],
					wireVersion: 1,
				});
				return completion;
			};
			activeBridgeFileViewerBrowserWorkerMessageDrains.add(workerMessageDrain);
			activeBridgeFileViewerBrowserQueryCompletions.add(queryCompletion);
			const productTransport = createBrowserTestProductTransport({
				onContentTerminalSettled: (succeeded): void => {
					pendingSettledContentTerminalPatchCount += 1;
					if (succeeded) pendingSettledContentPierreJobCount += 1;
				},
				onFileSourceDiscoveryCompleted: (): void => {
					fileSourceDiscoveryCompleted = true;
					for (const resolve of pendingFileDisplayPatchWaiters) resolve();
					pendingFileDisplayPatchWaiters.clear();
				},
				onFileBatchInstallStarted: (): void => {
					pendingFileDisplayPatchCount += 1;
				},
				onFileBatchInstallSettled: (): void => {
					pendingFileDisplayPatchCount -= 1;
					if (pendingFileDisplayPatchCount === 0) {
						for (const resolve of pendingFileDisplayPatchWaiters) resolve();
						pendingFileDisplayPatchWaiters.clear();
					}
				},
				onMetadataInterestUpdateSettled: (): void => {
					void Promise.resolve()
						.then(() => Promise.resolve())
						.then((): void => {
							pendingMetadataInterestUpdateCount -= 1;
							if (pendingMetadataInterestUpdateCount === 0) {
								for (const resolve of pendingFileDisplayPatchWaiters) resolve();
								pendingFileDisplayPatchWaiters.clear();
							}
						});
				},
				onMetadataInterestUpdateStarted: (): void => {
					pendingMetadataInterestUpdateCount += 1;
				},
				productSessionRef: props.productSessionRef,
			});
			channel.port1.addEventListener('message', (event: MessageEvent<unknown>): void => {
				const message = bridgeWorkerServerToMainWireMessageSchema.parse(event.data);
				if (message.kind === 'fileQueryOutcome') {
					queryCompletion.observeOutcome(message);
					return;
				}
				if (message.kind === 'sessionSuspect') return;
				if (
					message.kind === 'health' &&
					message.requestId?.startsWith(bridgeFileViewerBrowserWorkerDrainRequestPrefix) === true
				) {
					workerDrainWaiters.get(message.requestId)?.();
					workerDrainWaiters.delete(message.requestId);
					return;
				}
				if (message.kind === 'filePierreRenderJob' && pendingSettledContentPierreJobCount > 0) {
					pendingSettledContentPierreJobCount -= 1;
					if (pendingSettledContentPierreJobCount === 0) {
						for (const resolve of pendingFileDisplayPatchWaiters) resolve();
						pendingFileDisplayPatchWaiters.clear();
					}
				}
				if (
					message.kind === 'fileRenderPatch' &&
					message.patches.some(
						(patch) =>
							patch.slice === 'contentAvailability' &&
							patch.operation === 'upsert' &&
							patch.payload.state !== 'loading',
					) &&
					pendingSettledContentTerminalPatchCount > 0
				) {
					pendingSettledContentTerminalPatchCount -= 1;
					if (pendingSettledContentTerminalPatchCount === 0) {
						for (const resolve of pendingFileDisplayPatchWaiters) resolve();
						pendingFileDisplayPatchWaiters.clear();
					}
				}
				publishWorkerMessagesInAct({
					messages: [message],
					publishWorkerMessages: dispatcherProps.publishWorkerMessages,
				});
			});
			registerBridgeCommWorkerRuntimePortProtocol(channel.port2 as BridgeCommWorkerPort, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: bridgeWorkerPierreRenderPolicy.reviewInteractiveRenderBudget,
				fileViewBudget: {
					className: 'interactive',
					maxBytes: 2 * 1024 * 1024,
					maxWindowLines: 10_000,
				},
				productTransport,
			});
			channel.port1.start();
			channel.port2.start();
			if (props.activateFileViewerOnInstall !== false) {
				channel.port1.postMessage(
					encodeBridgeWorkerActiveViewerModeUpdateCommand({
						epoch: 1,
						requestId: 'browser-file-worker-active-viewer-mode',
						update: {
							activeSource: null,
							mode: 'file',
							nativeSelectionRequestId: null,
							sequence: 1,
							sessionId: 'browser-file-worker-session',
						},
					}),
				);
			}
			props.productSessionRef.current?.onWorkerMessagesPublisher?.((messages): void => {
				publishWorkerMessagesInAct({
					messages,
					publishWorkerMessages: dispatcherProps.publishWorkerMessages,
				});
			});
			return {
				dispatch: (message): void => {
					props.productSessionRef.current?.onWorkerCommand?.(message);
					queryCompletion.observeCommand(message);
					channel.port1.postMessage(message);
				},
				dispose: (): void => {
					activeBridgeFileViewerBrowserWorkerMessageDrains.delete(workerMessageDrain);
					activeBridgeFileViewerBrowserQueryCompletions.delete(queryCompletion);
					queryCompletion.dispose();
					const workerQueueJoin = workerMessageActQueue.then((): void => {});
					pendingBridgeFileViewerBrowserWorkerQueueJoins.add(workerQueueJoin);
					void workerQueueJoin.finally((): void => {
						pendingBridgeFileViewerBrowserWorkerQueueJoins.delete(workerQueueJoin);
					});
					waitForWorkerToMainPortDrain = null;
					fileSourceDiscoveryCompleted = true;
					pendingFileDisplayPatchCount = 0;
					pendingMetadataInterestUpdateCount = 0;
					pendingSettledContentPierreJobCount = 0;
					pendingSettledContentTerminalPatchCount = 0;
					for (const resolve of pendingFileDisplayPatchWaiters) resolve();
					pendingFileDisplayPatchWaiters.clear();
					for (const resolve of workerDrainWaiters.values()) resolve();
					workerDrainWaiters.clear();
					channel.port1.close();
					channel.port2.close();
				},
			};
		},
		dispose: (): void => {},
		setNativeBootstrapRequester: (): void => {},
		installNativeBootstrap: (_bootstrap: BridgePaneCommWorkerNativeBootstrap): void => {},
	});
	const renderStoreFactory: NonNullable<CreateBridgePaneRuntimeProps['renderStoreFactory']> = (
		fileDisplayApplierProps,
	): ReturnType<typeof createBridgeMainRenderSnapshotStore> => {
		return createBridgeMainRenderSnapshotStore(
			fileDisplayApplierProps === undefined
				? {}
				: {
						...fileDisplayApplierProps,
						onFileQueryTransactionPublished: queryCompletion.observePublishedTransaction,
					},
		);
	};
	return Object.assign(sessionFactory, { renderStoreFactory });
}

export function createBridgeFileViewerBrowserQueryCompletion(): BridgeFileViewerBrowserQueryCompletion {
	const pendingInteractionWaiters: BridgeFileViewerBrowserQueryWaiter[] = [];
	const waitersByRequestId = new Map<string, BridgeFileViewerBrowserQueryWaiter>();
	const waitersByTransactionId = new Map<string, BridgeFileViewerBrowserQueryWaiter>();
	let isDisposed = false;

	const removeWaiter = (waiter: BridgeFileViewerBrowserQueryWaiter): void => {
		const pendingIndex = pendingInteractionWaiters.indexOf(waiter);
		if (pendingIndex >= 0) pendingInteractionWaiters.splice(pendingIndex, 1);
		if (waiter.requestId !== null) waitersByRequestId.delete(waiter.requestId);
		if (waiter.transactionId !== null) waitersByTransactionId.delete(waiter.transactionId);
	};
	const resolveWaiter = (waiter: BridgeFileViewerBrowserQueryWaiter): void => {
		if (waiter.settled) return;
		waiter.settled = true;
		removeWaiter(waiter);
		waiter.resolve();
	};
	const rejectWaiter = (waiter: BridgeFileViewerBrowserQueryWaiter, error: Error): void => {
		if (waiter.settled) return;
		waiter.settled = true;
		removeWaiter(waiter);
		waiter.reject(error);
	};

	return {
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			const outstandingWaiters = new Set([
				...pendingInteractionWaiters,
				...waitersByRequestId.values(),
			]);
			for (const waiter of outstandingWaiters) {
				rejectWaiter(waiter, new Error('File query completion disposed.'));
			}
		},
		observeCommand: (message): void => {
			if (isDisposed || message.command !== 'fileQueryUpdate') return;
			const waiter = pendingInteractionWaiters.shift();
			if (waiter === undefined || waiter.settled) return;
			waiter.requestId = message.requestId;
			waitersByRequestId.set(message.requestId, waiter);
		},
		observeOutcome: (message): void => {
			if (isDisposed) return;
			const waiter = waitersByRequestId.get(message.requestId);
			if (waiter === undefined) return;
			if (message.outcome.kind === 'unchanged') {
				resolveWaiter(waiter);
				return;
			}
			if (message.outcome.kind === 'superseded') {
				rejectWaiter(waiter, new Error(`File query request ${message.requestId} was superseded.`));
				return;
			}
			waiter.transactionId = message.outcome.transactionId;
			waitersByTransactionId.set(message.outcome.transactionId, waiter);
		},
		observePublishedTransaction: (transactionId): void => {
			if (isDisposed) return;
			const waiter = waitersByTransactionId.get(transactionId);
			if (waiter !== undefined) resolveWaiter(waiter);
		},
		prepareNextQueryCompletion: (): BridgeFileViewerBrowserPreparedQueryCompletion => {
			if (isDisposed) {
				return {
					cancel: (): void => {},
					promise: Promise.reject(new Error('File query completion disposed.')),
				};
			}
			let resolvePromise: (() => void) | null = null;
			let rejectPromise: ((error: Error) => void) | null = null;
			const promise = new Promise<void>((resolve, reject): void => {
				resolvePromise = resolve;
				rejectPromise = reject;
			});
			if (resolvePromise === null || rejectPromise === null) {
				throw new Error('File query completion waiter was not initialized.');
			}
			const waiter: BridgeFileViewerBrowserQueryWaiter = {
				reject: rejectPromise,
				requestId: null,
				resolve: resolvePromise,
				settled: false,
				transactionId: null,
			};
			pendingInteractionWaiters.push(waiter);
			return {
				cancel: (): void => {
					if (waiter.settled) return;
					waiter.settled = true;
					removeWaiter(waiter);
				},
				promise,
			};
		},
	};
}

interface BridgeFileViewerBrowserQueryWaiter {
	reject: (error: Error) => void;
	requestId: string | null;
	resolve: () => void;
	settled: boolean;
	transactionId: string | null;
}

function createBrowserTestProductTransport(props: {
	readonly onContentTerminalSettled: (succeeded: boolean) => void;
	readonly onFileSourceDiscoveryCompleted: () => void;
	readonly onFileBatchInstallStarted: () => void;
	readonly onFileBatchInstallSettled: () => void;
	readonly onMetadataInterestUpdateSettled: () => void;
	readonly onMetadataInterestUpdateStarted: () => void;
	readonly productSessionRef: {
		readonly current: BridgeFileViewerBrowserTestProductSession | undefined;
	};
}): BridgeProductTransportSession {
	let fileEpoch = 0;
	let viewScopeRevision = 0;
	let batchSinks: BridgeProductBatchFrameSinks | null = null;
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileEpoch += 1;
			return surface === 'file' ? fileEpoch : 0;
		},
		call: async (...arguments_): Promise<never> => {
			const [method] = arguments_;
			if (method === 'file.source.current') {
				try {
					return (await (props.productSessionRef.current?.currentSource?.() ??
						defaultBrowserTestCurrentSource())) as never;
				} finally {
					props.onFileSourceDiscoveryCompleted();
				}
			}
			if (method === 'file.annotations.command' || method === 'review.annotations.command') {
				const request = (
					method === 'file.annotations.command'
						? bridgeProductFileWorktreeAnnotationCommandRequestSchema
						: bridgeProductReviewWorktreeAnnotationCommandRequestSchema
				).parse(arguments_[1]);
				if (request.operation.kind !== 'session.discover')
					throw new Error('File browser fixture supports only Comments discovery.');
				// The unrelated Comments source is admitted and idle, never a fabricated permanent failure.
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- The narrowed annotation call returns its completed discovery contract.
				return {
					kind: 'completed',
					outcome: {
						requestId: 'browser-comments-discovery',
						sessionId: null,
						status: { kind: 'committed' },
						surface: method === 'file.annotations.command' ? 'file' : 'review',
					},
				} as never;
			}
			if (method === 'file.activeViewerMode.update' || method === 'file.refresh.retry')
				return null as never;
			throw new Error(`Unexpected browser-test product call: ${method}.`);
		},
		openContent: (descriptor, signal): never => {
			const fileDescriptor = bridgeProductFileContentDescriptorSchema.parse(descriptor);
			const content = Promise.resolve(
				props.productSessionRef.current?.readContent?.({ descriptor: fileDescriptor, signal }) ??
					defaultBrowserTestContent(fileDescriptor.descriptorId),
			);
			const terminal = content.then(async (text) => {
				const bytes = new TextEncoder().encode(text);
				return {
					bytes: bytes.buffer,
					contentKind: 'file.content' as const,
					descriptorId: fileDescriptor.descriptorId,
					kind: 'complete' as const,
					observedSha256: await fileContentSha256Hex(bytes),
				};
			});
			void terminal.then(
				(): void => {
					props.onContentTerminalSettled(true);
				},
				(): void => {
					props.onContentTerminalSettled(false);
				},
			);
			return {
				contentKind: 'file.content',
				contentRequestId: `browser-content-${fileDescriptor.descriptorId}`,
				frames: emptyBrowserTestContentFrames(),
				terminal,
			} as never;
		},
		setPanePresentationFrameSink: (sink): void => {
			// This fixture models an already active native File pane. Activity-suppression
			// tests use their own transports so dormant and hidden admission remain explicit.
			sink({
				fileRefreshFailure: null,
				presentationRevision: 1,
				kind: 'pane.presentation',

				operationCorrelationId: null,
				metadataStreamId: 'browser-file-test-metadata-stream',
				nativeActivity: 'foreground',
				paneSessionId: 'browser-file-test-pane-session',
				refreshingLanes: [],
				reviewComparison: null,
				streamSequence: 1,
				wireVersion: 2,
				workerInstanceId: 'browser-file-test-worker-instance',
			});
		},
		setBatchFrameSinks: (sinks): void => {
			batchSinks = sinks;
		},
		setViewScopeForSubscription: async ({
			scope,
		}): Promise<{ readonly kind: 'accepted'; readonly scopeRevision: number }> => {
			if (scope.kind !== 'file') throw new Error('Expected typed File view scope.');
			props.onMetadataInterestUpdateStarted();
			try {
				await props.productSessionRef.current?.onFileScopeChange?.(scope as BrowserFileViewScope);
				viewScopeRevision += 1;
				return { kind: 'accepted', scopeRevision: viewScopeRevision };
			} finally {
				props.onMetadataInterestUpdateSettled();
			}
		},
		subscribe: (...arguments_): never => {
			const [protocol, options] = arguments_;
			if (protocol.kind === 'file.annotations' || protocol.kind === 'review.annotations') {
				// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- This branch closes over an idle annotation subscription, unrelated to the File behavior under test.
				return createIdleWorktreeAnnotationSubscription(protocol) as never;
			}
			if (protocol.kind !== 'file.metadata') {
				throw new Error(`Unexpected browser-test product subscription: ${protocol.kind}.`);
			}
			const subscriptionId = 'browser-file-metadata-subscription';
			const events = new BridgeProductBoundedAsyncQueue<never>(1);
			const publish: PublishBrowserFileBatch = (batch): void => {
				const sink = batchSinks;
				if (sink === null) throw new Error('File batch sink was not installed.');
				props.onFileBatchInstallStarted();
				// Subscribe returns before the controller records its subscription authority.
				void Promise.resolve()
					.then(() => sink.install(batch))
					.then(
						(): void => props.onFileBatchInstallSettled(),
						(error: unknown): void => {
							props.onFileBatchInstallSettled();
							queueMicrotask((): void => {
								throw error;
							});
						},
					);
			};
			const session = props.productSessionRef.current;
			session?.onMetadataSubscriptionOpen?.(options as never);
			if (session?.initialFileBatch !== undefined) publish(session.initialFileBatch);
			const disposePublisher = session?.onFileBatchPublisher?.(publish);
			const subscription: BridgeProductMetadataApplicationSubscription<
				typeof bridgeProductFileMetadataApplicationProtocol
			> = {
				cancel: async (): Promise<void> => {
					disposePublisher?.();
					events.close(true);
				},
				events,
				subscriptionId,
				subscriptionKind: 'file.metadata',
			};
			return subscription as never;
		},
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : 0),
	};
}

export function defaultBrowserTestCurrentSource(): BridgeProductCallResult<'file.source.current'> {
	return {
		status: 'available',
		source: {
			cwdScope: null,
			freshness: 'live',
			includeStatuses: true,
			repoId: '00000000-0000-4000-8000-000000000001',
			rootPathToken: 'browser-test-root',
			worktreeId: '00000000-0000-4000-8000-000000000002',
		},
	};
}

function defaultBrowserTestContent(descriptorId: string): string {
	return `export const ${descriptorId.replaceAll('-', '_')} = true;\n`;
}

async function* emptyBrowserTestContentFrames(): AsyncIterable<
	BridgeProductContentFrameFor<'file.content'>
> {}
