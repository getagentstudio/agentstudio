import type { BridgeBodyRegistry } from '../demand/bridge-body-registry.js';
import { BridgeProductContentProducerCapacityDeferred } from './bridge-product-content-response-reader.js';
import type {
	BridgeProductContentTerminal,
	BridgeProductContentResponseStartControl,
	BridgeProductContentStream,
} from './bridge-product-transport-contract.js';
import type { BridgeWorkerReviewContentRequestDescriptor } from './bridge-worker-contracts.js';
import { bridgeWorkerReviewContentRequestDescriptorSchema } from './bridge-worker-contracts.js';

export type BridgeWorkerReviewContentOpen = (
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
	abortSignal: AbortSignal,
) => BridgeProductContentStream<'review.content'>;

export interface BridgeWorkerReviewContentResourceFetch {
	(
		descriptor: BridgeWorkerReviewContentRequestDescriptor,
		signal?: AbortSignal,
		registerResponseStartControl?: (
			control: BridgeProductContentResponseStartControl,
		) => () => void,
	): Promise<BridgeWorkerReviewContentResourceFetchResult>;
}

export interface FetchBridgeWorkerReviewContentResourceProps {
	readonly beforeOpenContent?: () => Promise<void>;
	readonly descriptor: BridgeWorkerReviewContentRequestDescriptor;
	readonly openContent: BridgeWorkerReviewContentOpen;
	readonly registerResponseStartControl?: (
		control: BridgeProductContentResponseStartControl,
	) => () => void;
	readonly signal?: AbortSignal;
}

export interface BridgeWorkerFetchedReviewContentResource {
	readonly itemId: string;
	readonly role: BridgeWorkerReviewContentRequestDescriptor['role'];
	readonly contentHash: string;
	readonly contentHashAlgorithm: string;
	readonly descriptorId: string;
	readonly language: string | null;
	readonly byteLength: number;
	readonly observedSha256: string;
	readonly requestId: string;
	readonly sourceGeneration: number;
	readonly sourceIdentity: string;
	readonly sourcePosition: string;
	readonly text: string;
	readonly textBytes: ArrayBuffer;
}

export type BridgeWorkerResidentReviewContentBody = Pick<
	BridgeWorkerFetchedReviewContentResource,
	'byteLength' | 'observedSha256' | 'sourcePosition' | 'text' | 'textBytes'
>;

type BridgeWorkerReviewContentCompleteTerminal = Extract<
	BridgeProductContentTerminal<'review.content'>,
	{ readonly kind: 'complete' }
>;
type BridgeWorkerReviewContentErrorTerminal = Extract<
	BridgeProductContentTerminal<'review.content'>,
	{ readonly kind: 'error' }
>;
type BridgeWorkerReviewContentResetTerminal = Extract<
	BridgeProductContentTerminal<'review.content'>,
	{ readonly kind: 'reset' }
>;

export interface BridgeWorkerReviewContentLocalFailure {
	readonly code:
		| 'aborted'
		| 'descriptor_invalid'
		| 'internal_failure'
		| 'terminal_descriptor_mismatch'
		| 'utf8_invalid';
	readonly descriptorId: string;
	readonly kind: 'abort' | 'internal' | 'validation';
	readonly safeMessage: string;
}

export type BridgeWorkerReviewContentResourceFetchResult =
	| (BridgeWorkerFetchedReviewContentResource & {
			readonly contentRequestId: string;
			readonly disposition: 'ready';
			readonly terminal: BridgeWorkerReviewContentCompleteTerminal;
	  })
	| {
			readonly contentRequestId: string;
			readonly disposition: 'retryWait';
			readonly terminal:
				| BridgeWorkerReviewContentErrorTerminal
				| BridgeWorkerReviewContentResetTerminal;
	  }
	| {
			readonly contentRequestId: string;
			readonly disposition: 'terminal';
			readonly terminal: BridgeWorkerReviewContentErrorTerminal;
	  }
	| {
			readonly disposition: 'discarded' | 'terminal';
			readonly localFailure: BridgeWorkerReviewContentLocalFailure;
	  };

