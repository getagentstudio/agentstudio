import { expect } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewRecoveryRetryCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import {
	registerBridgeCommWorkerRuntimePortProtocol,
	type BridgeCommWorkerPreparationDrain,
} from './bridge-comm-worker-runtime-protocol.js';
import {
	createReviewBatchSinkCapture,
	makeIdleReviewMetadataSubscription,
	makeReviewProductTransport,
	makeReviewTestBatch,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	activateBridgeCommWorkerFileViewerMode,
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import {
	createBridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderPublication,
} from './bridge-main-render-fulfillment-coordinator.js';
import {
	connectedReadback,
	createControlledAnimationFrames,
} from './bridge-main-render-fulfillment-coordinator.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductControlMux } from './bridge-product-session-authority.js';
import type { BridgeProductViewInstallation } from './bridge-product-view-batch-receiver.js';
import {
	BridgeProductViewScopeOwner,
	type BridgeProductViewScopeSettlement,
} from './bridge-product-view-scope-owner.js';
import {
	bridgeWorkerServerToMainMessageSchema,
	type BridgeWorkerViewRecoveryStatusEvent,
} from './bridge-worker-contracts.js';
import type { BridgeWorkerRenderDispositionReceipt } from './bridge-worker-render-fulfillment.js';
import {
	makeFileBatchInstallation,
	makeFileProductTestTransport,
} from './comm-runtime-protocol.file-product.test-support.js';

interface ScheduledRecoveryWake {
	active: boolean;
	readonly atMilliseconds: number;
	readonly kind: 'render' | 'view';
	readonly fire: () => void;
}

type RecordedRuntimeMessage = ReturnType<
	typeof createRecordingBridgeCommWorkerPort
>['postedMessages'][number]['message'];
type RecordedTelemetrySample = Parameters<BridgeCommWorkerTelemetryRecorder['record']>[0];

export interface RenderStallRecoveryHarness {
	readonly acceptLatestRender: () => BridgeMainRenderPublication;
	readonly advanceRenderWake: () => Promise<void>;
	readonly close: () => Promise<void>;
	readonly install: (bank: BridgeProductViewInstallation) => Promise<void>;
	readonly initialBank: BridgeProductViewInstallation;
	readonly nextRenderWakeAt: () => number | null;
	readonly paint: (publication: BridgeMainRenderPublication) => void;
	readonly publications: () => readonly BridgeMainRenderPublication[];
	readonly receipts: readonly BridgeWorkerRenderDispositionReceipt[];
	readonly recoveryStatuses: readonly Pick<
		BridgeWorkerViewRecoveryStatusEvent,
		'status' | 'view'
	>[];
	readonly retry: () => Promise<void>;
	readonly resnapshotCount: () => number;
	readonly select: (itemId: string) => Promise<void>;
	readonly setVisible: (itemIds: readonly string[]) => Promise<void>;
	readonly setReceiptDelivery: (enabled: boolean) => void;
	readonly subscriptionId: string;
	readonly telemetrySamples: readonly RecordedTelemetrySample[];
	readonly whenIdle: () => Promise<void>;
	readonly messages: readonly RecordedRuntimeMessage[];
}

export async function createRenderStallRecoveryHarness(
	surface: 'file' | 'review',
): Promise<RenderStallRecoveryHarness> {
	let nowMilliseconds = 0;
	let commandEpoch = 10;
	let receiptOrdinal = 0;
	let receiptDeliveryEnabled = true;
	let scopeRevision = 0;
	let resnapshotCount = 0;
	let viewIdentifierOrdinal = 0;
	const wakes: ScheduledRecoveryWake[] = [];
	const tasks = new Set<Promise<unknown>>();
	const receipts: BridgeWorkerRenderDispositionReceipt[] = [];
	const telemetrySamples: RecordedTelemetrySample[] = [];
	const recoveryStatuses: Array<Pick<BridgeWorkerViewRecoveryStatusEvent, 'status' | 'view'>> = [];
	const subscriptionId = `${surface}-render-stall`;
	const events = new BridgeProductBoundedAsyncQueue<never>(1);
	const batches = createReviewBatchSinkCapture();
	const scheduleWake = (
		kind: ScheduledRecoveryWake['kind'],
		delay: number,
		fire: () => void,
	): (() => void) => {
		const wake = { active: true, atMilliseconds: nowMilliseconds + delay, kind, fire };
		wakes.push(wake);
		return (): void => {
			wake.active = false;
		};
	};
	const track = (task: Promise<unknown>): void => {
		tasks.add(task);
		void task.then(
			(): void => {
				tasks.delete(task);
			},
			(): void => {
				tasks.delete(task);
			},
		);
	};
	const whenIdle = async (): Promise<void> => {
		if (tasks.size === 0) return;
		await Promise.all(tasks);
		await whenIdle();
	};
	const viewOwner = new BridgeProductViewScopeOwner({
		controlMux: {
			resnapshotView: async (
				request,
			): Promise<Awaited<ReturnType<BridgeProductControlMux['resnapshotView']>>> => {
				resnapshotCount += 1;
				return {
					...request,
					kind: 'subscription.resnapshotAccepted',
					paneSessionId: 'render-stall-pane',
					requestId: `resnapshot-${resnapshotCount}`,
					requestSequence: resnapshotCount,
					wireVersion: 2,
					workerInstanceId: 'render-stall-worker',
				};
			},
			setViewScope: async (
				request,
			): Promise<Awaited<ReturnType<BridgeProductControlMux['setViewScope']>>> => ({
				...request,
				kind: 'subscription.scopeAccepted',
				paneSessionId: 'render-stall-pane',
				requestId: `scope-${request.scopeRevision}`,
				requestSequence: request.scopeRevision,
				wireVersion: 2,
				workerInstanceId: 'render-stall-worker',
			}),
		},
		createIdentifier: (): string => `render-view-${++viewIdentifierOrdinal}`,
		deadlineClock: { schedule: (delay, fire): (() => void) => scheduleWake('view', delay, fire) },
		maximumConsecutiveResnapshots: 2,
		onViewRecoveryStatus: (status): void => {
			recoveryStatuses.push(status);
		},
		progressDeadlineMilliseconds: 5_000,
	});
	viewOwner.register({
		subscriptionId,
		subscriptionKind: surface === 'file' ? 'file.metadata' : 'review.metadata',
		scope:
			surface === 'file'
				? { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] }
				: { kind: 'review', interests: [] },
	});
	const baseTransport =
		surface === 'file'
			? makeFileProductTestTransport({
					onBatchFrameSinks: batches.onBatchFrameSinks,
					onDiscoverSource: (): void => {},
					onOpenDescriptor: (): void => {},
					subscription: {
						subscriptionId,
						subscriptionKind: 'file.metadata',
						events,
						cancel: async (): Promise<void> => events.close(true),
					},
				})
			: makeReviewProductTransport({
					onBatchFrameSinks: batches.onBatchFrameSinks,
					reviewSubscription: makeIdleReviewMetadataSubscription(subscriptionId),
					subscribedKinds: [],
				});
	const transport = {
		...baseTransport,
		failFileRender: (): void => viewOwner.failViewsOfKind('file.metadata'),
		failReviewRender: (): void => viewOwner.failViewsOfKind('review.metadata'),
		retryView: (id: string): Promise<void> => {
			const task = viewOwner.retryView(id);
			track(task);
			return task;
		},
		setViewScopeForSubscription: async (
			request: Parameters<NonNullable<typeof baseTransport.setViewScopeForSubscription>>[0],
		): Promise<BridgeProductViewScopeSettlement> => {
			const settlement = await viewOwner.setScope(request);
			if (settlement.kind === 'accepted') scopeRevision = settlement.scopeRevision;
			return settlement;
		},
	};
	const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort({
		beforePostMessage: (message): void => {
			bridgeWorkerServerToMainMessageSchema.parse(message);
		},
	});
	const frames = createControlledAnimationFrames();
	const mainOwner = createBridgeMainRenderFulfillmentCoordinator({
		cancelAnimationFrame: frames.cancelAnimationFrame,
		requestAnimationFrame: frames.requestAnimationFrame,
		nowMilliseconds: (): number => nowMilliseconds,
		sendDisposition: (receipt): void => {
			receipts.push(receipt);
			if (!receiptDeliveryEnabled) return;
			dispatch.message(
				encodeBridgeWorkerRenderDispositionCommand({
					epoch: receipt.workerDerivationEpoch,
					requestId: `render-receipt-${++receiptOrdinal}`,
					receipts: [receipt],
				}),
			);
		},
	});
	registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
		bridgeDemandRank: { lane: 'selected', priority: 0 },
		budget: { className: 'interactive', maxBytes: 524_288, maxWindowLines: 400 },
		now: (): number => nowMilliseconds,
		openReviewContent: (descriptor) =>
			makeImmediateReviewContentStream(descriptor, 'hello world\n'),
		productTransport: transport,
		renderFulfillmentContext: {
			paneSessionId: 'render-stall-pane',
			workerInstanceId: 'render-stall-worker',
		},
		schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void =>
			track(Promise.resolve().then(drain)),
		scheduleRenderFulfillmentWake: (delay, fire): (() => void) =>
			scheduleWake('render', delay, fire),
		telemetryClient: {
			record: (sample): void => {
				telemetrySamples.push(sample);
			},
		},
	});
	if (surface === 'file') activateBridgeCommWorkerFileViewerMode(dispatch, 'render-stall');
	else activateBridgeCommWorkerReviewViewerMode(dispatch, 'render-stall');
	await waitForMessage(
		(message) =>
			message.kind === 'health' && message.requestId === `request-${surface}-mode-render-stall`,
	);
	const install = async (bank: BridgeProductViewInstallation): Promise<void> => {
		await batches.install(bank);
		await whenIdle();
		viewOwner.recordCertifiedInstall({
			subscriptionId,
			handle: 'render-view-1',
			incarnation: 'render-view-2',
			scopeRevision,
		});
	};
	const initialBank =
		surface === 'file'
			? makeFileBatchInstallation('open', subscriptionId)
			: makeReviewTestBatch({ snapshotCause: 'open', subscriptionId, withContent: true });
	await install(initialBank);
	const publications = (): readonly BridgeMainRenderPublication[] =>
		postedMessages.flatMap(({ message }) =>
			message.kind === 'filePierreRenderJob' || message.kind === 'reviewPierreRenderJob'
				? [message]
				: [],
		);
	return {
		acceptLatestRender: (): BridgeMainRenderPublication => {
			const publication = publications().at(-1);
			if (publication === undefined) throw new Error('Expected demanded Comm render publication.');
			expect(mainOwner.acceptPublication(publication)).toBe('accepted');
			const item = publication.job.payload.item;
			mainOwner.bindPublicationItem({
				finalItem: item,
				publicationItem: item,
				residency: 'replaced',
			});
			mainOwner.markPublicationQueued(publication);
			mainOwner.reconcilePublication({
				itemId: item.id,
				readCurrentItem: () => item,
				readRenderedItem: () => null,
			});
			return publication;
		},
		advanceRenderWake: async (): Promise<void> => {
			const wake = wakes.find((candidate) => candidate.active && candidate.kind === 'render');
			if (wake === undefined) throw new Error('Expected a finite render fulfillment wake.');
			nowMilliseconds = wake.atMilliseconds;
			wake.active = false;
			wake.fire();
			await whenIdle();
		},
		close: async (): Promise<void> => {
			mainOwner.dispose();
			viewOwner.retire(subscriptionId);
			events.close(true);
			await whenIdle();
		},
		initialBank,
		install,
		nextRenderWakeAt: (): number | null =>
			wakes.find((wake) => wake.active && wake.kind === 'render')?.atMilliseconds ?? null,
		paint: (publication): void => {
			const item = publication.job.payload.item;
			mainOwner.observePostRender({
				...connectedReadback(item),
				contextItem: item,
				itemId: item.id,
				phase: 'mount',
			});
			for (const frame of frames.activeFrameHandles()) frames.runActiveFrame(frame);
		},
		publications,
		receipts,
		recoveryStatuses,
		resnapshotCount: (): number => resnapshotCount,
		retry: async (): Promise<void> => {
			dispatch.message(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: ++commandEpoch,
					requestId: 'retry-render-stall',
					view: { kind: surface === 'file' ? 'file.metadata' : 'review.metadata', subscriptionId },
				}),
			);
			await whenIdle();
		},
		select: async (itemId): Promise<void> => {
			dispatch.message(
				encodeBridgeWorkerSelectCommand({
					epoch: ++commandEpoch,
					requestId: `select-${commandEpoch}`,
					selectedItemId: itemId,
					selectedSource: 'user',
					surface: surface === 'file' ? 'fileView' : 'review',
				}),
			);
			await whenIdle();
		},
		setVisible: async (itemIds): Promise<void> => {
			dispatch.message(
				encodeBridgeWorkerViewportCommand({
					epoch: ++commandEpoch,
					requestId: `viewport-${commandEpoch}`,
					firstVisibleIndex: 0,
					lastVisibleIndex: itemIds.length - 1,
					phase: 'settled',
					surface: surface === 'file' ? 'fileView' : 'review',
					visibleItemIds: itemIds,
				}),
			);
			await whenIdle();
		},
		setReceiptDelivery: (enabled): void => {
			receiptDeliveryEnabled = enabled;
		},
		subscriptionId,
		telemetrySamples,
		whenIdle,
		get messages(): readonly RecordedRuntimeMessage[] {
			return postedMessages.map(({ message }) => message);
		},
	};
}
