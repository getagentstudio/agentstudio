import {
	createBridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderedItemReadback,
	type BridgeMainRenderFulfillmentCoordinator,
	type BridgeMainRenderPublication,
	type BridgeMainRenderPublicationItem,
	type BridgeMainRenderReadback,
} from './bridge-main-render-fulfillment-coordinator.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerFilePierreRenderJobEventSchema,
	bridgeWorkerReviewPierreRenderJobEventSchema,
	type BridgeWorkerFilePierreRenderJobEvent,
	type BridgeWorkerReviewPierreRenderJobEvent,
} from './bridge-worker-contracts.js';
import {
	buildBridgeWorkerPierreRenderJob,
	type BridgeWorkerRenderSourceCorrelation,
} from './bridge-worker-pierre-render-job.js';
import {
	bridgeWorkerRenderDispositionReceiptSchema,
	type BridgeWorkerPaintReleasedReceipt,
	type BridgeWorkerRenderDisposition,
	type BridgeWorkerRenderDispositionReceipt,
	type BridgeWorkerRenderRejectionReason,
} from './bridge-worker-render-fulfillment.js';

export const bridgeWorkerTestReviewPublicationIdentity = {
	packageId: 'test-review-package',
	publicationId: '00000000-0000-7000-8000-000000000001',
	reviewGeneration: 1,
	revision: 1,
	sourceIdentity: 'test-review-source',
} as const;
import { makeBridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.test-support.js';

export type {
	BridgeMainRenderedItemReadback,
	BridgeMainRenderFulfillmentCoordinator,
	BridgeMainRenderPublication,
	BridgeMainRenderPublicationItem,
} from './bridge-main-render-fulfillment-coordinator.js';

export interface CreateCoordinatorProps {
	readonly animationFrames: ControlledAnimationFrames;
	readonly dispositions: BridgeWorkerRenderDispositionReceipt[];
	readonly paintReleases?: BridgeWorkerPaintReleasedReceipt[];
	readonly nowMilliseconds: () => number;
}

export function createCoordinator(
	props: CreateCoordinatorProps,
): BridgeMainRenderFulfillmentCoordinator {
	return createBridgeMainRenderFulfillmentCoordinator({
		cancelAnimationFrame: props.animationFrames.cancelAnimationFrame,
		nowMilliseconds: props.nowMilliseconds,
		requestAnimationFrame: props.animationFrames.requestAnimationFrame,
		sendDisposition: (receipt): void => {
			props.dispositions.push(receipt);
		},
		sendPaintRelease: (receipt): void => {
			props.paintReleases?.push(receipt);
		},
	});
}

export interface CoordinatorHarness {
	readonly animationFrames: ControlledAnimationFrames;
	readonly coordinator: BridgeMainRenderFulfillmentCoordinator;
	readonly dispositions: BridgeWorkerRenderDispositionReceipt[];
	readonly paintReleases: BridgeWorkerPaintReleasedReceipt[];
	readonly setNowMilliseconds: (nextNowMilliseconds: number) => void;
}

export function createCoordinatorHarness(initialNowMilliseconds: number): CoordinatorHarness {
	let nowMilliseconds = initialNowMilliseconds;
	const animationFrames = createControlledAnimationFrames();
	const dispositions: BridgeWorkerRenderDispositionReceipt[] = [];
	const paintReleases: BridgeWorkerPaintReleasedReceipt[] = [];
	return {
		animationFrames,
		coordinator: createCoordinator({
			animationFrames,
			dispositions,
			paintReleases,
			nowMilliseconds: (): number => nowMilliseconds,
		}),
		dispositions,
		paintReleases,
		setNowMilliseconds: (nextNowMilliseconds): void => {
			nowMilliseconds = nextNowMilliseconds;
		},
	};
}

export interface ControlledAnimationFrames {
	readonly activeFrameHandles: () => readonly number[];
	readonly cancelAnimationFrame: (frameHandle: number) => void;
	readonly cancelledFrameHandles: () => readonly number[];
	readonly invokeHistoricalFrame: (frameHandle: number) => void;
	readonly requestAnimationFrame: (callback: FrameRequestCallback) => number;
	readonly runActiveFrame: (frameHandle: number) => void;
}

export function createControlledAnimationFrames(): ControlledAnimationFrames {
	let nextFrameHandle = 1;
	const activeCallbacksByFrameHandle = new Map<number, FrameRequestCallback>();
	const historicalCallbacksByFrameHandle = new Map<number, FrameRequestCallback>();
	const cancelledFrameHandles: number[] = [];
	const callbackForHandle = (frameHandle: number): FrameRequestCallback => {
		const callback = historicalCallbacksByFrameHandle.get(frameHandle);
		if (callback === undefined) {
			throw new Error(`Expected animation frame ${frameHandle} to have been scheduled.`);
		}
		return callback;
	};
	return {
		activeFrameHandles: (): readonly number[] => [...activeCallbacksByFrameHandle.keys()],
		cancelAnimationFrame: (frameHandle): void => {
			cancelledFrameHandles.push(frameHandle);
			activeCallbacksByFrameHandle.delete(frameHandle);
		},
		cancelledFrameHandles: (): readonly number[] => cancelledFrameHandles,
		invokeHistoricalFrame: (frameHandle): void => {
			callbackForHandle(frameHandle)(16.67);
		},
		requestAnimationFrame: (callback): number => {
			const frameHandle = nextFrameHandle;
			nextFrameHandle += 1;
			activeCallbacksByFrameHandle.set(frameHandle, callback);
			historicalCallbacksByFrameHandle.set(frameHandle, callback);
			return frameHandle;
		},
		runActiveFrame: (frameHandle): void => {
			if (!activeCallbacksByFrameHandle.delete(frameHandle)) {
				throw new Error(`Expected animation frame ${frameHandle} to be active.`);
			}
			callbackForHandle(frameHandle)(16.67);
		},
	};
}

export function connectedReadback(item: BridgeMainRenderPublicationItem): BridgeMainRenderReadback {
	return {
		readCurrentItem: (): BridgeMainRenderPublicationItem => item,
		readRenderedItem: (): BridgeMainRenderedItemReadback => ({
			element: testRenderedElement(true),
			item,
			readableContentMatchesItem: true,
		}),
	};
}

export function bindPublicationItemAsFinal(
	coordinator: BridgeMainRenderFulfillmentCoordinator,
	publication: BridgeMainRenderPublication,
): void {
	const publicationItem = publication.job.payload.item;
	coordinator.bindPublicationItem({
		finalItem: publicationItem,
		publicationItem,
		residency: 'replaced',
	});
}

export function expectedDisposition(
	publication: BridgeMainRenderPublication,
	disposition: BridgeWorkerRenderDisposition,
	receivedAtMilliseconds: number,
	reason?: BridgeWorkerRenderRejectionReason,
): BridgeWorkerRenderDispositionReceipt {
	if (disposition === 'rejected' || disposition === 'superseded') {
		if (reason === undefined) {
			throw new Error(`Expected ${disposition} receipt to declare a reason.`);
		}
		return bridgeWorkerRenderDispositionReceiptSchema.parse({
			...publication.renderReceiptIdentity,
			disposition,
			kind: 'render.disposition',
			reason,
			receivedAtMilliseconds,
			retryAtMilliseconds: receivedAtMilliseconds,
		});
	}
	return bridgeWorkerRenderDispositionReceiptSchema.parse({
		...publication.renderReceiptIdentity,
		disposition,
		kind: 'render.disposition',
		receivedAtMilliseconds,
	});
}

interface MakePublicationProps {
	readonly itemId: string;
	readonly operationCorrelationId?: string | null;
	readonly publicationSequence: number;
	readonly reviewPublicationIdentity?: {
		readonly packageId: string;
		readonly publicationId: string;
		readonly reviewGeneration: number;
		readonly revision: number;
		readonly sourceIdentity: string;
	};
	readonly sourceCorrelations?: readonly BridgeWorkerRenderSourceCorrelation[];
}

export function makeReviewPublication(
	props: MakePublicationProps,
): BridgeWorkerReviewPierreRenderJobEvent {
	const contentCacheKey = `review-cache-${props.publicationSequence}`;
	return bridgeWorkerReviewPierreRenderJobEventSchema.parse({
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'reviewPierreRenderJob',
		reviewPublicationIdentity:
			props.reviewPublicationIdentity ?? bridgeWorkerTestReviewPublicationIdentity,
		job: buildBridgeWorkerPierreRenderJob({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 4096, maxWindowLines: 20 },
			contentCacheKey,
			contentHash: `review-hash-${props.publicationSequence}`,
			itemId: props.itemId,
			language: 'typescript',
			payload: {
				kind: 'codeViewDiffItem',
				item: {
					bridgeMetadata: {
						cacheKey: contentCacheKey,
						contentRoles: ['base', 'head'],
						contentState: 'hydrated',
						displayPath: `Sources/${props.itemId}.ts`,
						itemId: props.itemId,
						lineCount: 2,
					},
					fileDiff: {
						additionLines: [`export const revision = ${props.publicationSequence};`],
						deletionLines: ['export const revision = 0;'],
						hunks: [],
						isPartial: false,
						name: `Sources/${props.itemId}.ts`,
						splitLineCount: 2,
						type: 'change',
						unifiedLineCount: 2,
					},
					id: props.itemId,
					type: 'diff',
					version: props.publicationSequence,
				},
			},
			renderKind: 'reviewDiff',
			...(props.sourceCorrelations === undefined
				? {}
				: { sourceCorrelations: props.sourceCorrelations }),
			window: { endLine: 2, startLine: 1, totalLineCount: 2 },
		}),
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId: props.itemId,
			...(props.operationCorrelationId === undefined
				? {}
				: { operationCorrelationId: props.operationCorrelationId }),
			publicationSequence: props.publicationSequence,
			surface: 'review',
			workerDerivationEpoch: 7,
		}),
		surface: 'review',
		workerDerivationEpoch: 7,
	});
}

