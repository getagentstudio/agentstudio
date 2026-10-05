import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	createRecordingBridgeCommWorkerPort,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type {
	BridgeProductContentTerminal,
	BridgeProductFileContentDescriptor,
} from './bridge-product-content-contracts.js';
import { bridgeProductFileBatchRowSchema } from './bridge-product-file-batch-row-contracts.js';
import { bridgeProductFileMemberStatusRecordSchema } from './bridge-product-file-member-status-contracts.js';
import type { BridgeProductPanePresentationFrame } from './bridge-product-transport.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';
import {
	fileViewProductTestBudget,
	makeFileBatchInstallation,
	makeFilePanePresentationFrame,
	makeFileProductTestTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

describe('Bridge File selected-read supersession', () => {
	test.each(['descriptor', 'request'] as const)(
		'replaces an in-flight read after a healthy same-source %s change and fulfills paint',
		async (changeKind) => {
			const scenario = await createSelectedReadScenario();
			try {
				// Arrange: hold the selected read at its real content terminal boundary.
				scenario.select();
				const firstOpen = await scenario.firstOpen.promise;
				const replacement = makeSuccessorInstallation(scenario.subscriptionId, changeKind);

				// Act: a healthy W4 source refresh changes identity without changing the warmup key.
				await scenario.install(replacement);

				// Assert before releasing anything: cancellation is a synchronous admission decision.
				expect(firstOpen.signal.aborted).toBe(true);
				expect(scenario.openedDescriptors).toHaveLength(1);
				scenario.firstTerminal.reject(new Error('Superseded read settled.'));
				const successor = await scenario.secondOpen.promise;
				expect(successor.descriptor.descriptorId).toBe(
					changeKind === 'descriptor' ? 'file-descriptor-successor' : 'file-descriptor-1',
				);
				const renderJob = await scenario.waitForMessage(
					(message) => message.kind === 'filePierreRenderJob',
				);
				if (renderJob.kind !== 'filePierreRenderJob') throw new Error('Expected File render job.');
				expect(renderJob.job.payload).toMatchObject({
					kind: 'codeViewFileItem',
					item: { file: { name: 'src/a.ts', contents: 'abc' } },
				});
				expect(scenario.openedDescriptors).toHaveLength(2);
				const ready = await scenario.waitForMessage(
					(message) =>
						message.kind === 'fileRenderPatch' &&
						message.patches.some(
							(patch) =>
								patch.slice === 'contentAvailability' &&
								patch.operation === 'upsert' &&
								patch.payload.state === 'ready',
						),
				);
				expect(ready.kind).toBe('fileRenderPatch');
				// Close the actual render publication through its exact paint receipt.
				scenario.dispatch.message(
					encodeBridgeWorkerRenderDispositionCommand({
						epoch: 1,
						requestId: 'supersession-painted',
						receipts: [
							{
								...renderJob.renderReceiptIdentity,
								disposition: 'painted',
								kind: 'render.disposition',
								receivedAtMilliseconds: 0,
							},
						],
					}),
				);
				await scenario.waitForMessage(
					(message) => message.kind === 'health' && message.requestId === 'supersession-painted',
				);
			} finally {
				await scenario.close();
			}
		},
	);

	test('an identical selected-demand wake retains its active read', async () => {
		const scenario = await createSelectedReadScenario();
		try {
			scenario.select();
			const firstOpen = await scenario.firstOpen.promise;
			// File refresh settlement wakes retained demand without changing request identity.
			scenario.present({
				...makeFilePanePresentationFrame(2, 'foreground'),
				refreshingLanes: ['file'],
			});
			scenario.present(makeFilePanePresentationFrame(3, 'foreground'));
			expect(firstOpen.signal.aborted).toBe(false);
			expect(scenario.openedDescriptors).toHaveLength(1);
			scenario.firstTerminal.resolve(completedFileContent(firstOpen.descriptor));
			await scenario.waitForMessage((message) => message.kind === 'filePierreRenderJob');
			expect(scenario.openedDescriptors).toHaveLength(1);
		} finally {
			await scenario.close();
		}
	});

	test('a persistent non-abort content failure stays Failed after the existing bounded retry', async () => {
		const scenario = await createSelectedReadScenario({ failSubsequentReads: true });
		try {
			scenario.select();
			const firstOpen = await scenario.firstOpen.promise;
			scenario.firstTerminal.reject(new Error('Content read failed.'));
			const firstFailure = await scenario.waitForMessage(isFailedFileRenderPatch);
			if (firstFailure.kind !== 'fileRenderPatch') throw new Error('Expected failed File patch.');
			await scenario.secondOpen.promise;
			await scenario.waitForMessage(
				(message) =>
					isFailedFileRenderPatch(message) &&
					message.kind === 'fileRenderPatch' &&
					message.publicationSequence !== firstFailure.publicationSequence,
			);
			expect(firstOpen.signal.aborted).toBe(false);
			expect(scenario.openedDescriptors).toHaveLength(2);
			expect(
				scenario.postedMessages.some(({ message }) => message.kind === 'filePierreRenderJob'),
			).toBe(false);
		} finally {
			await scenario.close();
		}
	});
});

type SelectedReadObservation = {
	readonly descriptor: BridgeProductFileContentDescriptor;
	readonly signal: AbortSignal;
};

type SelectedReadScenario = ReturnType<typeof createRecordingBridgeCommWorkerPort> & {
	readonly firstOpen: ReturnType<typeof createBridgeProductDeferred<SelectedReadObservation>>;
	readonly secondOpen: ReturnType<typeof createBridgeProductDeferred<SelectedReadObservation>>;
	readonly firstTerminal: ReturnType<
		typeof createBridgeProductDeferred<BridgeProductContentTerminal<'file.content'>>
	>;
	readonly install: (view: BridgeProductViewInstallation) => Promise<void>;
	readonly openedDescriptors: readonly BridgeProductFileContentDescriptor[];
	readonly present: (frame: BridgeProductPanePresentationFrame) => void;
	readonly subscriptionId: string;
	readonly select: () => void;
	readonly close: () => Promise<void>;
};

async function createSelectedReadScenario(
	props: { readonly failSubsequentReads?: boolean } = {},
): Promise<SelectedReadScenario> {
	const subscriptionId = 'file-subscription-supersession';
	const metadataEvents = new BridgeProductBoundedAsyncQueue<never>(64);
	const installed =
		createBridgeProductDeferred<(view: BridgeProductViewInstallation) => Promise<void>>();
	const firstTerminal = createBridgeProductDeferred<BridgeProductContentTerminal<'file.content'>>();
	const firstOpen = createBridgeProductDeferred<{
		readonly descriptor: BridgeProductFileContentDescriptor;
		readonly signal: AbortSignal;
	}>();
	const secondOpen = createBridgeProductDeferred<{
		readonly descriptor: BridgeProductFileContentDescriptor;
		readonly signal: AbortSignal;
	}>();
	const presentationSink =
		createBridgeProductDeferred<(frame: BridgeProductPanePresentationFrame) => void>();
	const openedDescriptors: BridgeProductFileContentDescriptor[] = [];
	const drainCompletions: Promise<unknown>[] = [];
	const port = createRecordingBridgeCommWorkerPort();
	registerBridgeCommWorkerRuntimePortProtocol(port.dispatch.port, {
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: fileViewProductTestBudget,
		fileViewBudget: fileViewProductTestBudget,
		productTransport: makeFileProductTestTransport({
			onBatchFrameSinks: (sinks): void =>
				installed.resolve(async (view): Promise<void> => {
					await sinks.install(view);
				}),
			onDiscoverSource: (): void => {},
			onOpenDescriptor: (): void => {},
			onPanePresentationSink: (sink): void => presentationSink.resolve(sink),
			subscription: {
				cancel: async (): Promise<void> => metadataEvents.close(true),
				events: metadataEvents,
				subscriptionId,
				subscriptionKind: 'file.metadata',
			},
		}),
		openFileViewContent: (descriptor, signal) => {
			openedDescriptors.push(descriptor);
			const first = openedDescriptors.length === 1;
			if (first) {
				firstOpen.resolve({ descriptor, signal });
			} else {
				secondOpen.resolve({ descriptor, signal });
			}
			return {
				contentKind: 'file.content',
				contentRequestId: `selected-read-${openedDescriptors.length}`,
				frames: emptyContentFrames(),
				terminal: first
					? firstTerminal.promise
					: props.failSubsequentReads === true
						? Promise.reject(new Error('Persistent content failure.'))
						: Promise.resolve(completedFileContent(descriptor)),
			};
		},
		// Drive each requested drain once; completion is announced by the owner, never polled.
		schedulePreparationDrain: (drain): void => {
			queueMicrotask((): void => {
				drainCompletions.push(drain());
			});
		},
		scheduleRenderFulfillmentWake: () => (): void => {},
	});
	activateBridgeCommWorkerFileViewerMode(port.dispatch, 'supersession');
	await port.waitForMessage(
		(message) =>
			message.kind === 'health' && message.requestId === 'request-file-mode-supersession',
	);
	const install = await installed.promise;
	await install(makeFileBatchInstallation(subscriptionId, { revision: 1 }));
	const present = await presentationSink.promise;
	return {
		...port,
		firstOpen,
		firstTerminal,
		install,
		openedDescriptors,
		present,
		secondOpen,
		subscriptionId,
		select: (): void =>
			port.dispatch.message(
				encodeBridgeWorkerSelectCommand({
					epoch: 1,
					requestId: 'select-supersession',
					selectedItemId: 'file-1',
					selectedSource: 'user',
					surface: 'fileView',
				}),
			),
		close: async (): Promise<void> => {
			port.dispatch.message(
				encodeBridgeWorkerSelectCommand({
					epoch: 2,
					requestId: 'close-supersession',
					selectedItemId: null,
					selectedSource: null,
					surface: 'fileView',
				}),
			);
			firstTerminal.reject(new Error('Selected read closed.'));
			metadataEvents.close(true);
			await Promise.all(drainCompletions);
		},
	};
}

function makeSuccessorInstallation(
	subscriptionId: string,
	changeKind: 'descriptor' | 'request',
): BridgeProductViewInstallation {
	const base = makeFileBatchInstallation(subscriptionId, { revision: 2 });
	return {
		...base,
		records: base.records.map((record) => {
			if (record.key === 'member-status') {
				const status = bridgeProductFileMemberStatusRecordSchema.parse(record.value);
				return {
					...record,
					value: {
						...status,
						source: { ...status.source, rootRevisionToken: 'revision-successor' },
					},
				};
			}
			const row = bridgeProductFileBatchRowSchema.parse(record.value);
			const outcome = row.descriptorOutcome;
			if (outcome?.availability.availabilityKind !== 'available') return record;
			const descriptor = {
				...outcome.availability.contentDescriptor,
				descriptorId:
					changeKind === 'descriptor' ? 'file-descriptor-successor' : 'file-descriptor-1',
			};
			return {
				...record,
				value: {
					...row,
					readDescriptor: descriptor,
					descriptorOutcome: {
						...outcome,
						language: changeKind === 'request' ? 'javascript' : outcome.language,
						availability: { availabilityKind: 'available', contentDescriptor: descriptor },
					},
				},
			};
		}),
	};
}

function completedFileContent(
	descriptor: BridgeProductFileContentDescriptor,
): BridgeProductContentTerminal<'file.content'> {
	return {
		bytes: new TextEncoder().encode('abc').buffer,
		contentKind: 'file.content',
		descriptorId: descriptor.descriptorId,
		endOfSource: true,
		observedByteLength: 3,
		kind: 'complete',
		observedSha256: descriptor.expectedSha256,
	};
}

async function* emptyContentFrames(): AsyncIterable<never> {}

function isFailedFileRenderPatch(message: BridgeWorkerServerToMainMessage): boolean {
	return (
		message.kind === 'fileRenderPatch' &&
		message.patches.some(
			(patch) =>
				patch.slice === 'contentAvailability' &&
				patch.operation === 'upsert' &&
				patch.payload.state === 'failed',
		)
	);
}
