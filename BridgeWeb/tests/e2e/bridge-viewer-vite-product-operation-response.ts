import type { Page, Response } from 'playwright';

import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';

export interface SettledProductCallResponse {
	readonly operationId: string;
	readonly requestSequence: number;
	readonly response: Response;
	readonly result: unknown;
}

export interface SupersededProductCallObservation {
	readonly failureCode: 'superseded';
	readonly operationId: string;
	readonly requestSequence: number;
}

interface ProductCallSettlementObservationProps {
	readonly page: Page;
	readonly matchesCall: (response: Response) => boolean | Promise<boolean>;
	readonly signal?: AbortSignal;
	readonly onSuperseded?: (observation: SupersededProductCallObservation) => void;
}

/** A single-call assertion is terminal on every refusal; projection alone opts into supersession. */
export function waitForProductCallSettlement(
	page: Page,
	matchesCall: (response: Response) => boolean | Promise<boolean>,
	signal?: AbortSignal,
): Promise<SettledProductCallResponse> {
	return observeProductCallSettlement({
		page,
		matchesCall,
		...(signal === undefined ? {} : { signal }),
	});
}

/** Correlates real admissions/results, retaining newer candidates received before an older refusal. */
export function observeProductCallSettlement(
	props: ProductCallSettlementObservationProps,
): Promise<SettledProductCallResponse> {
	return new Promise<SettledProductCallResponse>((resolve, reject): void => {
		const admissions = new Map<
			string,
			{ readonly operationId: string; readonly requestSequence: number }
		>();
		const pendingAdmissions = new Set<{ readonly requestSequence: number }>();
		const resultsByOperationId = new Map<
			string,
			{
				readonly parsed: ReturnType<typeof bridgeProductOperationResultResponseSchema.parse>;
				readonly response: Response;
			}
		>();
		let minimumRequestSequence = 0;
		let finished = false;
		const cleanup = (): void => {
			props.page.off('response', onResponse);
			props.page.off('close', onClose);
			props.signal?.removeEventListener('abort', onAbort);
		};
		const fail = (error: unknown): void => {
			if (finished) return;
			finished = true;
			cleanup();
			reject(error);
		};
		const finishIfReady = (): void => {
			// Each iteration consumes a buffered superseded admission; this never waits or resends.
			while (!finished) {
				const admission = [...admissions.values()]
					.filter((candidate) => candidate.requestSequence > minimumRequestSequence)
					.toSorted((left, right) => left.requestSequence - right.requestSequence)[0];
				if (admission === undefined) return;
				// An earlier response may still be resolving the committed-session matcher.
				if (
					[...pendingAdmissions].some(
						(candidate) =>
							candidate.requestSequence > minimumRequestSequence &&
							candidate.requestSequence < admission.requestSequence,
					)
				)
					return;
				const settlement = resultsByOperationId.get(admission.operationId);
				if (settlement === undefined) return;
				if (
					settlement.parsed.outcome === 'refused' &&
					settlement.parsed.failureCode === 'superseded' &&
					props.onSuperseded !== undefined
				) {
					props.onSuperseded({ ...admission, failureCode: 'superseded' });
					minimumRequestSequence = admission.requestSequence;
					admissions.delete(admission.operationId);
					resultsByOperationId.delete(admission.operationId);
					continue;
				}
				finished = true;
				cleanup();
				if (settlement.parsed.outcome !== 'succeeded') {
					reject(
						new Error(
							`Product call ${admission.operationId} settled as ${settlement.parsed.outcome}; failureCode=${settlement.parsed.failureCode ?? 'none'}.`,
						),
					);
					return;
				}
				resolve({ ...admission, response: settlement.response, result: settlement.parsed.result });
			}
		};
		const inspect = async (response: Response): Promise<void> => {
			const request = response.request();
			if (
				request.method() !== 'POST' ||
				new URL(request.url()).pathname !== '/__bridge-product/command'
			)
				return;
			const requestBody: unknown = request.postDataJSON();
			if (!isRecord(requestBody)) return;
			if (
				requestBody['kind'] === 'product.call' &&
				typeof requestBody['requestSequence'] === 'number'
			) {
				const pending = { requestSequence: requestBody['requestSequence'] };
				pendingAdmissions.add(pending);
				try {
					if (!(await props.matchesCall(response)) || finished) return;
					const parsed = bridgeProductAdmissionResponseSchema.parse(await response.json());
					if (finished) return;
					if (parsed.kind !== 'operation.admitted')
						throw new Error(`Product call admission was refused with ${parsed.code}.`);
					admissions.set(parsed.operationId, {
						operationId: parsed.operationId,
						requestSequence: parsed.requestSequence,
					});
				} catch (error: unknown) {
					fail(error);
				} finally {
					pendingAdmissions.delete(pending);
					finishIfReady();
				}
				return;
			}
			if (requestBody['kind'] !== 'operation.result') return;
			const parsed = bridgeProductOperationResultResponseSchema.parse(await response.json());
			if (finished) return;
			if (parsed.operationId !== requestBody['operationId'])
				throw new Error('Product result response does not match its request.');
			resultsByOperationId.set(parsed.operationId, { parsed, response });
			finishIfReady();
		};
		const onResponse = (response: Response): void => {
			void inspect(response).catch(fail);
		};
		const onClose = (): void => fail(new Error('Page closed before product call settlement.'));
		const onAbort = (): void =>
			fail(props.signal?.reason ?? new Error('Product call observation cancelled.'));
		props.page.on('response', onResponse);
		props.page.on('close', onClose);
		if (props.signal?.aborted) onAbort();
		else props.signal?.addEventListener('abort', onAbort, { once: true });
	});
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