export function createSharedBridgeWorkerReviewContentResourceFetch(props: {
	readonly beforeOpenContent?: () => Promise<void>;
	readonly bodyRegistry?: BridgeBodyRegistry<BridgeWorkerResidentReviewContentBody>;
	readonly openContent: BridgeWorkerReviewContentOpen | undefined;
	readonly resolveBodyRegistry?: () =>
		| BridgeBodyRegistry<BridgeWorkerResidentReviewContentBody>
		| undefined;
}): BridgeWorkerReviewContentResourceFetch {
	interface InFlightReviewContentResource {
		readonly promise: ReturnType<BridgeWorkerReviewContentResourceFetch>;
		readonly sourceSignal: AbortSignal | undefined;
	}
	const inFlightResourcesByIdentity = new Map<string, InFlightReviewContentResource>();
	return async (
		descriptor: BridgeWorkerReviewContentRequestDescriptor,
		signal?: AbortSignal,
		registerResponseStartControl?: (
			control: BridgeProductContentResponseStartControl,
		) => () => void,
	) => {
		if (signal?.aborted === true) {
			return abortedBridgeWorkerReviewContentFetchResult(descriptor);
		}
		const bodyRegistry = props.bodyRegistry ?? props.resolveBodyRegistry?.();
		const residentCacheKey = residentBridgeWorkerReviewContentResourceCacheKey(descriptor);
		const residentFreshnessKey = residentBridgeWorkerReviewContentResourceFreshnessKey(descriptor);
		const residentResource = bodyRegistry?.get({
			cacheKey: residentCacheKey,
			freshnessKey: residentFreshnessKey,
		});
		if (residentResource !== null && residentResource !== undefined) {
			const resource = fetchedBridgeWorkerReviewContentResourceFromResidentBody({
				body: residentResource,
				descriptor,
			});
			return {
				...resource,
				contentRequestId: resource.requestId,
				disposition: 'ready',
				terminal: {
					bytes: resource.textBytes,
					contentKind: 'review.content',
					descriptorId: descriptor.descriptorId,
					endOfSource: resource.sourcePosition === 'whole',
					kind: 'complete',
					observedByteLength: resource.byteLength,
					observedSha256: resource.observedSha256,
				},
			};
		}
		const resourceKey = sharedBridgeWorkerReviewContentResourceKey(descriptor);
		const existingResource = inFlightResourcesByIdentity.get(resourceKey);
		if (existingResource !== undefined && existingResource.sourceSignal?.aborted !== true) {
			return await existingResource.promise;
		}
		if (existingResource !== undefined) {
			inFlightResourcesByIdentity.delete(resourceKey);
		}
		if (props.openContent === undefined) {
			return internalBridgeWorkerReviewContentFetchResult(descriptor);
		}
		const resourcePromise = fetchBridgeWorkerReviewContentResource({
			...(props.beforeOpenContent === undefined
				? {}
				: { beforeOpenContent: props.beforeOpenContent }),
			descriptor,
			openContent: props.openContent,
			...(registerResponseStartControl === undefined ? {} : { registerResponseStartControl }),
			...(signal === undefined ? {} : { signal }),
		});
		const resourceEntry: InFlightReviewContentResource = {
			promise: resourcePromise,
			sourceSignal: signal,
		};
		const evictAbortedResource = (): void => {
			if (inFlightResourcesByIdentity.get(resourceKey) === resourceEntry) {
				inFlightResourcesByIdentity.delete(resourceKey);
			}
		};
		signal?.addEventListener('abort', evictAbortedResource, { once: true });
		inFlightResourcesByIdentity.set(resourceKey, resourceEntry);
		try {
			const result = await resourcePromise;
			if (isAbortSignalAborted(signal)) {
				return abortedBridgeWorkerReviewContentFetchResult(descriptor);
			}
			if (result.disposition !== 'ready') {
				return result;
			}
			bodyRegistry?.evictStale({
				cacheKey: residentCacheKey,
				keepFreshnessKey: residentFreshnessKey,
			});
			bodyRegistry?.put({
				body: {
					byteLength: result.byteLength,
					observedSha256: result.observedSha256,
					sourcePosition: result.sourcePosition,
					text: result.text,
					textBytes: result.textBytes,
				},
				byteLength: result.byteLength,
				cacheKey: residentCacheKey,
				freshnessKey: residentFreshnessKey,
			});
			return result;
		} finally {
			signal?.removeEventListener('abort', evictAbortedResource);
			evictAbortedResource();
		}
	};
}

