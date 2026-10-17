import type {
	BridgeProductContentFrameFor,
	BridgeProductContentKind,
	BridgeProductContentRequestFor,
	BridgeProductContentTerminal,
} from './bridge-product-content-contracts.js';
import {
	BridgeProductContentResponseAdmission,
	type BridgeProductContentResponseAdmissionLease,
} from './bridge-product-content-response-admission.js';
import { BridgeProductContentStreamDecoder } from './bridge-product-content-stream-decoder.js';
import type { BridgeProductContentStreamOpening } from './bridge-product-content-stream-opening.js';
import { BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES } from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { awaitBridgeProductFiniteProgress } from './bridge-product-finite-progress-deadline.js';
import { BridgeProductFrameAcknowledgementFailure } from './bridge-product-frame-acknowledgement.js';
import { BridgeProductReadAhead } from './bridge-product-read-ahead.js';
import { encodeBridgeProductRequestBody } from './bridge-product-request-body.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import type { BridgeProductSessionAuthority } from './bridge-product-session-authority.js';

export async function readBridgeProductContentResponse<
	TContentKind extends BridgeProductContentKind,
>(props: {
	readonly acknowledgeReceivedThrough: (
		request: BridgeProductContentRequestFor<TContentKind>,
		receivedThroughContentSequence: number,
	) => Promise<void>;
	readonly authority: BridgeProductSessionAuthority;
	readonly clock: BridgeProductDeadlineClock;
	readonly executeProductRequest: BridgeProductRequestExecutor;
	readonly opening: BridgeProductContentStreamOpening<TContentKind>;
	readonly responseAdmission: BridgeProductContentResponseAdmission;
}): Promise<void> {
	const opening = props.opening;
	let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
	let responseAdmissionLease: BridgeProductContentResponseAdmissionLease | null = null;
	let pendingAcknowledgementSequence: number | null = null;
	const unacknowledgedDataFrames: Array<{ readonly sequence: number; readonly byteCount: number }> =
		[];
	let unacknowledgedDataBytes = 0;
	let acknowledgementDrain: Promise<void> | null = null;
	let acknowledgementFailure: unknown = null;
	let acknowledgementScopeEnded = false;
	let terminalVerified = false;
	// Native reserves a maximum encoded frame before each source read. A data
	// receipt returns credit only when that next reservation would be blocked.
	const maximumReservedFrameBytes = BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES + 4;
	const dataFrameWireOverheadBytes = 4 + 1 + 4 + 4 + 33;
	const readAbortController = new AbortController();
	const beginAcknowledgementDrain = (): void => {
		if (acknowledgementDrain !== null || acknowledgementScopeEnded) return;
		const drain = async (): Promise<void> => {
			while (pendingAcknowledgementSequence !== null && !opening.abortSignal.aborted) {
				if (terminalVerified) return;
				const receivedThroughContentSequence = pendingAcknowledgementSequence;
				pendingAcknowledgementSequence = null;
				for (
					let attempt = 0;
					attempt <= props.authority.bootstrap.policy.admissionRetryCount;
					attempt += 1
				) {
					try {
						// eslint-disable-next-line no-await-in-loop -- Ambiguous replies replay the exact credit before advancing.
						await props.acknowledgeReceivedThrough(opening.request, receivedThroughContentSequence);
						while (true) {
							const oldestDataFrame = unacknowledgedDataFrames[0];
							if (
								oldestDataFrame === undefined ||
								oldestDataFrame.sequence > receivedThroughContentSequence
							)
								break;
							unacknowledgedDataFrames.shift();
							unacknowledgedDataBytes -= oldestDataFrame.byteCount;
						}
						break;
					} catch (error) {
						if (terminalVerified || opening.abortSignal.aborted) return;
						if (
							receivedThroughContentSequence > 0 &&
							error instanceof BridgeProductFrameAcknowledgementFailure &&
							error.failureCode === 'unknown_read'
						) {
							// Native retires credit when its producer ends, before the page
							// necessarily verifies terminal. Body validation and its progress
							// deadline still own completion; ACK0 remains the authority barrier.
							acknowledgementScopeEnded = true;
							pendingAcknowledgementSequence = null;
							unacknowledgedDataFrames.length = 0;
							unacknowledgedDataBytes = 0;
							return;
						}
						if (
							!(error instanceof BridgeProductFrameAcknowledgementFailure) ||
							(error.failureCode !== 'ambiguous_refusal' &&
								error.failureCode !== 'request_failed' &&
								error.failureCode !== 'request_timeout' &&
								!(
									error.failureCode === 'unsupported_status' &&
									error.status !== null &&
									error.status >= 500 &&
									error.status < 600
								)) ||
							attempt === props.authority.bootstrap.policy.admissionRetryCount
						)
							throw error;
					}
				}
			}
		};
		acknowledgementDrain = drain()
			.catch((error: unknown): void => {
				if (terminalVerified || opening.abortSignal.aborted) return;
				acknowledgementFailure = error;
				readAbortController.abort(error);
				void reader?.cancel(error).catch((): void => {});
			})
			.finally((): void => {
				acknowledgementDrain = null;
				if (
					pendingAcknowledgementSequence !== null &&
					acknowledgementFailure === null &&
					!acknowledgementScopeEnded &&
					!terminalVerified &&
					!opening.abortSignal.aborted
				) {
					beginAcknowledgementDrain();
				}
			});
	};
	const acknowledgeReceivedFrame = (frame: BridgeProductContentFrameFor<TContentKind>): void => {
		if (acknowledgementScopeEnded) return;
		if (frame.header.kind === 'content.data') {
			const byteCount = dataFrameWireOverheadBytes + frame.payload.byteLength;
			unacknowledgedDataFrames.push({ sequence: frame.header.contentSequence, byteCount });
			unacknowledgedDataBytes += byteCount;
			if (
				unacknowledgedDataFrames.length < props.authority.bootstrap.policy.viewCreditParts &&
				unacknowledgedDataBytes <=
					props.authority.bootstrap.policy.viewCreditBytes - maximumReservedFrameBytes
			)
				return;
		}
		pendingAcknowledgementSequence = Math.max(
			pendingAcknowledgementSequence ?? 0,
			frame.header.contentSequence,
		);
		beginAcknowledgementDrain();
	};
	const abortResponse = (): void => {
		readAbortController.abort(opening.abortSignal.reason);
		void reader?.cancel(opening.abortSignal.reason).catch((): void => {});
		responseAdmissionLease?.release();
	};
	opening.abortSignal.addEventListener('abort', abortResponse, { once: true });
	try {
		opening.abortSignal.throwIfAborted();
		await props.authority.open;
		opening.abortSignal.throwIfAborted();
		responseAdmissionLease = await opening.responseStartAdmission.acquire(
			props.responseAdmission,
			opening.abortSignal,
		);
		opening.abortSignal.throwIfAborted();
		const response = await awaitBridgeProductFiniteProgress({
			abortRead: (): void => readAbortController.abort(),
			clock: props.clock,
			delayMilliseconds: props.authority.bootstrap.policy.contentProgressDeadlineMilliseconds,
			pending: () =>
				props.executeProductRequest('content', {
					body: encodeBridgeProductRequestBody(opening.request),
					headers: {
						'Content-Type': 'application/json',
						'X-AgentStudio-Bridge-Product-Capability': props.authority.capabilityHeader,
					},
					method: 'POST',
					signal: readAbortController.signal,
				}),
		});
		opening.abortSignal.throwIfAborted();
		if (!response.ok || response.body === null) {
			throw new Error(`Bridge product content stream failed with status ${response.status}.`);
		}
		const responseReader = response.body.getReader();
		const readAhead = new BridgeProductReadAhead(responseReader);
		reader = responseReader;
		const decoder = new BridgeProductContentStreamDecoder(opening.request);
		let terminalResult: BridgeProductContentTerminal<TContentKind> | null = null;
		while (true) {
			// eslint-disable-next-line no-await-in-loop -- Stream chunks are ordered.
			const chunk = await awaitBridgeProductFiniteProgress({
				abortRead: (): void => {
					readAbortController.abort();
					void reader?.cancel().catch((): void => {});
				},
				clock: props.clock,
				delayMilliseconds: props.authority.bootstrap.policy.contentProgressDeadlineMilliseconds,
				pending: () => readAhead.next(),
			});
			if (acknowledgementFailure !== null) throw acknowledgementFailure;
			if (chunk.done) break;
			// eslint-disable-next-line no-await-in-loop -- Decoder digest validation is ordered.
			const decoded = await decoder.push(chunk.value);
			for (const frame of decoded.frames) {
				opening.frames.push(frame);
				if (
					frame.header.kind === 'content.end' ||
					frame.header.kind === 'content.error' ||
					frame.header.kind === 'content.reset'
				) {
					terminalVerified = true;
					pendingAcknowledgementSequence = null;
				} else {
					acknowledgeReceivedFrame(frame);
				}
			}
			terminalResult = decoded.terminal ?? terminalResult;
			if (terminalResult !== null) break;
		}
		decoder.finish();
		if (acknowledgementFailure !== null) throw acknowledgementFailure;
		if (terminalResult === null) {
			throw new Error('Bridge product content stream ended without a terminal result.');
		}
		opening.frames.close(false);
		opening.terminal.resolve(terminalResult);
		if (terminalVerified) await reader.cancel().catch((): void => {});
	} catch (error) {
		if (reader !== null) await reader.cancel(error).catch((): void => {});
		opening.frames.fail(error, true);
		opening.terminal.reject(error);
	} finally {
		opening.abortSignal.removeEventListener('abort', abortResponse);
		reader?.releaseLock();
		responseAdmissionLease?.release();
	}
}
