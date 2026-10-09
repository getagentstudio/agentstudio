import { describe, expect, test, vi } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { encodeBridgeWorkerMetadataInterestUpdateCommand } from './bridge-comm-worker-protocol.js';
import { dispatchBridgeCommWorkerRuntimeProductControl } from './bridge-comm-worker-runtime-product-control-dispatch.js';
import { flushBridgeWorkerRuntimeContinuations } from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductWorktreeAnnotationOperation } from './bridge-product-call-contracts.js';
import { BridgeProductControlRequestError } from './bridge-product-session-authority.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from './bridge-worker-contracts.js';

describe.each(['fileView', 'review'] as const)(
	'Bridge comm worker runtime %s annotation output control',
	(surface) => {
		test('accepts JSON export success after the ordinary product-control deadline', async () => {
			vi.useFakeTimers();
			try {
				// Arrange
				const action = deferredProductControlAction();
				const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
				const requestId = 'request-json-export';
				dispatchAnnotationOutput({
					surface,
					operation: {
						displayedProjectionRevision: 9,
						expectedSessionRevision: 4,
						kind: 'output.scope.commit',
						outputKind: 'jsonFile',
						scope: 'pending',
						sessionId: '00000000-0000-7000-8000-000000000013',
						sourceGeneration: 7,
					},
					publish: (message): void => {
						publishedMessages.push(message);
					},
					requestId,
					sendProductControl: action.send,
					timeoutMilliseconds: 25,
				});

				// Act
				await vi.advanceTimersByTimeAsync(250);
				await flushBridgeWorkerRuntimeContinuations();
				action.resolve(
					completedOutputResult(
						{
							kind: 'succeeded',
							summary: {
								attemptId: '00000000-0000-7000-8000-000000000014',
								destinationFilename: 'review.json',
								messageCount: 2,
								outputKind: 'json_file',
								sessionId: '00000000-0000-7000-8000-000000000013',
							},
						},
						requestId,
						surface,
					),
				);
				await flushBridgeWorkerRuntimeContinuations();

				// Assert
				expect(action.send).toHaveBeenCalledTimes(1);
				expect(publishedMessages.filter((message) => message.kind === 'health')).toEqual([
					expect.objectContaining({ status: 'ready', requestId }),
				]);
				expect(
					publishedMessages.filter((message) => message.kind === 'annotationCommandAccepted'),
				).toEqual([
					expect.objectContaining({
						kind: 'annotationCommandAccepted',
						outcome: expect.objectContaining({
							status: { kind: 'output', outcome: expect.objectContaining({ kind: 'succeeded' }) },
						}),
						requestId,
					}),
				]);
			} finally {
				vi.useRealTimers();
			}
		});

		test('accepts one repeated-output cancellation after pane backgrounding and the ordinary deadline', async () => {
			vi.useFakeTimers();
			try {
				// Arrange
				const action = deferredProductControlAction();
				const paneWork = new AbortController();
				const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
				const requestId = 'request-repeat-export';
				dispatchAnnotationOutput({
					surface,
					operation: {
						attemptId: '00000000-0000-7000-8000-000000000014',
						kind: 'output.repeat',
					},
					paneWorkSignal: paneWork.signal,
					publish: (message): void => {
						publishedMessages.push(message);
					},
					requestId,
					sendProductControl: action.send,
					timeoutMilliseconds: 25,
				});

				// Act
				paneWork.abort(new DOMException('pane moved to background', 'AbortError'));
				await vi.advanceTimersByTimeAsync(250);
				action.resolve(
					completedOutputResult({ kind: 'destination_cancelled' }, requestId, surface),
				);
				await flushBridgeWorkerRuntimeContinuations();

				// Assert
				expect(action.send).toHaveBeenCalledTimes(1);
				expect(publishedMessages.filter((message) => message.kind === 'health')).toEqual([
					expect.objectContaining({ status: 'ready', requestId }),
				]);
				expect(
					publishedMessages.filter((message) => message.kind === 'annotationCommandAccepted'),
				).toEqual([
					expect.objectContaining({
						kind: 'annotationCommandAccepted',
						outcome: expect.objectContaining({
							status: { kind: 'output', outcome: { kind: 'destination_cancelled' } },
						}),
						requestId,
					}),
				]);
			} finally {
				vi.useRealTimers();
			}
		});

		test('reports a Save past its deadline as unknown and still publishes the late committed outcome', async () => {
			// Arrange: W1 settles unknown, then its revision-aware observer receives the late result.
			const action = deferredProductControlAction();
			const lateAction = deferredProductControlAction();
			const acknowledgeLate = vi.fn(async (): Promise<void> => {});
			const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
			const requestId = 'request-late-save';
			dispatchAnnotationOutput({
				surface,
				operation: {
					editToken: '00000000-0000-7000-8000-000000000015',
					expectedDraftRevision: 1,
					expectedMessageRevision: 2,
					kind: 'draft.save',
					messageId: '00000000-0000-7000-8000-000000000016',
					sessionId: '00000000-0000-7000-8000-000000000013',
				},
				publish: (message): void => {
					publishedMessages.push(message);
				},
				requestId,
				sendProductControl: action.send,
				timeoutMilliseconds: 25,
			});

			// Act: W1 reports its typed deadline settlement.
			await flushBridgeWorkerRuntimeContinuations();
			action.reject(
				new BridgeProductControlRequestError({
					code: 'internal',
					message: 'Save result is unknown.',
					outcome: 'outcomeUnknown',
					retryAfterMilliseconds: null,
					retryable: true,
					observeLateOutcome: async () => ({
						actionResult: await lateAction.send(),
						evidence: {
							failureCode: null,
							kind: 'operation.lateOutcome',
							operationId: 'save-operation-1',
							outcome: 'succeeded',
							result: { committed: true },
							revision: 2,
						},
						acknowledge: acknowledgeLate,
					}),
				}),
			);
			await flushBridgeWorkerRuntimeContinuations();

			// Assert: the outcome is unknown, not failed.
			expect(publishedMessages).toEqual([
				expect.objectContaining({
					deliveryStatus: 'unknownAfterDispatch',
					kind: 'health',
					requestId,
					status: 'degraded',
				}),
			]);

			// Act: native commits the Save late and W1's observer reports revision two.
			lateAction.resolve({
				kind: 'completed',
				outcome: {
					requestId: `product-${requestId}`,
					sessionId: '00000000-0000-7000-8000-000000000013',
					status: { kind: 'committed' },
					surface: surface === 'review' ? 'review' : 'file',
				},
			});
			await flushBridgeWorkerRuntimeContinuations();

			// Assert: the late committed outcome still reaches main for reconciliation.
			expect(action.send).toHaveBeenCalledTimes(1);
			expect(
				publishedMessages.filter((message) => message.kind === 'annotationCommandAccepted'),
			).toEqual([
				expect.objectContaining({
					outcome: expect.objectContaining({ status: { kind: 'committed' } }),
					requestId,
				}),
			]);
			expect(
				publishedMessages.filter(
					(message) => message.kind === 'health' && message.status === 'degraded',
				),
			).toHaveLength(1);
			expect(acknowledgeLate).toHaveBeenCalledTimes(1);
		});

		test('reports the W1 outcomeUnknown settlement for clipboard output commits', async () => {
			// Arrange
			const action = deferredProductControlAction();
			const publishedMessages: BridgeWorkerServerToMainMessage[] = [];
			dispatchAnnotationOutput({
				surface,
				operation: {
					displayedProjectionRevision: 9,
					expectedSessionRevision: 4,
					kind: 'output.scope.commit',
					outputKind: 'clipboardMarkdown',
					scope: 'pending',
					sessionId: '00000000-0000-7000-8000-000000000013',
					sourceGeneration: 7,
				},
				publish: (message): void => {
					publishedMessages.push(message);
				},
				requestId: 'request-clipboard-output',
				sendProductControl: action.send,
				timeoutMilliseconds: 25,
			});

			// W1 owns the deadline and reports its typed settlement to this dispatcher.
			await flushBridgeWorkerRuntimeContinuations();
			action.reject(
				new BridgeProductControlRequestError({
					code: 'internal',
					message: 'Clipboard output result is unknown.',
					outcome: 'outcomeUnknown',
					retryAfterMilliseconds: null,
					retryable: true,
				}),
			);
			await flushBridgeWorkerRuntimeContinuations();

			// Assert
			expect(action.send).toHaveBeenCalledTimes(1);
			expect(publishedMessages).toEqual([
				expect.objectContaining({
					deliveryStatus: 'unknownAfterDispatch',
					kind: 'health',
					requestId: 'request-clipboard-output',
					status: 'degraded',
				}),
			]);
		});
	},
);