export function makeFilePublication(
	props: MakePublicationProps,
): BridgeWorkerFilePierreRenderJobEvent {
	const contentCacheKey = `file-cache-${props.publicationSequence}`;
	return bridgeWorkerFilePierreRenderJobEventSchema.parse({
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'filePierreRenderJob',
		job: buildBridgeWorkerPierreRenderJob({
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 4096, maxWindowLines: 20 },
			contentCacheKey,
			contentHash: `file-hash-${props.publicationSequence}`,
			itemId: props.itemId,
			language: 'typescript',
			payload: {
				kind: 'codeViewFileItem',
				item: {
					bridgeMetadata: {
						cacheKey: contentCacheKey,
						contentRoles: ['file'],
						contentState: 'hydrated',
						displayPath: `Sources/${props.itemId}.ts`,
						itemId: props.itemId,
						lineCount: 1,
					},
					file: {
						cacheKey: contentCacheKey,
						contents: `export const fileRevision = ${props.publicationSequence};\n`,
						lang: 'typescript',
						name: `Sources/${props.itemId}.ts`,
					},
					id: props.itemId,
					type: 'file',
					version: props.publicationSequence,
				},
			},
			renderKind: 'fileText',
			...(props.sourceCorrelations === undefined
				? {}
				: { sourceCorrelations: props.sourceCorrelations }),
			window: { endLine: 1, startLine: 1, totalLineCount: 1 },
		}),
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId: props.itemId,
			...(props.operationCorrelationId === undefined
				? {}
				: { operationCorrelationId: props.operationCorrelationId }),
			publicationSequence: props.publicationSequence,
			surface: 'file',
			workerDerivationEpoch: 11,
		}),
		surface: 'file',
		workerDerivationEpoch: 11,
	});
}

