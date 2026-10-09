import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	bridgeProductFileContentDescriptorSchema,
	type BridgeProductFileContentDescriptor,
} from './bridge-product-content-contracts.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';

export type BridgeWorkerFileViewContentOpen = (
	descriptor: BridgeProductFileContentDescriptor,
	abortSignal: AbortSignal,
	operationCorrelationId: string,
) => BridgeProductContentStream<'file.content'>;

export interface FetchBridgeWorkerFileViewContentResourceProps {
	readonly contentRequest: BridgeCommWorkerFileViewContentRequest;
	readonly isBinary?: boolean;
	readonly openContent: BridgeWorkerFileViewContentOpen;
	readonly operationCorrelationId: string;
	readonly signal?: AbortSignal;
}

export interface BridgeWorkerFetchedFileViewContentResource {
	readonly byteLength: number;
	readonly contentHash: string;
	readonly contentHashAlgorithm: 'sha256';
	readonly descriptorId: string;
	readonly itemId: string;
	readonly language: string | null;
	readonly maxBytes: number;
	readonly path: string;
	readonly requestId: string;
	readonly resourceKind: 'file.content';
	readonly sizeBytes: number;
	readonly sourceGeneration: number;
	readonly sourceIdentity: string;
	readonly sourcePosition: string;
	readonly text: string;
	readonly textBytes: ArrayBuffer;
}

export async function fetchBridgeWorkerFileViewContentResource(
	props: FetchBridgeWorkerFileViewContentResourceProps,
): Promise<BridgeWorkerFetchedFileViewContentResource> {
	if (props.isBinary === true) {
		throw new Error('Bridge worker File View content fetch cannot load binary descriptors.');
	}
	const descriptor = bridgeProductFileContentDescriptorSchema.parse(
		props.contentRequest.contentDescriptor,
	);
	const abortSignal = props.signal ?? new AbortController().signal;
	const contentStream = props.openContent(descriptor, abortSignal, props.operationCorrelationId);
	const [, terminal] = await Promise.all([
		drainBridgeProductContentFrames(contentStream),
		contentStream.terminal,
	]);
	if (terminal.kind === 'error') {
		throw new Error(
			terminal.safeMessage ?? `Bridge worker File View content failed: ${terminal.code}.`,
		);
	}
	if (terminal.kind === 'reset') {
		throw new Error(`Bridge worker File View content reset: ${terminal.reason}.`);
	}
	if (terminal.descriptorId !== descriptor.descriptorId) {
		throw new Error('Bridge worker File View content terminal descriptor does not match demand.');
	}
	const text = new TextDecoder('utf-8', { fatal: true }).decode(terminal.bytes);
	return {
		byteLength: terminal.bytes.byteLength,
		contentHash: terminal.observedSha256,
		contentHashAlgorithm: 'sha256',
		descriptorId: descriptor.descriptorId,
		itemId: props.contentRequest.itemId,
		language: props.contentRequest.language,
		maxBytes: descriptor.maximumBytes,
		path: props.contentRequest.path,
		requestId: contentStream.contentRequestId,
		resourceKind: 'file.content',
		sizeBytes: props.contentRequest.sizeBytes,
		sourceGeneration: descriptor.source.subscriptionGeneration,
		sourceIdentity: descriptor.source.sourceId,
		sourcePosition: terminal.endOfSource ? 'whole' : 'prefix:0',
		text,
		textBytes: terminal.bytes,
	};
}

async function drainBridgeProductContentFrames(
	contentStream: BridgeProductContentStream<'file.content'>,
): Promise<void> {
	for await (const frame of contentStream.frames) {
		// The shared transport validates and assembles ordered content into its terminal result.
		void frame;
	}
}