function fetchedBridgeWorkerReviewContentResourceFromResidentBody(props: {
	readonly body: BridgeWorkerResidentReviewContentBody;
	readonly descriptor: BridgeWorkerReviewContentRequestDescriptor;
}): BridgeWorkerFetchedReviewContentResource {
	return {
		...props.body,
		contentHash: props.descriptor.contentDigest.value,
		contentHashAlgorithm: props.descriptor.contentDigest.algorithm,
		descriptorId: props.descriptor.descriptorId,
		itemId: props.descriptor.itemId,
		language: props.descriptor.language,
		requestId: `resident-${props.descriptor.descriptorId}`,
		role: props.descriptor.role,
		sourceGeneration: props.descriptor.reviewGeneration,
		sourceIdentity: props.descriptor.sourceIdentity,
	};
}

export async function fetchBridgeWorkerReviewContentResource(
	props: FetchBridgeWorkerReviewContentResourceProps,
): Promise<BridgeWorkerReviewContentResourceFetchResult> {
	const descriptorResult = bridgeWorkerReviewContentRequestDescriptorSchema.safeParse(
		props.descriptor,
	);
	if (!descriptorResult.success) {
		return validationBridgeWorkerReviewContentFetchResult({
			code: 'descriptor_invalid',
			descriptorId: props.descriptor.descriptorId,
			safeMessage: 'Bridge worker Review content descriptor is invalid.',
		});
	}
	const descriptor = descriptorResult.data;
	const abortSignal = props.signal ?? new AbortController().signal;
	if (abortSignal.aborted) {
		return abortedBridgeWorkerReviewContentFetchResult(descriptor);
	}
	let contentStream: BridgeProductContentStream<'review.content'>;
	try {
		if (props.beforeOpenContent !== undefined) {
			await props.beforeOpenContent();
		}
		if (abortSignal.aborted) {
			return abortedBridgeWorkerReviewContentFetchResult(descriptor);
		}
		contentStream = props.openContent(descriptor, abortSignal);
	} catch {
		return internalBridgeWorkerReviewContentFetchResult(descriptor);
	}
	const unregisterResponseStartControl =
		contentStream.responseStartControl === undefined
			? undefined
			: props.registerResponseStartControl?.(contentStream.responseStartControl);
	try {
		const [, terminal] = await Promise.all([
			drainBridgeProductReviewContentFrames(contentStream),
			contentStream.terminal,
		]);
		if (abortSignal.aborted) {
			return abortedBridgeWorkerReviewContentFetchResult(descriptor);
		}
		if (terminal.kind === 'error') {
			return terminal.retryable
				? {
						contentRequestId: contentStream.contentRequestId,
						disposition: 'retryWait',
						terminal,
					}
				: {
						contentRequestId: contentStream.contentRequestId,
						disposition: 'terminal',
						terminal,
					};
		}
		if (terminal.kind === 'reset') {
			return {
				contentRequestId: contentStream.contentRequestId,
				disposition: 'retryWait',
				terminal,
			};
		}
		if (terminal.descriptorId !== descriptor.descriptorId) {
			return validationBridgeWorkerReviewContentFetchResult({
				code: 'terminal_descriptor_mismatch',
				descriptorId: descriptor.descriptorId,
				safeMessage: 'Bridge worker Review content terminal descriptor is invalid.',
			});
		}
		let text: string;
		try {
			text = new TextDecoder('utf-8', { fatal: true }).decode(terminal.bytes);
		} catch {
			return validationBridgeWorkerReviewContentFetchResult({
				code: 'utf8_invalid',
				descriptorId: descriptor.descriptorId,
				safeMessage: 'Bridge worker Review content is not valid UTF-8.',
			});
		}
		return {
			contentRequestId: contentStream.contentRequestId,
			itemId: descriptor.itemId,
			role: descriptor.role,
			contentHash: descriptor.contentDigest.value,
			contentHashAlgorithm: descriptor.contentDigest.algorithm,
			descriptorId: descriptor.descriptorId,
			disposition: 'ready',
			language: descriptor.language,
			byteLength: terminal.bytes.byteLength,
			observedSha256: terminal.observedSha256,
			requestId: contentStream.contentRequestId,
			sourceGeneration: descriptor.reviewGeneration,
			sourceIdentity: descriptor.sourceIdentity,
			sourcePosition:
				terminal.endOfSource && descriptor.window.startByte === 0
					? 'whole'
					: `byteRange:${descriptor.window.startByte}:${terminal.bytes.byteLength}`,
			text,
			textBytes: terminal.bytes,
			terminal,
		};
	} catch (error) {
		if (abortSignal.aborted) {
			return abortedBridgeWorkerReviewContentFetchResult(descriptor);
		}
		if (error instanceof BridgeProductContentProducerCapacityDeferred) {
			return {
				contentRequestId: contentStream.contentRequestId,
				disposition: 'retryWait',
				terminal: {
					code: 'internal',
					contentKind: 'review.content',
					descriptorId: descriptor.descriptorId,
					kind: 'error',
					retryable: true,
					safeMessage: error.message,
				},
			};
		}
		return internalBridgeWorkerReviewContentFetchResult(descriptor);
	} finally {
		unregisterResponseStartControl?.();
	}
}