describe('Bridge comm worker runtime Review interest control', () => {
	test('reports degraded health when worker-owned interest publication rejects', async () => {
		// Arrange
		const publishedMessages: BridgeWorkerServerToMainMessage[] = [];

		// Act
		dispatchMetadataInterestUpdate({
			publish: (message): void => {
				publishedMessages.push(message);
			},
			publishReviewMetadataInterests: async (): Promise<void> => {
				throw new Error('injected Review interest failure');
			},
			requestId: 'request-review-interest-rejected',
		});
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(publishedMessages).toEqual([
			expect.objectContaining({
				kind: 'health',
				message: 'Bridge comm worker failed to update Review metadata interests.',
				requestId: 'request-review-interest-rejected',
				status: 'degraded',
			}),
		]);
	});

	test('reports degraded health when worker-owned interest publication does not settle', async () => {
		vi.useFakeTimers();
		try {
			// Arrange
			const publishedMessages: BridgeWorkerServerToMainMessage[] = [];

			// Act
			dispatchMetadataInterestUpdate({
				publish: (message): void => {
					publishedMessages.push(message);
				},
				publishReviewMetadataInterests: async (): Promise<never> => new Promise((): void => {}),
				requestId: 'request-review-interest-timeout',
				timeoutMilliseconds: 25,
			});
			await flushBridgeWorkerRuntimeContinuations();
			expect(publishedMessages).toEqual([]);
			await vi.advanceTimersByTimeAsync(25);
			await flushBridgeWorkerRuntimeContinuations();

			// Assert
			expect(publishedMessages).toEqual([
				expect.objectContaining({
					kind: 'health',
					message: 'Bridge comm worker failed to update Review metadata interests.',
					requestId: 'request-review-interest-timeout',
					status: 'degraded',
				}),
			]);
		} finally {
			vi.useRealTimers();
		}
	});
});

