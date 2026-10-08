import { uuidv7 } from 'uuidv7';
import { expect, test } from 'vitest';

import type { CreateBridgeCommWorkerCommandHandlerProps } from './bridge-comm-worker-command-handler-contracts.js';
import {
	advanceBridgeCommWorkerFileRenderFulfillmentLifecycle,
	retryBridgeCommWorkerExhaustedFileRender,
} from './bridge-comm-worker-file-render-fulfillment-lifecycle.js';
import {
	enqueueSelectedBridgeWorkerFileViewContentReadyPreparation,
	type BridgeWorkerFileViewContentReadyPreparationTicket,
} from './bridge-comm-worker-file-view-preparation.js';
import { createBridgeCommWorkerStore } from './bridge-comm-worker-store.js';
import { installBridgeProductFileBatch } from './bridge-product-file-batch-installer.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import type {
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerServerToMainWireMessage,
} from './bridge-worker-contracts.js';
import { BridgeWorkerRenderFulfillmentRegistry } from './bridge-worker-render-fulfillment-registry.js';
import { makeFileBatchInstallation } from './comm-runtime-protocol.file-product.test-support.js';

test.each(['lease backstop', 'exhausted Retry'] as const)(
	'%s prepares real File work using the selected demand epoch after selection epoch advances',
	async (retryKind) => {
		let nowMilliseconds = 0;
		let sequence = 13;
		const registry = new BridgeWorkerRenderFulfillmentRegistry({
			context: {
				paneSessionId: 'file-retry-pane',
				surface: 'file',
				workerInstanceId: 'file-retry-worker',
			},
			createIdentifier: (purpose): string => `${purpose}-${uuidv7()}`,
			now: (): number => nowMilliseconds,
			receiptLeaseDurationMilliseconds: 100,
			retryBackoffMilliseconds: 25,
		});
		const view = installBridgeProductFileBatch(
			makeFileBatchInstallation('open', 'file-demand-retry'),
		);
		const store = createBridgeCommWorkerStore({
			contentItems: view.contentItems,
			renderFulfillmentRegistry: registry,
			rows: view.runtimeRows,
			surface: 'file',
		});
		store.actions.applySelectedFact({ epoch: 3, itemId: 'file-1' });
		store.actions.applyFileViewSourceUpdateFact({
			contentItems: view.contentItems,
			epoch: 1,
			rows: view.runtimeRows,
			selectedContentRequestChanged: true,
		});
		expect(store.getState().selectedEpoch).toBe(3);
		expect(store.getState().demandByKey.get('file-1')).toBe('selected:1');
		store.actions.takePendingSlicePatchEvent({ epoch: 1, sequence: 1 });
		const messages: BridgeWorkerServerToMainWireMessage[] = [];
		const pump = createWorkerContentPreparationPump({ maxSliceMs: 5, now: (): number => 0 });
		let drainReady: (() => void) | null = null;
		let currentTicket: BridgeWorkerFileViewContentReadyPreparationTicket | null = null;
		let scheduledEpoch: number | null = null;
		const enqueue: NonNullable<
			CreateBridgeCommWorkerCommandHandlerProps['scheduleSelectedFileViewContentReadyPreparation']
		> = (request): void => {
			scheduledEpoch = request.epoch;
			currentTicket = enqueueSelectedBridgeWorkerFileViewContentReadyPreparation({
				...request,
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
				contentRequests: view.contentRequests,
				openContent: (descriptor) => ({
					contentKind: 'file.content',
					contentRequestId: `content-request-${uuidv7()}`,
					frames: emptyContentFrames(),
					terminal: Promise.resolve({
						bytes: new TextEncoder().encode('abc').buffer,
						contentKind: 'file.content',
						descriptorId: descriptor.descriptorId,
						endOfSource: true,
						kind: 'complete',
						observedByteLength: 3,
						observedSha256: descriptor.expectedSha256,
					}),
				}),
				operationCorrelationId: 'f'.repeat(64),
				port: {
					addEventListener: (): void => {},
					postMessage: (message): void => {
						messages.push(message);
					},
				},
				pump,
				requestPreparationDrain: (): void => {
					drainReady?.();
				},
				sequence: ++sequence,
				workerDerivationEpoch: 1,
			});
		};
		const runEnqueued = async (): Promise<void> => {
			const ticket = currentTicket;
			if (ticket === null) throw new Error('Expected lifecycle to schedule preparation.');
			expect(ticket.enqueued).toBe(true);
			const drained = new Promise<void>((resolve): void => {
				drainReady = resolve;
			});
			pump.runUntilBudget();
			await drained;
			pump.runUntilBudget();
			await ticket.completion;
			drainReady = null;
		};
		const advance = (): void => {
			const wakeAt = registry.nextLifecycleWakeAtMilliseconds();
			if (wakeAt === null) throw new Error('Expected an owned render lifecycle wake.');
			nowMilliseconds = wakeAt;
			advanceBridgeCommWorkerFileRenderFulfillmentLifecycle({
				atMilliseconds: nowMilliseconds,
				onExhausted: undefined,
				scheduleSelectedPreparation: enqueue,
				store,
			});
		};
		const publications = (): readonly BridgeWorkerFilePierreRenderJobEvent[] =>
			messages.filter(
				(message): message is BridgeWorkerFilePierreRenderJobEvent =>
					message.kind === 'filePierreRenderJob',
			);
		try {
			// Establish a real publication, then drop all Main fulfillment receipts.
			enqueue({ epoch: 1, itemId: 'file-1', store });
			await runEnqueued();
			expect(publications()).toHaveLength(1);
			const firstAttempt = publications()[0]?.renderReceiptIdentity.attemptId;
			currentTicket = null;
			advance();
			expect(registry.getItemState('file-1')?.stage).toBe('retry_wait');
			if (retryKind === 'lease backstop') {
				advance();
			} else {
				const retryAt = registry.nextLifecycleWakeAtMilliseconds();
				if (retryAt === null) throw new Error('Expected receipt recovery backoff.');
				nowMilliseconds = retryAt;
				registry.releaseReadyRetries(nowMilliseconds);
				enqueue({ epoch: 1, itemId: 'file-1', store });
				await runEnqueued();
				expect(publications()).toHaveLength(2);
				advance();
				expect(registry.getItemState('file-1')?.stage).toBe('failed');
				currentTicket = null;
				retryBridgeCommWorkerExhaustedFileRender({ scheduleSelectedPreparation: enqueue, store });
			}
			await runEnqueued();
			expect(scheduledEpoch).toBe(1);
			expect(publications()).toHaveLength(retryKind === 'lease backstop' ? 2 : 3);
			expect(publications().at(-1)?.renderReceiptIdentity.attemptId).not.toBe(firstAttempt);
			expect(publications().at(-1)?.job.payload.item).toMatchObject({
				type: 'file',
				file: { contents: 'abc' },
			});
		} finally {
			for (const workId of pump.getPendingWorkIds()) pump.cancel(workId);
			registry.resetPublications();
		}
	},
);

async function* emptyContentFrames(): AsyncIterable<never> {}
