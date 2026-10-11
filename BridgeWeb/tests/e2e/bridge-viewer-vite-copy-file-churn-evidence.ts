import type { Page, Request, Response } from 'playwright';

import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { bridgeProductWorktreeAnnotationCommandOutcomeSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-contracts.js';

export interface ChurnEvidence {
	readonly annotationOutcomes: Array<{
		readonly operationKind: string;
		readonly status: string;
	}>;
	copyRefreshOverlap: {
		readonly expectedSha256: string;
		readonly interceptedBeforeCopy: boolean;
		readonly paintedBeforeCopy: boolean;
		releasedBy: 'cleanup' | 'output.scope.commit' | null;
		readonly workerDerivationEpoch: number | null;
	} | null;
	readonly fileAnnotationOpens: Array<{
		readonly workerDerivationEpoch: number;
		readonly workerInstanceId: string;
	}>;
	readonly subscriptionRetirements: Array<{
		readonly subscriptionId: string;
		readonly subscriptionKind: string;
		readonly workerDerivationEpoch: number;
	}>;
	fileScopeUpdateCount: number;
	readonly transportRequests: Array<{
		readonly kind: string;
		readonly method: string | null;
		readonly operationKind: string | null;
		readonly subscriptionId: string | null;
		readonly subscriptionKind: string | null;
		readonly workerDerivationEpoch: number | null;
	}>;
}

export interface ChurnEvidenceObserver {
	readonly drain: () => Promise<void>;
	readonly evidence: ChurnEvidence;
}

export function observeChurnEvidence(page: Page): ChurnEvidenceObserver {
	const evidence: ChurnEvidence = {
		annotationOutcomes: [],
		copyRefreshOverlap: null,
		fileAnnotationOpens: [],
		subscriptionRetirements: [],
		fileScopeUpdateCount: 0,
		transportRequests: [],
	};
	const pendingOutcomeReads = new Set<Promise<void>>();
	const operationKindById = new Map<string, string>();
	const resultByOperationId = new Map<string, unknown>();
	const recordedOperationIds = new Set<string>();
	page.on('request', (request): void => recordTransportRequest(evidence, request));
	page.on('response', (response): void => {
		const read = recordAnnotationOutcome({
			evidence,
			operationKindById,
			recordedOperationIds,
			response,
			resultByOperationId,
		}).finally((): void => {
			pendingOutcomeReads.delete(read);
		});
		pendingOutcomeReads.add(read);
	});
	return {
		drain: async (): Promise<void> => {
			await Promise.allSettled(pendingOutcomeReads);
		},
		evidence,
	};
}

function recordTransportRequest(evidence: ChurnEvidence, request: Request): void {
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return;
	const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
	if (!parsed.success) return;
	const control = parsed.data;
	const call = control.kind === 'product.call' ? control.call : null;
	const callRequest: unknown = call?.request;
	const operation = isRecord(callRequest) ? callRequest['operation'] : null;
	if (
		control.kind === 'subscription.open' &&
		control.subscription.subscriptionKind === 'file.annotations'
	) {
		evidence.fileAnnotationOpens.push({
			workerDerivationEpoch: control.workerDerivationEpoch,
			workerInstanceId: control.workerInstanceId,
		});
	}
	if (control.kind === 'subscription.setScope' && control.subscriptionKind === 'file.metadata') {
		evidence.fileScopeUpdateCount += 1;
	}
	if (control.kind === 'subscription.cancel') {
		evidence.subscriptionRetirements.push({
			subscriptionId: control.subscriptionId,
			subscriptionKind: control.subscriptionKind,
			workerDerivationEpoch: control.workerDerivationEpoch,
		});
	}
	evidence.transportRequests.push({
		kind: control.kind,
		method: call?.method ?? null,
		operationKind:
			isRecord(operation) && typeof operation['kind'] === 'string' ? operation['kind'] : null,
		subscriptionId:
			'subscriptionId' in control && typeof control.subscriptionId === 'string'
				? control.subscriptionId
				: null,
		subscriptionKind:
			'subscriptionKind' in control && typeof control.subscriptionKind === 'string'
				? control.subscriptionKind
				: control.kind === 'subscription.open'
					? control.subscription.subscriptionKind
					: null,
		workerDerivationEpoch:
			'workerDerivationEpoch' in control && typeof control.workerDerivationEpoch === 'number'
				? control.workerDerivationEpoch
				: null,
	});
	if (evidence.transportRequests.length > 128) evidence.transportRequests.shift();
}

async function recordAnnotationOutcome(props: {
	readonly evidence: ChurnEvidence;
	readonly operationKindById: Map<string, string>;
	readonly recordedOperationIds: Set<string>;
	readonly response: Response;
	readonly resultByOperationId: Map<string, unknown>;
}): Promise<void> {
	const { evidence, operationKindById, recordedOperationIds, response, resultByOperationId } =
		props;
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return;
	const requestBody: unknown = request.postDataJSON();
	if (!isRecord(requestBody)) return;
	if (requestBody['kind'] === 'product.call') {
		const admission = bridgeProductAdmissionResponseSchema.safeParse(
			await response.json().catch((): null => null),
		);
		if (!admission.success || admission.data.kind !== 'operation.admitted') return;
		const call = requestBody['call'];
		if (
			!isRecord(call) ||
			(call['method'] !== 'file.annotations.command' &&
				call['method'] !== 'review.annotations.command') ||
			!isRecord(call['request'])
		)
			return;
		const operation = call['request']['operation'];
		if (!isRecord(operation) || typeof operation['kind'] !== 'string') return;
		operationKindById.set(admission.data.operationId, operation['kind']);
		const priorResult = resultByOperationId.get(admission.data.operationId);
		if (priorResult !== undefined) {
			recordSettledAnnotationOutcome(
				evidence,
				operation['kind'],
				priorResult,
				admission.data.operationId,
				recordedOperationIds,
			);
		}
		return;
	}
	if (requestBody['kind'] !== 'operation.result') return;
	const settlement = bridgeProductOperationResultResponseSchema.safeParse(
		await response.json().catch((): null => null),
	);
	if (
		!settlement.success ||
		settlement.data.outcome !== 'succeeded' ||
		settlement.data.operationId !== requestBody['operationId']
	)
		return;
	resultByOperationId.set(settlement.data.operationId, settlement.data.result);
	const operationKind = operationKindById.get(settlement.data.operationId);
	if (operationKind !== undefined) {
		recordSettledAnnotationOutcome(
			evidence,
			operationKind,
			settlement.data.result,
			settlement.data.operationId,
			recordedOperationIds,
		);
	}
}

function recordSettledAnnotationOutcome(
	evidence: ChurnEvidence,
	operationKind: string,
	responseBody: unknown,
	operationId: string,
	recordedOperationIds: Set<string>,
): void {
	if (recordedOperationIds.has(operationId)) return;
	if (!isRecord(responseBody) || !isRecord(responseBody['call'])) return;
	const result = responseBody['call']['result'];
	if (!isRecord(result) || !isRecord(result['outcome'])) return;
	const outcome = bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(result['outcome']);
	if (!outcome.success) return;
	recordedOperationIds.add(operationId);
	evidence.annotationOutcomes.push({
		operationKind,
		status:
			outcome.data.status.kind === 'failed'
				? `failed:${outcome.data.status.code}`
				: outcome.data.status.kind,
	});
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