function dispatchMetadataInterestUpdate(props: {
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly publishReviewMetadataInterests: () => Promise<void>;
	readonly requestId: string;
	readonly timeoutMilliseconds?: number;
}): void {
	const command = encodeBridgeWorkerMetadataInterestUpdateCommand({
		epoch: 3,
		request: {
			itemIds: ['forged-caller-item'],
			lane: 'foreground',
			protocol: 'review',
		},
		requestId: props.requestId,
	});
	dispatchBridgeCommWorkerRuntimeProductControl({
		activeReviewWorkerDerivationEpoch: 3,
		comparisonTargetsQueryRunner: {
			abort: (): void => {},
			fail: (): void => {},
			run: async (): Promise<void> => {},
		},
		getActiveComparisonTargetsRequestId: (): null => null,
		mainCommand: command,
		messages: [
			{
				direction: 'serverWorkerToMain',
				kind: 'health',
				requestId: props.requestId,
				status: 'ready',
				transferDescriptors: [],
				wireVersion: 1,
			},
		],
		paneWorkSignal: new AbortController().signal,
		productControlTimeoutMilliseconds: props.timeoutMilliseconds ?? 5_000,
		productController: createUnusedProductController(),
		productTransport: undefined,
		publish: props.publish,
		publishReviewMetadataInterests: props.publishReviewMetadataInterests,
		reviewSuccessorSettlementOwner: null,
		sendProductControl: async (): Promise<null> => null,
		setActiveComparisonTargetsRequestId: (): void => {},
	});
}

