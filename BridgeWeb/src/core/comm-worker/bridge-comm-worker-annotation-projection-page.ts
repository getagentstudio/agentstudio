import type {
	BridgeCommWorkerAnnotationProjectionTransport,
	BridgeCommWorkerAnnotationSurface,
} from './bridge-comm-worker-annotation-projection-query-controller.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';
import type {
	BridgeProductAnnotationProjectionContentDescriptor,
	BridgeProductAnnotationProjectionPageContract,
} from './bridge-product-worktree-annotation-projection-query-contracts.js';

export async function openAnnotationProjectionPage(props: {
	readonly descriptor: BridgeProductAnnotationProjectionContentDescriptor;
	readonly openContent: BridgeCommWorkerAnnotationProjectionTransport['openContent'];
	readonly signal: AbortSignal;
}): Promise<Uint8Array<ArrayBuffer>> {
	const contentStream: BridgeProductContentStream<'annotation.projection'> = props.openContent(
		props.descriptor,
		props.signal,
	);
	const drain = (async (): Promise<void> => {
		for await (const frame of contentStream.frames) void frame;
	})();
	const [, terminal] = await Promise.all([drain, contentStream.terminal]);
	if (terminal.kind !== 'complete') {
		throw new Error('Annotation projection content did not complete.');
	}
	if (
		terminal.descriptorId !== props.descriptor.descriptorId ||
		terminal.observedByteLength !== props.descriptor.maximumBytes ||
		terminal.bytes.byteLength !== props.descriptor.maximumBytes ||
		!terminal.endOfSource
	) {
		throw new Error('Annotation projection content terminal does not match its descriptor.');
	}
	return new Uint8Array(terminal.bytes);
}

export function validatePageContract(props: {
	readonly descriptor: BridgeProductAnnotationProjectionContentDescriptor;
	readonly expectedPage: BridgeProductAnnotationProjectionPageContract | null;
	readonly previousPageOrdinal: number | null;
	readonly requestedCursor: string | null;
	readonly requestedOperationCorrelationId: string;
	readonly requestedSourceGeneration: number;
	readonly requestedSurface: BridgeCommWorkerAnnotationSurface;
}): void {
	const expectedOrdinal = props.previousPageOrdinal === null ? 0 : props.previousPageOrdinal + 1;
	if (
		props.descriptor.surface !== props.requestedSurface ||
		props.descriptor.page.operationCorrelationId !== props.requestedOperationCorrelationId ||
		props.descriptor.page.sourceGeneration !== props.requestedSourceGeneration ||
		props.descriptor.page.pageOrdinal !== expectedOrdinal ||
		(props.requestedCursor === null) !== (props.descriptor.page.pageOrdinal === 0)
	) {
		throw new Error('Annotation projection page does not match its query authority or order.');
	}
	if (props.expectedPage === null) return;
	for (const field of [
		'aggregateSha256',
		'expectedMessageCount',
		'expectedPageCount',
		'expectedSessionCount',
		'expectedThreadCount',
		'operationCorrelationId',
		'projectionRevision',
		'snapshotId',
		'sourceGeneration',
	] as const) {
		if (props.descriptor.page[field] !== props.expectedPage[field]) {
			throw new Error(`Annotation projection page changed ${field} within one snapshot.`);
		}
	}
}
