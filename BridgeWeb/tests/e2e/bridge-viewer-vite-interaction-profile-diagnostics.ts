import type { Page, Response } from 'playwright';

import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import type { BridgeWorkerHealthEvent } from '../../src/core/comm-worker/bridge-worker-contracts.js';
import { annotationProjectionQueryResultDiagnostic } from './bridge-viewer-vite-annotation-projection-test-support.ts';

type MetadataHealthDiagnostic = NonNullable<BridgeWorkerHealthEvent['diagnostic']>;

declare global {
	interface Window {
		bridgeInteractionMetadataHealthHistory?: MetadataHealthDiagnostic[];
	}
}

interface ControlRejectionObservation {
	readonly code: string;
	readonly nextExpectedRequestSequence: number | null;
	readonly requestKind: string;
	readonly requestMethod: string | null;
	readonly requestSequence: number;
	readonly retryable: boolean;
	readonly safeMessage: string | null;
}

interface ResyncObservation {
	readonly atEpochMilliseconds: number;
	readonly claimedSubscriptionIds: readonly string[];
	readonly operationId: string;
	readonly reconciliation: readonly {
		readonly disposition: string;
		readonly reason: string | null;
		readonly subscriptionId: string;
		readonly subscriptionKind: string;
	}[];
	readonly requestSequence: number;
	readonly responseKind: string;
}

interface ResnapshotObservation {
	readonly atEpochMilliseconds: number;
	readonly code: string | null;
	readonly requestSequence: number;
	readonly responseKind: string;
	readonly subscriptionId: string;
	readonly subscriptionKind: string;
}

interface AnnotationQueryObservation {
	readonly method: string;
	readonly operationCorrelationId: string;
	readonly requestSequence: number;
	readonly sourceGeneration: number;
	readonly workerDerivationEpoch: number | null;
	readonly result: unknown;
}

