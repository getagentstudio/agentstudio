import { describe, expect, test } from 'vitest';

import { makeReviewTestBatch } from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import { createRenderStallRecoveryHarness } from './bridge-render-stall-recovery.test-support.js';
import { makeFileBatchInstallation } from './comm-runtime-protocol.file-product.test-support.js';

describe('Main and Comm bounded render stall recovery', () => {
	test.each(['review', 'file'] as const)(
		'%s queued render exhaustion preserves its delivery budget and sibling view',
		async (surface) => {
			const harness = await createRenderStallRecoveryHarness(surface);
			try {
				if (surface === 'file') await harness.select('file-1');
				await harness.setVisible([surface === 'file' ? 'file-1' : 'item-1']);
				const before = harness.viewRecoveryState(harness.subscriptionId);
				const siblingBefore = harness.viewRecoveryState(harness.siblingSubscriptionId);
				expect(before?.consecutiveResnapshots).toBe(0);
				expect(siblingBefore).toEqual({ consecutiveResnapshots: 0, status: 'ready' });
				harness.acceptLatestRender();
				await harness.advanceRenderWake();
				await harness.advanceRenderWake();
				harness.acceptLatestRender();
				await harness.advanceRenderWake();
				expect(harness.nextRenderWakeAt()).toBeNull();
				expect.soft(harness.viewRecoveryState(harness.subscriptionId)).toEqual({
					consecutiveResnapshots: before?.consecutiveResnapshots,
					status: 'failedRetryable',
				});
				expect
					.soft(harness.viewRecoveryState(harness.siblingSubscriptionId))
					.toEqual(siblingBefore);
			} finally {
				await harness.close();
			}
		},
	);

	test.each(['review', 'file'] as const)(
		'%s certified newer-input install heals exhausted render without Retry',
		async (surface) => {
			const harness = await createRenderStallRecoveryHarness(surface);
			try {
				if (surface === 'file') await harness.select('file-1');
				await harness.setVisible([surface === 'file' ? 'file-1' : 'item-1']);
				harness.acceptLatestRender();
				await harness.advanceRenderWake();
				await harness.advanceRenderWake();
				const exhausted = harness.acceptLatestRender();
				await harness.advanceRenderWake();
				expect(harness.viewRecoveryState(harness.subscriptionId)).toEqual({
					consecutiveResnapshots: 0,
					status: 'failedRetryable',
				});
				const bank =
					surface === 'review'
						? makeReviewTestBatch({
								snapshotCause: 'newerInput',
								subscriptionId: harness.subscriptionId,
								revision: 12,
								withContent: true,
							})
						: makeFileBatchInstallation('newerInput', harness.subscriptionId, { revision: 5 });
				await harness.install({
					...bank,
					records: bank.records.map((entry) => {
						if (surface === 'review') {
							const record = bridgeProductReviewBatchRecordSchema.parse(entry.value);
							if (record.recordKind !== 'item') return entry;
							return {
								...entry,
								value: {
									...record,
									contentByRole: Object.fromEntries(
										Object.entries(record.contentByRole).map(([role, content]) => [
											role,
											content.state === 'available'
												? {
														...content,
														source: {
															...content.source,
															contentDigest: {
																...content.source.contentDigest,
																value: 'd'.repeat(64),
															},
														},
													}
												: content,
										]),
									),
								},
							};
						}
						const parsed = bridgeProductFileBatchRowSchema.safeParse(entry.value);
						if (!parsed.success || parsed.data.readDescriptor === null) return entry;
						const row = parsed.data;
						const descriptor = {
							...parsed.data.readDescriptor,
							descriptorId: 'file-descriptor-successor',
							source: {
								...parsed.data.readDescriptor.source,
								sourceCursor: 'successor-source-cursor',
							},
						};
						if (row.descriptorOutcome?.availability.availabilityKind !== 'available') return entry;
						return {
							...entry,
							value: bridgeProductFileBatchRowSchema.parse({
								...row,
								readDescriptor: descriptor,
								descriptorOutcome: {
									...row.descriptorOutcome,
									source: descriptor.source,
									availability: {
										...row.descriptorOutcome.availability,
										contentDescriptor: descriptor,
									},
								},
							}),
						};
					}),
				});
				expect(harness.viewRecoveryState(harness.subscriptionId)).toEqual({
					consecutiveResnapshots: 0,
					status: 'ready',
				});
				expect(harness.publications()).toHaveLength(3);
				const successor = harness.acceptLatestRender();
				expect(successor.renderReceiptIdentity.windowKey).not.toBe(
					exhausted.renderReceiptIdentity.windowKey,
				);
				harness.paint(successor);
				expect(harness.receipts.at(-1)?.disposition).toBe('painted');
				expect(harness.resnapshotCount()).toBe(0);
			} finally {
				await harness.close();
			}
		},
	);

	test.each([true, false])(
		'BH2: queued selected File render exhausts and unchanged-input Retry paints (visible: %s)',
		async (visible) => {
			const harness = await createRenderStallRecoveryHarness('file');
			try {
				await harness.select('file-1');
				if (visible) await harness.setVisible(['file-1']);
				harness.acceptLatestRender();
				expect(harness.receipts.map((receipt) => receipt.disposition)).toEqual(['queued']);
				expect(harness.nextRenderWakeAt()).toBe(5_000);
				await harness.advanceRenderWake();
				await harness.advanceRenderWake();
				expect(harness.publications()).toHaveLength(2);
				const exhausted = harness.acceptLatestRender();
				await harness.advanceRenderWake();
				expect(harness.recoveryStatuses.at(-1)).toMatchObject({
					status: 'failedRetryable',
					view: { kind: 'file.metadata' },
				});
				expect(
					harness.recoveryStatuses.filter((status) => status.status === 'failedRetryable'),
				).toHaveLength(1);
				expect(harness.telemetrySamples).toContainEqual(
					expect.objectContaining({
						stringAttributes: expect.objectContaining({
							'agentstudio.bridge.phase': 'file_content_operation_terminal',
							'agentstudio.bridge.result': 'failure',
						}),
					}),
				);
				expect(harness.nextRenderWakeAt()).toBeNull();
				expect(harness.messages).toContainEqual(
					expect.objectContaining({
						kind: 'fileRenderPatch',
						patches: expect.arrayContaining([
							expect.objectContaining({
								slice: 'contentAvailability',
								payload: expect.objectContaining({ state: 'failed', reason: 'load_failed' }),
							}),
						]),
					}),
				);
				await harness.whenIdle();
				expect(harness.publications()).toHaveLength(2);
				await harness.retry();
				expect(harness.viewRecoveryState(harness.subscriptionId)?.status).toBe('recovering');
				expect(harness.resnapshotCount()).toBe(1);
				await harness.install(
					makeFileBatchInstallation('open', harness.subscriptionId, { revision: 5 }),
				);
				expect(harness.publications()).toHaveLength(3);
				const retry = harness.acceptLatestRender();
				expect(retry.renderReceiptIdentity.attemptId).not.toBe(
					exhausted.renderReceiptIdentity.attemptId,
				);
				harness.paint(exhausted);
				expect(harness.receipts.at(-1)?.disposition).toBe('queued');
				harness.paint(retry);
				await harness.whenIdle();
				expect(harness.receipts.slice(-3).map((receipt) => receipt.disposition)).toEqual([
					'queued',
					'applied',
					'painted',
				]);
				expect(harness.telemetrySamples).toContainEqual(
					expect.objectContaining({
						stringAttributes: expect.objectContaining({
							'agentstudio.bridge.phase': 'file_content_operation_terminal',
							'agentstudio.bridge.result': 'success',
						}),
					}),
				);
				expect(harness.nextRenderWakeAt()).toBeNull();
			} finally {
				await harness.close();
			}
		},
	);

	test('BH8: missing first File disposition exhausts once and unchanged-input Retry repaints', async () => {
		const harness = await createRenderStallRecoveryHarness('file');
		try {
			await harness.select('file-1');
			harness.setReceiptDelivery(false);
			harness.acceptLatestRender();
			await harness.advanceRenderWake();
			await harness.advanceRenderWake();
			expect(harness.publications()).toHaveLength(2);
			harness.acceptLatestRender();
			await harness.advanceRenderWake();
			expect(
				harness.recoveryStatuses.filter((status) => status.status === 'failedRetryable'),
			).toHaveLength(1);
			expect(harness.nextRenderWakeAt()).toBeNull();
			await harness.whenIdle();
			expect(harness.publications()).toHaveLength(2);
			harness.setReceiptDelivery(true);
			await harness.retry();
			await harness.install(
				makeFileBatchInstallation('open', harness.subscriptionId, { revision: 5 }),
			);
			expect(harness.publications()).toHaveLength(3);
			harness.paint(harness.acceptLatestRender());
			await harness.whenIdle();
			expect(harness.receipts.at(-1)?.disposition).toBe('painted');
			expect(harness.nextRenderWakeAt()).toBeNull();
		} finally {
			await harness.close();
		}
	});

	test('BH5: exhausted Review window A cannot disable new content window B ender', async () => {
		const harness = await createRenderStallRecoveryHarness('review');
		try {
			await harness.setVisible(['item-1']);
			harness.acceptLatestRender();
			await harness.advanceRenderWake();
			await harness.advanceRenderWake();
			const identityA = harness.acceptLatestRender().renderReceiptIdentity;
			await harness.advanceRenderWake();
			expect(harness.recoveryStatuses.at(-1)?.status).toBe('failedRetryable');
			const bank = makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: harness.subscriptionId,
				revision: 12,
				withContent: true,
			});
			await harness.install({
				...bank,
				records: bank.records.map((entry) => {
					const record = bridgeProductReviewBatchRecordSchema.parse(entry.value);
					if (record.recordKind !== 'item') return entry;
					return {
						...entry,
						value: bridgeProductReviewBatchRecordSchema.parse({
							...record,
							contentByRole: Object.fromEntries(
								Object.entries(record.contentByRole).map(([role, content]) => [
									role,
									content.state === 'available'
										? Object.assign({}, content, {
												source: {
													...content.source,
													contentDigest: { ...content.source.contentDigest, value: 'd'.repeat(64) },
												},
											})
										: content,
								]),
							),
						}),
					};
				}),
			});
			expect(harness.publications()).toHaveLength(3);
			const identityB = harness.acceptLatestRender().renderReceiptIdentity;
			expect(identityB.windowKey).not.toBe(identityA.windowKey);
			expect(harness.nextRenderWakeAt()).toBe(15_025);
			await harness.advanceRenderWake();
			await harness.advanceRenderWake();
			harness.acceptLatestRender();
			await harness.advanceRenderWake();
			expect(
				harness.recoveryStatuses.filter((status) => status.status === 'failedRetryable'),
			).toHaveLength(2);
			expect(harness.nextRenderWakeAt()).toBeNull();
		} finally {
			await harness.close();
		}
	});
});
