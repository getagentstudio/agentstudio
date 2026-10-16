import { type Page, type Response } from 'playwright';

import { bridgeProductAnnotationProjectionQueryResultSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-projection-query-contracts.js';
import {
	observeProductCallSettlement,
	type SupersededProductCallObservation,
} from './bridge-viewer-vite-product-operation-response.ts';

export async function annotationProjectionUiDiagnostic(
	page: Page,
	savedBody: string | null,
): Promise<{
	readonly committedPreviewCount: number;
	readonly composerCount: number;
	readonly refreshingCount: number;
	readonly savedBodyCount: number;
	readonly threadCount: number;
	readonly unavailableCount: number;
}> {
	return {
		committedPreviewCount: await page
			.getByTestId('worktree-annotation-committed-pending-projection')
			.count(),
		composerCount: await page
			.getByRole('textbox', { name: 'Write an annotation in Markdown' })
			.count(),
		refreshingCount: await page.getByText('Refreshing', { exact: true }).count(),
		savedBodyCount:
			savedBody === null ? 0 : await page.getByText(savedBody, { exact: true }).count(),
		threadCount: await page.getByTestId('worktree-annotation-thread').count(),
		unavailableCount: await page.getByText('Updates unavailable', { exact: true }).count(),
	};
}

export function annotationProjectionContentRequestDiagnostic(value: unknown): unknown {
	if (!isUnknownRecord(value) || value['contentKind'] !== 'annotation.projection') return null;
	const descriptor = value['descriptor'];
	const page = isUnknownRecord(descriptor) ? descriptor['page'] : null;
	return {
		contentRequestId: value['contentRequestId'],
		descriptorId: isUnknownRecord(descriptor) ? descriptor['descriptorId'] : null,
		page: isUnknownRecord(page)
			? {
					operationCorrelationId: page['operationCorrelationId'],
					projectionRevision: page['projectionRevision'],
					snapshotId: page['snapshotId'],
				}
			: null,
	};
}

export function annotationProjectionQueryResultDiagnostic(
	value: unknown,
	request: unknown,
): unknown {
	if (!isUnknownRecord(value)) return { shape: typeof value };
	if (value['kind'] === 'request.error') {
		return {
			code: value['code'],
			kind: value['kind'],
			nextExpectedRequestSequence: value['nextExpectedRequestSequence'],
			requestSequence: value['requestSequence'],
			retryable: value['retryable'],
			safeMessage: value['safeMessage'],
		};
	}
	const call = value['call'];
	if (!isUnknownRecord(call)) return { kind: value['kind'] };
	const result = call['result'];
	if (!isUnknownRecord(result)) return { kind: value['kind'], resultShape: typeof result };
	const descriptor = result['descriptor'];
	if (!isUnknownRecord(descriptor)) {
		return {
			code: result['code'],
			kind: value['kind'],
			resultKind: result['kind'],
		};
	}
	const page = descriptor['page'];
	return {
		descriptorPresent: true,
		kind: value['kind'],
		request: isUnknownRecord(request)
			? {
					cursor: request['cursor'],
					operationCorrelationId: request['operationCorrelationId'],
					sessionIds: request['sessionIds'],
					sourceGeneration: request['sourceGeneration'],
				}
			: null,
		requestSequence: value['requestSequence'],
		page: isUnknownRecord(page)
			? {
					descriptorId: descriptor['descriptorId'],
					expectedMessageCount: page['expectedMessageCount'],
					expectedSessionCount: page['expectedSessionCount'],
					expectedThreadCount: page['expectedThreadCount'],
					operationCorrelationId: page['operationCorrelationId'],
					pageOrdinal: page['pageOrdinal'],
					projectionRevision: page['projectionRevision'],
					snapshotId: page['snapshotId'],
					sourceGeneration: page['sourceGeneration'],
				}
			: null,
	};
}

export async function waitForDemandedAnnotationProjectionContent(props: {
	readonly afterRequestSequence: Promise<number>;
	readonly onSuperseded?: (observation: SupersededProductCallObservation) => void;
	readonly page: Page;
	readonly sessionId: Promise<string>;
}): Promise<void> {
	const matchingDescriptorIds = new Set<string>();
	const completedDescriptorIds = new Set<string>();
	let resolveMatch: (() => void) | null = null;
	let rejectMatch: ((error: Error) => void) | null = null;
	let settled = false;
	const completion = new Promise<void>((resolve, reject): void => {
		resolveMatch = resolve;
		rejectMatch = reject;
	});
	// Attach ownership at creation, before any response can reject the inner completion.
	const completionOutcome = completion.then(
		(): { readonly kind: 'complete' } => ({ kind: 'complete' }),
		(error: unknown): { readonly kind: 'failed'; readonly error: unknown } => ({
			kind: 'failed',
			error,
		}),
	);
	const failObservation = (error: Error): void => {
		if (settled) return;
		settled = true;
		rejectMatch?.(error);
	};
	const observationController = new AbortController();
	const querySettlement = observeProductCallSettlement({
		page: props.page,
		onSuperseded: (observation): void => {
			console.info('[annotation-projection-superseded]', JSON.stringify(observation));
			props.onSuperseded?.(observation);
		},
		matchesCall: async (response): Promise<boolean> => {
			const request = response.request();
			if (new URL(request.url()).pathname !== '/__bridge-product/command') return false;
			const requestBody: unknown = request.postDataJSON();
			if (!isUnknownRecord(requestBody) || requestBody['kind'] !== 'product.call') return false;
			const call = requestBody['call'];
			if (!isUnknownRecord(call) || !isUnknownRecord(call['request'])) return false;
			if (
				call['method'] !== 'file.annotations.projection.query' &&
				call['method'] !== 'review.annotations.projection.query'
			)
				return false;
			const queryRequest = call['request'];
			const [afterRequestSequence, sessionId] = await Promise.all([
				props.afterRequestSequence,
				props.sessionId,
			]);
			return (
				typeof requestBody['requestSequence'] === 'number' &&
				requestBody['requestSequence'] > afterRequestSequence &&
				Array.isArray(queryRequest['sessionIds']) &&
				queryRequest['sessionIds'].includes(sessionId)
			);
		},
		signal: observationController.signal,
	});
	void querySettlement
		.then(
			(settled): void => {
				const result = settled.result;
				const call = isUnknownRecord(result) ? result['call'] : null;
				const callResult = isUnknownRecord(call) ? call['result'] : null;
				const projectionResult =
					bridgeProductAnnotationProjectionQueryResultSchema.parse(callResult);
				if (projectionResult.kind !== 'content') {
					failObservation(new Error('Demanded annotation projection result has no descriptor.'));
					return;
				}
				const descriptorId = projectionResult.descriptor.descriptorId;
				matchingDescriptorIds.add(descriptorId);
				settleIfMatched(descriptorId);
			},
			(error: unknown): void => {
				failObservation(error instanceof Error ? error : new Error('Projection query failed.'));
			},
		)
		.catch((error: unknown): void => {
			failObservation(error instanceof Error ? error : new Error('Projection parsing failed.'));
		});
	const settleIfMatched = (descriptorId: string): void => {
		if (settled || !matchingDescriptorIds.has(descriptorId)) return;
		if (!completedDescriptorIds.has(descriptorId)) return;
		settled = true;
		resolveMatch?.();
	};
	const inspectResponse = async (response: Response): Promise<void> => {
		const request = response.request();
		const path = new URL(request.url()).pathname;
		const requestBody: unknown = request.postDataJSON();
		if (path === '/__bridge-product/content') {
			if (!response.ok()) return;
			const descriptorId = annotationProjectionContentDescriptorId(requestBody);
			if (descriptorId === null) return;
			completedDescriptorIds.add(descriptorId);
			settleIfMatched(descriptorId);
			return;
		}
	};
	const responseListener = (response: Response): void => {
		void inspectResponse(response).catch((error: unknown): void => {
			if (settled) return;
			settled = true;
			rejectMatch?.(
				error instanceof Error
					? error
					: new Error('Demanded annotation projection inspection failed.'),
			);
		});
	};
	const onPageClosed = (): void =>
		failObservation(new Error('Page closed before demanded projection content completed.'));
	props.page.on('response', responseListener);
	props.page.on('close', onPageClosed);
	try {
		const outcome = await completionOutcome;
		if (outcome.kind === 'failed') throw outcome.error;
	} finally {
		observationController.abort();
		props.page.off('response', responseListener);
		props.page.off('close', onPageClosed);
	}
}

function annotationProjectionContentDescriptorId(value: unknown): string | null {
	if (!isUnknownRecord(value) || value['contentKind'] !== 'annotation.projection') return null;
	const descriptor = value['descriptor'];
	return isUnknownRecord(descriptor) && typeof descriptor['descriptorId'] === 'string'
		? descriptor['descriptorId']
		: null;
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
