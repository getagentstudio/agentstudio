import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import {
	createWorkerContentPreparationPump,
	type BridgeWorkerContentPreparationWork,
} from './bridge-worker-content-preparation-pump.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerSlicePatchEventSchema,
} from './bridge-worker-contracts.js';

describe('Worker content preparation pump', () => {
	test('large preparation yields to selected facts and resumes without redoing completed slices', () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 5,
			now: () => clockMs,
		});
		let backgroundProgress = 0;

		pump.enqueue({
			id: 'background-large-file',
			rank: 'background',
			runSlice: () => {
				backgroundProgress += 1;
				executionOrder.push(`background:${backgroundProgress}`);
				clockMs += 3;
				if (backgroundProgress === 1) {
					pump.enqueueOrPromote({
						id: 'selected-click',
						rank: 'selected',
						runSlice: () => {
							executionOrder.push('selected');
							clockMs += 1;
							return { complete: true };
						},
					});
				}
				return { complete: backgroundProgress === 3 };
			},
		});

		const firstRun = pump.runUntilBudget();
		expect(firstRun.completedIds).toEqual(['selected-click']);
		expect(firstRun.yielded).toBe(true);
		expect(executionOrder).toEqual(['background:1', 'selected', 'background:2']);

		const secondRun = pump.runUntilBudget();
		expect(secondRun.completedIds).toEqual(['background-large-file']);
		expect(executionOrder).toEqual(['background:1', 'selected', 'background:2', 'background:3']);
		expect(pump.getPendingWorkIds()).toEqual([]);
	});

	test('newly selected work preempts admitted visible and background work at the next slice boundary', () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 1,
			now: () => clockMs,
		});
		pump.enqueue({
			id: 'visible-work',
			rank: 'visible',
			runSlice: () => {
				executionOrder.push('visible');
				pump.enqueue({
					id: 'new-selected-work',
					rank: 'selected',
					runSlice: () => {
						executionOrder.push('selected');
						clockMs += 1;
						return { complete: true };
					},
				});
				clockMs += 1;
				return { complete: true };
			},
		});
		pump.enqueue({
			id: 'background-work',
			rank: 'background',
			runSlice: () => {
				executionOrder.push('background');
				clockMs += 1;
				return { complete: true };
			},
		});

		expect(pump.runUntilBudget()).toEqual({ completedIds: ['visible-work'], yielded: true });
		expect(pump.runUntilBudget()).toEqual({
			completedIds: ['new-selected-work'],
			yielded: true,
		});
		expect(executionOrder).toEqual(['visible', 'selected']);
	});

	test('bounds priority bypasses so continuously arriving selected work cannot starve background work', () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 1,
			now: () => clockMs,
		});
		let selectedSequence = 0;
		const enqueueNextSelectedWork = (): void => {
			const selectedId = `selected-${selectedSequence}`;
			selectedSequence += 1;
			pump.enqueue({
				id: selectedId,
				rank: 'selected',
				runSlice: () => {
					executionOrder.push(selectedId);
					clockMs += 1;
					enqueueNextSelectedWork();
					return { complete: true };
				},
			});
		};
		pump.enqueue({
			id: 'admitted-background',
			rank: 'background',
			runSlice: () => {
				executionOrder.push('background');
				clockMs += 1;
				return { complete: true };
			},
		});
		enqueueNextSelectedWork();

		for (let runIndex = 0; runIndex < 9; runIndex += 1) pump.runUntilBudget();

		expect(executionOrder).toEqual([
			'selected-0',
			'selected-1',
			'selected-2',
			'selected-3',
			'selected-4',
			'selected-5',
			'selected-6',
			'selected-7',
			'background',
		]);
		expect(pump.getPendingWorkIds()).toEqual(['selected-8']);
	});

	test('rejects owned synchronous slice budgets above eight milliseconds', () => {
		expect(() =>
			createWorkerContentPreparationPump({
				maxSliceMs: 8.01,
				now: () => 0,
			}),
		).toThrow(/eight milliseconds|8 ms/iu);
	});

	test('yields, cancels, and resumes 18,000-line Review preparation from exact completed progress', () => {
		const totalLineCount = 18_000;
		let clockMs = 0;
		let completedLineCount = 0;
		const processingCounts = new Uint8Array(totalLineCount);
		const publishedMainPayloads: unknown[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 8,
			now: () => clockMs,
		});
		const reviewPreparationWork = {
			id: 'review-preparation-18k-lines',
			rank: 'visible',
			telemetry: {
				payloadClass: 'inline',
				sourceEpoch: 41,
				workKind: 'review_content_ready',
			},
			runSlice: (context) => {
				while (completedLineCount < totalLineCount) {
					if (context.shouldYield()) return { complete: false };
					processingCounts[completedLineCount] = (processingCounts[completedLineCount] ?? 0) + 1;
					completedLineCount += 1;
					clockMs += 1;
				}
				publishedMainPayloads.push(
					bridgeWorkerSlicePatchEventSchema.parse({
						direction: 'serverWorkerToMain',
						epoch: 41,
						kind: 'slicePatch',
						patches: [
							{
								itemId: 'review-item-18k',
								operation: 'upsert',
								payload: { state: 'loading' },
								slice: 'contentAvailability',
							},
						],
						sequence: 1,
						transferDescriptors: [],
						wireVersion: BRIDGE_WORKER_WIRE_VERSION,
					}),
				);
				return { complete: true };
			},
		} satisfies BridgeWorkerContentPreparationWork;
		pump.enqueue(reviewPreparationWork);

		const firstRun = pump.runUntilBudget();
		const cancelledAtLineCount = completedLineCount;
		pump.cancel(reviewPreparationWork.id);

		expect(firstRun).toEqual({ completedIds: [], yielded: true });
		expect(cancelledAtLineCount).toBe(8);
		expect(pump.getPendingWorkIds()).toEqual([]);
		expect(publishedMainPayloads).toEqual([]);

		pump.enqueue(reviewPreparationWork);
		let runCount = 1;
		for (; runCount < 2_250 && pump.getPendingWorkIds().length > 0; runCount += 1) {
			pump.runUntilBudget();
		}

		expect(completedLineCount).toBe(totalLineCount);
		expect(runCount).toBe(2_250);
		expect(pump.getPendingWorkIds()).toEqual([]);
		expect([...processingCounts].every((processingCount) => processingCount === 1)).toBe(true);
		expect(publishedMainPayloads).toEqual([
			{
				direction: 'serverWorkerToMain',
				epoch: 41,
				kind: 'slicePatch',
				patches: [
					{
						itemId: 'review-item-18k',
						operation: 'upsert',
						payload: { state: 'loading' },
						slice: 'contentAvailability',
					},
				],
				sequence: 1,
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			},
		]);
		expect(JSON.stringify(publishedMainPayloads)).not.toMatch(/package|rootSnapshot|allRows/iu);
	});

	test('promotes an existing work item without duplicating completed preparation', () => {
		let clockMs = 0;
		const executionOrder: string[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 2,
			now: () => clockMs,
		});
		let sharedProgress = 0;
		const sharedWork = {
			id: 'shared-file',
			rank: 'background' as const,
			runSlice: () => {
				sharedProgress += 1;
				executionOrder.push(`shared:${sharedProgress}`);
				clockMs += 1;
				return { complete: sharedProgress === 2 };
			},
		};

		pump.enqueue(sharedWork);
		pump.enqueueOrPromote({
			...sharedWork,
			rank: 'selected',
		});

		expect(pump.getPendingWorkIds()).toEqual(['shared-file']);
		const result = pump.runUntilBudget();

		expect(result.completedIds).toEqual(['shared-file']);
		expect(sharedProgress).toBe(2);
		expect(executionOrder).toEqual(['shared:1', 'shared:2']);
		expect(pump.getPendingWorkIds()).toEqual([]);
	});

	test('records queue wait and handler duration by rank and work kind', () => {
		let clockMs = 0;
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 8,
			now: () => clockMs,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});

		pump.enqueue({
			id: 'visible-review-content',
			rank: 'visible',
			telemetry: {
				payloadClass: 'inline',
				sourceEpoch: 7,
				workKind: 'review_content_ready',
			},
			runSlice: (context) => {
				expect(context).toMatchObject({
					elapsedMs: 0,
					maxSliceMs: 8,
					remainingBudgetMs: 8,
				});
				clockMs += 3;
				expect(context.shouldYield()).toBe(false);
				return { complete: true };
			},
		});
		clockMs = 5;

		const result = pump.runUntilBudget();

		expect(result.completedIds).toEqual(['visible-review-content']);
		expect(telemetrySamples).toHaveLength(1);
		expect(telemetrySamples[0]).toMatchObject({
			name: 'performance.bridge.worker.task',
			durationMilliseconds: 3,
			stringAttributes: {
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.worker.lane': 'visible',
				'agentstudio.bridge.worker.payload_class': 'inline',
				'agentstudio.bridge.worker.task_kind': 'content_preparation',
				'agentstudio.bridge.worker.work_kind': 'review_content_ready',
			},
			numericAttributes: {
				'agentstudio.bridge.worker.handler_duration_ms': 3,
				'agentstudio.bridge.worker.queue_wait_ms': 5,
				'agentstudio.bridge.worker.source_epoch': 7,
			},
		});
	});

	test('records one content preparation task after three slices with first queue wait', () => {
		let clockMs = 0;
		let sliceCount = 0;
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 4,
			now: () => clockMs,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		pump.enqueue({
			id: 'three-slice-review',
			rank: 'visible',
			telemetry: { workKind: 'review_content_ready' },
			runSlice: () => {
				sliceCount += 1;
				clockMs += 2;
				return { complete: sliceCount === 3 };
			},
		});
		clockMs = 5;
		expect(pump.runUntilBudget()).toEqual({ completedIds: [], yielded: true });
		expect(telemetrySamples).toEqual([]);
		expect(pump.runUntilBudget()).toEqual({ completedIds: ['three-slice-review'], yielded: false });
		expect(telemetrySamples).toHaveLength(1);
		expect(telemetrySamples[0]).toMatchObject({
			durationMilliseconds: 6,
			stringAttributes: {
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.worker.task_kind': 'content_preparation',
			},
			numericAttributes: {
				'agentstudio.bridge.worker.handler_duration_ms': 6,
				'agentstudio.bridge.worker.queue_wait_ms': 5,
			},
		});
	});

	test('records one cancelled content preparation task after its partial slice', () => {
		let clockMs = 0;
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 2,
			now: () => clockMs,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		pump.enqueue({
			id: 'cancelled-review',
			rank: 'visible',
			runSlice: () => {
				clockMs += 2;
				return { complete: false };
			},
		});
		expect(pump.runUntilBudget()).toEqual({ completedIds: [], yielded: true });
		pump.cancel('cancelled-review');
		expect(telemetrySamples).toHaveLength(1);
		expect(telemetrySamples[0]).toMatchObject({
			durationMilliseconds: 2,
			stringAttributes: {
				'agentstudio.bridge.result': 'cancelled',
				'agentstudio.bridge.worker.task_kind': 'content_preparation',
			},
		});
	});

	test('re-stamps queue wait when lower-priority work promotes to selected', () => {
		let clockMs = 0;
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const pump = createWorkerContentPreparationPump({
			maxSliceMs: 8,
			now: () => clockMs,
			telemetryClient: {
				record: (sample): void => {
					telemetrySamples.push(sample);
				},
			},
		});
		const sharedWork = {
			id: 'shared-review-content',
			rank: 'background' as const,
			telemetry: {
				payloadClass: 'inline',
				sourceEpoch: 11,
				workKind: 'review_content_ready',
			},
			runSlice: () => {
				clockMs += 2;
				return { complete: true };
			},
		};

		pump.enqueue(sharedWork);
		clockMs = 20;
		pump.enqueueOrPromote({
			...sharedWork,
			rank: 'selected',
		});
		clockMs = 25;

		pump.runUntilBudget();

		expect(telemetrySamples[0]).toMatchObject({
			stringAttributes: {
				'agentstudio.bridge.worker.lane': 'selected',
			},
			numericAttributes: {
				'agentstudio.bridge.worker.queue_wait_ms': 5,
			},
		});
	});
});