export function cloneReviewPublicationForRetry(
	publication: BridgeWorkerReviewPierreRenderJobEvent,
): BridgeWorkerReviewPierreRenderJobEvent {
	const publicationItem = publication.job.payload.item;
	const clonedPublicationItem = cloneReviewPublicationItem(publicationItem);
	return bridgeWorkerReviewPierreRenderJobEventSchema.parse({
		...publication,
		job: {
			...publication.job,
			payload: {
				...publication.job.payload,
				item: clonedPublicationItem,
			},
		},
		renderReceiptIdentity: {
			...publication.renderReceiptIdentity,
			attemptId: 'attempt-reused-painted-retry',
		},
	});
}

export function cloneReviewPublicationItem(
	publicationItem: BridgeWorkerReviewPierreRenderJobEvent['job']['payload']['item'],
): BridgeWorkerReviewPierreRenderJobEvent['job']['payload']['item'] {
	if (publicationItem.type !== 'diff') {
		throw new Error('Review publication fixture requires a diff item.');
	}
	return {
		...publicationItem,
		bridgeMetadata: {
			...publicationItem.bridgeMetadata,
			contentRoles: [...publicationItem.bridgeMetadata.contentRoles],
		},
		fileDiff: {
			...publicationItem.fileDiff,
			additionLines: [...publicationItem.fileDiff.additionLines],
			deletionLines: [...publicationItem.fileDiff.deletionLines],
			hunks: [...publicationItem.fileDiff.hunks],
		},
	};
}

export function testRenderedElement(
	isConnected: boolean,
	attributes: Map<string, string> = new Map(),
): BridgeMainRenderedItemReadback['element'] {
	return {
		isConnected,
		getAttribute: (qualifiedName): string | null => attributes.get(qualifiedName) ?? null,
		removeAttribute: (qualifiedName): void => {
			attributes.delete(qualifiedName);
		},
		setAttribute: (qualifiedName, value): void => {
			attributes.set(qualifiedName, value);
		},
	};
}
