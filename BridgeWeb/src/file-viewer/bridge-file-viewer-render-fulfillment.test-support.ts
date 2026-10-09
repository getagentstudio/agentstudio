import type { BridgeWorkerFilePierreRenderJobEvent } from '../core/comm-worker/bridge-worker-contracts.js';
import {
	buildBridgeWorkerPierreRenderJob,
	type BridgeWorkerRenderSourceCorrelation,
} from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import { makeBridgeWorkerRenderReceiptIdentity } from '../core/comm-worker/bridge-worker-render-fulfillment.test-support.js';

export function makeFilePublication(props: {
	readonly contentsMarker: string;
	readonly path?: string;
	readonly publicationSequence: number;
	readonly version: number;
}): BridgeWorkerFilePierreRenderJobEvent {
	const itemId = 'file-1';
	const cacheKey = `cache-${props.contentsMarker}`;
	const sourceCorrelation = {
		descriptorId: `descriptor-${props.contentsMarker}`,
		itemId,
		observedSha256: 'd'.repeat(64),
		position: 'whole',
		requestId: `request-${props.contentsMarker}`,
		role: 'file',
		sourceGeneration: props.publicationSequence,
		sourceIdentity: `source-${props.contentsMarker}`,
	} satisfies BridgeWorkerRenderSourceCorrelation;
	const job = buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank: { lane: 'selected', priority: props.publicationSequence },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		contentCacheKey: cacheKey,
		contentHash: `sha256:${props.contentsMarker}`,
		itemId,
		language: 'swift',
		payload: {
			item: {
				bridgeMetadata: {
					cacheKey,
					contentRoles: ['file'],
					contentState: 'hydrated',
					displayPath: props.path ?? 'Sources/App/View.swift',
					itemId,
					lineCount: 1,
				},
				file: {
					cacheKey,
					contents: `let value = "${props.contentsMarker}"\n`,
					lang: 'swift',
					name: props.path ?? 'Sources/App/View.swift',
				},
				id: `file:${itemId}`,
				type: 'file',
				version: props.version,
			},
			kind: 'codeViewFileItem',
		},
		renderKind: 'fileText',
		sourceCorrelations: [sourceCorrelation],
		window: { endLine: 1, startLine: 1, totalLineCount: 1 },
	});
	return {
		direction: 'serverWorkerToMain',
		job,
		kind: 'filePierreRenderJob',
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId,
			publicationSequence: props.publicationSequence,
			surface: 'file',
			workerDerivationEpoch: 1,
		}),
		surface: 'file',
		transferDescriptors: [
			{
				byteLength: job.payloadByteLength,
				fieldPath: ['job', 'payload'],
				messageKind: 'filePierreRenderJob',
				mode: 'clone',
			},
		],
		wireVersion: 1,
		workerDerivationEpoch: 1,
	};
}