export async function observeInteractionProfileFailures(page: Page): Promise<{
	readonly read: () => Promise<{
		readonly annotationQueries: readonly AnnotationQueryObservation[];
		readonly controlRejections: readonly ControlRejectionObservation[];
		readonly metadataHealthHistory: readonly MetadataHealthDiagnostic[];
		readonly resyncs: readonly ResyncObservation[];
		readonly resnapshots: readonly ResnapshotObservation[];
		readonly pendingControlResponseCount: number;
		readonly unreadableControlResponseCount: number;
	}>;
}> {
	const annotationQueries: AnnotationQueryObservation[] = [];
	const controlRejections: ControlRejectionObservation[] = [];
	const resyncs: ResyncObservation[] = [];
	const resnapshots: ResnapshotObservation[] = [];
	const pendingResyncByOperationId = new Map<
		string,
		{ readonly claimedSubscriptionIds: readonly string[]; readonly requestSequence: number }
	>();
	const pendingReads = new Set<Promise<void>>();
	let unreadableControlResponseCount = 0;
	await page.addInitScript((): void => {
		let latest: MetadataHealthDiagnostic | undefined;
		const history: MetadataHealthDiagnostic[] = [];
		window.bridgeInteractionMetadataHealthHistory = history;
		// Observe the existing diagnostic publication without changing its value or owner.
		Object.defineProperty(window, '__bridgeProductMetadataStreamDiagnostic', {
			configurable: true,
			get: (): MetadataHealthDiagnostic | undefined => latest,
			set: (diagnostic: MetadataHealthDiagnostic): void => {
				latest = diagnostic;
				history.push(diagnostic);
				if (history.length > 32) history.shift();
			},
		});
	});
	const inspectResponse = async (response: Response): Promise<void> => {
		try {
			const requestBody: unknown = response.request().postDataJSON();
			const responseBody: unknown = await response.json();
			const resultRequest = bridgeProductOperationResultRequestSchema.safeParse(requestBody);
			if (resultRequest.success) {
				const pendingResync = pendingResyncByOperationId.get(resultRequest.data.operationId);
				if (pendingResync === undefined) return;
				const result = bridgeProductOperationResultResponseSchema.safeParse(responseBody);
				if (!result.success) return;
				const reconciliation = bridgeProductControlResponseSchema.safeParse(result.data.result);
				resyncs.push({
					atEpochMilliseconds: Date.now(),
					claimedSubscriptionIds: pendingResync.claimedSubscriptionIds,
					operationId: resultRequest.data.operationId,
					reconciliation:
						reconciliation.success && reconciliation.data.kind === 'resync.accepted'
							? reconciliation.data.reconciliation.map((outcome) => ({
									disposition: outcome.disposition,
									reason: 'reason' in outcome ? outcome.reason : null,
									subscriptionId: outcome.subscriptionId,
									subscriptionKind: outcome.subscriptionKind,
								}))
							: [],
					requestSequence: pendingResync.requestSequence,
					responseKind: reconciliation.success ? reconciliation.data.kind : result.data.outcome,
				});
				if (resyncs.length > 32) resyncs.shift();
				pendingResyncByOperationId.delete(resultRequest.data.operationId);
				return;
			}
			const request = bridgeProductControlRequestSchema.parse(requestBody);
			if (request.kind === 'workerSession.resync') {
				const admission = bridgeProductAdmissionResponseSchema.safeParse(responseBody);
				if (admission.success && admission.data.kind === 'operation.admitted') {
					pendingResyncByOperationId.set(admission.data.operationId, {
						claimedSubscriptionIds: request.activeSubscriptions.map(
							(active) => active.subscriptionId,
						),
						requestSequence: request.requestSequence,
					});
				}
			}
			const parsed = bridgeProductControlResponseSchema.safeParse(responseBody);
			if (!parsed.success) return;
			if (request.kind === 'subscription.resnapshot') {
				resnapshots.push({
					atEpochMilliseconds: Date.now(),
					code: parsed.data.kind === 'request.error' ? parsed.data.code : null,
					requestSequence: request.requestSequence,
					responseKind: parsed.data.kind,
					subscriptionId: request.subscriptionId,
					subscriptionKind: request.subscriptionKind,
				});
				if (resnapshots.length > 32) resnapshots.shift();
			}
			if (
				request.kind === 'product.call' &&
				(request.call.method === 'file.annotations.projection.query' ||
					request.call.method === 'review.annotations.projection.query')
			) {
				annotationQueries.push({
					method: request.call.method,
					operationCorrelationId: request.call.request.operationCorrelationId,
					requestSequence: request.requestSequence,
					sourceGeneration: request.call.request.sourceGeneration,
					workerDerivationEpoch: request.workerDerivationEpoch ?? null,
					result: annotationProjectionQueryResultDiagnostic(parsed.data, request.call.request),
				});
				if (annotationQueries.length > 64) annotationQueries.shift();
			}
			if (parsed.data.kind !== 'request.error') return;
			if (controlRejections.length >= 32) return;
			controlRejections.push({
				code: parsed.data.code,
				nextExpectedRequestSequence: parsed.data.nextExpectedRequestSequence ?? null,
				requestKind: request.kind,
				requestMethod: request.kind === 'product.call' ? request.call.method : null,
				requestSequence: request.requestSequence,
				retryable: parsed.data.retryable,
				safeMessage: parsed.data.safeMessage ?? null,
			});
		} catch {
			unreadableControlResponseCount += 1;
		}
	};
	page.on('response', (response): void => {
		if (
			response.status() !== 200 ||
			new URL(response.url()).pathname !== '/__bridge-product/command'
		)
			return;
		const pending = inspectResponse(response);
		pendingReads.add(pending);
		void pending.finally((): void => {
			pendingReads.delete(pending);
		});
	});
	return {
		read: async () => {
			return {
				annotationQueries: [...annotationQueries],
				controlRejections: [...controlRejections],
				metadataHealthHistory: await page.evaluate(
					() => window.bridgeInteractionMetadataHealthHistory ?? [],
				),
				resyncs: [...resyncs],
				resnapshots: [...resnapshots],
				unreadableControlResponseCount,
				pendingControlResponseCount: pendingReads.size,
			};
		},
	};
}