export function internalBridgeWorkerReviewContentFetchResult(
	descriptor: Pick<BridgeWorkerReviewContentRequestDescriptor, 'descriptorId'>,
): BridgeWorkerReviewContentResourceFetchResult {
	return {
		disposition: 'terminal',
		localFailure: {
			code: 'internal_failure',
			descriptorId: descriptor.descriptorId,
			kind: 'internal',
			safeMessage: 'Bridge worker Review content failed internally.',
		},
	};
}

function abortedBridgeWorkerReviewContentFetchResult(
	descriptor: Pick<BridgeWorkerReviewContentRequestDescriptor, 'descriptorId'>,
): BridgeWorkerReviewContentResourceFetchResult {
	return {
		disposition: 'discarded',
		localFailure: {
			code: 'aborted',
			descriptorId: descriptor.descriptorId,
			kind: 'abort',
			safeMessage: 'Bridge worker Review content fetch was aborted.',
		},
	};
}

function validationBridgeWorkerReviewContentFetchResult(props: {
	readonly code: Extract<
		BridgeWorkerReviewContentLocalFailure['code'],
		'descriptor_invalid' | 'terminal_descriptor_mismatch' | 'utf8_invalid'
	>;
	readonly descriptorId: string;
	readonly safeMessage: string;
}): BridgeWorkerReviewContentResourceFetchResult {
	return {
		disposition: 'terminal',
		localFailure: {
			...props,
			kind: 'validation',
		},
	};
}

function isAbortSignalAborted(signal: AbortSignal | undefined): boolean {
	return signal?.aborted === true;
}

async function drainBridgeProductReviewContentFrames(
	contentStream: BridgeProductContentStream<'review.content'>,
): Promise<void> {
	for await (const frame of contentStream.frames) {
		// The shared transport validates and assembles ordered content into its terminal result.
		void frame;
	}
}

function sharedBridgeWorkerReviewContentResourceKey(
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
): string {
	return [
		residentBridgeWorkerReviewContentResourceCacheKey(descriptor),
		residentBridgeWorkerReviewContentResourceFreshnessKey(descriptor),
		descriptor.descriptorId,
		descriptor.endpointId,
		descriptor.handleId,
		descriptor.expectedSha256 ?? '',
		descriptor.language ?? '',
		descriptor.maximumBytes,
		descriptor.mimeType,
	].join('\u0000');
}

function residentBridgeWorkerReviewContentResourceCacheKey(
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
): string {
	return [
		descriptor.packageId,
		descriptor.sourceIdentity,
		descriptor.reviewGeneration,
		descriptor.itemId,
		descriptor.role,
		descriptor.window.kind,
		descriptor.window.startByte,
		descriptor.window.maximumBytes,
	].join('\u0000');
}

function residentBridgeWorkerReviewContentResourceFreshnessKey(
	descriptor: BridgeWorkerReviewContentRequestDescriptor,
): string {
	return [
		descriptor.contentDigest.algorithm,
		descriptor.contentDigest.authority,
		descriptor.contentDigest.value,
		descriptor.declaredByteLength ?? '',
		descriptor.wholeByteLength ?? '',
		descriptor.encoding,
		descriptor.isBinary,
	].join('\u0000');
}