function dispatchAnnotationOutput(props: {
	readonly surface: 'fileView' | 'review';
	readonly operation: BridgeProductWorktreeAnnotationOperation;
	readonly paneWorkSignal?: AbortSignal;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly requestId: string;
	readonly sendProductControl: () => Promise<unknown>;
	readonly timeoutMilliseconds: number;
}): void {
	dispatchBridgeCommWorkerRuntimeProductControl({
		activeReviewWorkerDerivationEpoch: null,
		comparisonTargetsQueryRunner: {
			abort: (): void => {},
			fail: (): void => {},
			run: async (): Promise<void> => {},
		},
		getActiveComparisonTargetsRequestId: (): null => null,
		mainCommand: {
			command: 'annotationCommand',
			direction: 'mainToServerWorker',
			epoch: 1,
			kind: 'command',
			operation: props.operation,
			requestId: props.requestId,
			surface: props.surface,
			...(props.surface === 'review'
				? {
						reviewPublicationIdentity: {
							packageId: 'installed-package',
							publicationId: '00000000-0000-7000-8000-000000000031',
							reviewGeneration: 1,
							revision: 1,
							sourceIdentity: 'installed-source',
						},
					}
				: {}),
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		},
		messages: [
			{
				direction: 'serverWorkerToMain',
				kind: 'health',
				requestId: props.requestId,
				status: 'ready',
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			},
		],
		paneWorkSignal: props.paneWorkSignal ?? new AbortController().signal,
		productControlTimeoutMilliseconds: props.timeoutMilliseconds,
		productController: null,
		productTransport: undefined,
		publish: props.publish,
		publishReviewMetadataInterests: async (): Promise<void> => {},
		reviewSuccessorSettlementOwner: null,
		sendProductControl: props.sendProductControl,
		setActiveComparisonTargetsRequestId: (): void => {},
	});
}

function deferredProductControlAction(): {
	readonly reject: (reason: Error) => void;
	readonly resolve: (value: unknown) => void;
	readonly send: ReturnType<typeof vi.fn<() => Promise<unknown>>>;
} {
	let resolveAction!: (value: unknown) => void;
	let rejectAction!: (reason: Error) => void;
	const promise = new Promise<unknown>((resolve, reject): void => {
		resolveAction = resolve;
		rejectAction = reject;
	});
	return {
		reject: rejectAction,
		resolve: resolveAction,
		send: vi.fn(async (): Promise<unknown> => promise),
	};
}

function completedOutputResult(
	outcome: Readonly<Record<string, unknown>>,
	requestId: string,
	surface: 'fileView' | 'review',
): Readonly<Record<string, unknown>> {
	return {
		kind: 'completed',
		outcome: {
			requestId: `product-${requestId}`,
			sessionId: '00000000-0000-7000-8000-000000000013',
			status: { kind: 'output', outcome },
			surface: surface === 'review' ? 'review' : 'file',
		},
	};
}

function createUnusedProductController(): BridgeCommWorkerProductController {
	return new BridgeCommWorkerProductController({
		productTransport: unusedProductTransport(),
	});
}

function unusedProductTransport(): BridgeProductTransportSession {
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (): number => 0,
		call: async (): Promise<never> => {
			throw new Error('Unexpected product call.');
		},
		openContent: (): never => {
			throw new Error('Unexpected content open.');
		},
		subscribe: (): never => {
			throw new Error('Unexpected product subscription.');
		},
		workerDerivationEpoch: (): number => 0,
	};
}
