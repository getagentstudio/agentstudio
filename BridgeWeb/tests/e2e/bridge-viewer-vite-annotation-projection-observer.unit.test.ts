import type { Page, Request, Response } from 'playwright';
import { expect, test } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import {
	bridgeProductOperationAdmittedResponseSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import { bridgeProductAnnotationProjectionContentDescriptorSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-projection-query-contracts.js';
import { waitForDemandedAnnotationProjectionContent } from './bridge-viewer-vite-annotation-projection-test-support.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';

const sessionId = '00000000-0000-7000-8000-000000000021';
const correlation = { paneSessionId: 'pane', workerInstanceId: 'worker', wireVersion: 2 } as const;
interface SupersededObservation {
	readonly operationId: string;
	readonly requestSequence: number;
	readonly failureCode: 'superseded';
}

/** Only the external Page/Response transport is faked; all observation and wire parsing stay real. */
class ProjectionResponseTransport {
	readonly responseListeners = new Set<(response: Response) => void>();
	readonly closeListeners = new Set<() => void>();
	readonly operationObserverReleased = createBridgeProductDeferred<void>();
	// The mock implements exactly the Page events consumed by these helpers, not browser behavior.
	readonly page = {
		on: (event: string, listener: ((response: Response) => void) | (() => void)): void => {
			if (event === 'response') this.responseListeners.add(listener);
			else if (event === 'close') this.closeListeners.add(listener as () => void);
			else throw new Error(`Unexpected observation event ${event}`);
		},
		off: (event: string, listener: ((response: Response) => void) | (() => void)): void => {
			if (event === 'response') this.responseListeners.delete(listener);
			else if (event === 'close') {
				this.closeListeners.delete(listener as () => void);
				this.operationObserverReleased.resolve();
			}
		},
	} as unknown as Page;

	emit(requestBody: unknown, responseBody: unknown, path = 'command'): void {
		const request = {
			method: (): string => 'POST',
			url: (): string => `http://fixture/__bridge-product/${path}`,
			postDataJSON: (): unknown => requestBody,
		} as unknown as Request;
		const response = {
			request: (): Request => request,
			ok: (): boolean => true,
			json: async (): Promise<unknown> => responseBody,
		} as unknown as Response;
		for (const listener of this.responseListeners) listener(response);
	}

	close(): void {
		for (const listener of this.closeListeners) listener();
	}
}

function queryAdmission(
	transport: ProjectionResponseTransport,
	operationId: string,
	sequence: number,
	demandedSessionId = sessionId,
): void {
	const requestId = `query-${sequence}`;
	const request = bridgeProductControlRequestSchema.parse({
		...correlation,
		kind: 'product.call',
		requestId,
		requestSequence: sequence,
		workerDerivationEpoch: 1,
		call: {
			method: 'file.annotations.projection.query',
			request: {
				cursor: null,
				operationCorrelationId: String(sequence).padStart(64, '0'),
				sessionIds: [demandedSessionId],
				sourceGeneration: 1,
				surface: 'file',
			},
		},
	});
	const response = bridgeProductOperationAdmittedResponseSchema.parse({
		...correlation,
		kind: 'operation.admitted',
		requestId,
		requestSequence: sequence,
		operationId,
		waitKind: 'ordinary',
	});
	transport.emit(request, response);
}

function refusedResult(
	transport: ProjectionResponseTransport,
	operationId: string,
	failureCode: 'superseded' | 'internal' | 'invalid_request',
	outcome: 'refused' | 'failed' = 'refused',
): void {
	transport.emit(
		{ ...correlation, kind: 'operation.result', operationId },
		bridgeProductOperationResultResponseSchema.parse({
			kind: 'operation.result',
			operationId,
			outcome,
			failureCode,
			result: null,
		}),
	);
}

function successfulProjection(
	transport: ProjectionResponseTransport,
	operationId: string,
	sequence: number,
	descriptorId: string,
	emitContent = true,
): void {
	const descriptor = bridgeProductAnnotationProjectionContentDescriptorSchema.parse({
		contentKind: 'annotation.projection',
		descriptorId,
		maximumBytes: 128,
		surface: 'file',
		page: {
			aggregateSha256: '0'.repeat(64),
			expectedMessageCount: 1,
			expectedPageCount: 1,
			expectedSessionCount: 1,
			expectedThreadCount: 1,
			isLastPage: true,
			nextCursor: null,
			operationCorrelationId: String(sequence).padStart(64, '0'),
			pageOrdinal: 0,
			projectionRevision: 5,
			snapshotId: '00000000-0000-7000-8000-000000000022',
			sourceGeneration: 1,
		},
	});
	const result = bridgeProductControlResponseSchema.parse({
		...correlation,
		requestId: `query-${sequence}`,
		requestSequence: sequence,
		kind: 'call.completed',
		call: { method: 'file.annotations.projection.query', result: { kind: 'content', descriptor } },
	});
	transport.emit(
		{ ...correlation, kind: 'operation.result', operationId },
		bridgeProductOperationResultResponseSchema.parse({
			kind: 'operation.result',
			operationId,
			outcome: 'succeeded',
			failureCode: null,
			result,
		}),
	);
	if (emitContent)
		transport.emit(
			{ contentKind: 'annotation.projection', descriptor },
			{ kind: 'content.open' },
			'content',
		);
}

function startProjectionObserver(
	transport: ProjectionResponseTransport,
	observations: SupersededObservation[],
	onSuperseded?: () => void,
): Promise<void> {
	const props = {
		afterRequestSequence: Promise.resolve(10),
		page: transport.page,
		sessionId: Promise.resolve(sessionId),
		onSuperseded: (observation: SupersededObservation): void => {
			observations.push(observation);
			onSuperseded?.();
		},
	};
	return waitForDemandedAnnotationProjectionContent(props);
}

test('superseded A is recorded, then newer B for the committed session completes the real projection observer', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const observed = startProjectionObserver(transport, observations);
	// Rejection owner exists before any responses are emitted, including on the baseline red.
	const outcome = observed.then(
		() => ({ kind: 'completed' as const }),
		(error: unknown) => ({ kind: 'failed' as const, error }),
	);
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		queryAdmission(transport, 'query-B', 12);
		successfulProjection(transport, 'query-B', 12, 'descriptor-B');
		expect(await outcome).toEqual({ kind: 'completed' });
		expect(observations).toEqual([
			{ operationId: 'query-A', requestSequence: 11, failureCode: 'superseded' },
		]);
		expect(transport.responseListeners.size).toBe(0);
		expect(transport.closeListeners.size).toBe(0);
	} finally {
		transport.close();
		await outcome;
	}
});

test.each(['internal', 'invalid_request'] as const)(
	'a refused %s projection remains terminal with its operation identity and code',
	async (failureCode): Promise<void> => {
		const transport = new ProjectionResponseTransport();
		const observations: SupersededObservation[] = [];
		const observed = startProjectionObserver(transport, observations);
		const rejected = expect(observed).rejects.toThrow(new RegExp(`query-A.*${failureCode}`));
		try {
			queryAdmission(transport, 'query-A', 11);
			refusedResult(transport, 'query-A', failureCode);
			queryAdmission(transport, 'query-B', 12);
			successfulProjection(transport, 'query-B', 12, 'descriptor-B');
			await rejected;
			expect(observations).toEqual([]);
			expect(transport.responseListeners.size).toBe(0);
		} finally {
			transport.close();
			await observed.catch((): void => {});
		}
	},
);

test('the generic single-call waiter does not ignore a superseded refusal', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observed = waitForProductCallSettlement(transport.page, (response): boolean => {
		const body: unknown = response.request().postDataJSON();
		return (
			typeof body === 'object' && body !== null && 'kind' in body && body.kind === 'product.call'
		);
	});
	const rejected = expect(observed).rejects.toThrow(/query-A.*superseded/);
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		await rejected;
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('newer B received before A refusal is retained, while a different session cannot settle the observation', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const observed = startProjectionObserver(transport, observations);
	const completion = expect(observed).resolves.toBeUndefined();
	try {
		queryAdmission(transport, 'query-A', 11);
		queryAdmission(transport, 'query-unrelated', 12, '00000000-0000-7000-8000-000000000023');
		refusedResult(transport, 'query-unrelated', 'superseded');
		queryAdmission(transport, 'query-B', 13);
		successfulProjection(transport, 'query-B', 13, 'descriptor-B');
		refusedResult(transport, 'query-A', 'superseded');
		await completion;
		expect(observations).toEqual([
			{ operationId: 'query-A', requestSequence: 11, failureCode: 'superseded' },
		]);
		expect(transport.responseListeners.size).toBe(0);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('failed/superseded is terminal: only refused/superseded may follow a newer query', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const observed = startProjectionObserver(transport, observations);
	const rejected = expect(observed).rejects.toThrow(/query-A.*failed.*superseded/);
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded', 'failed');
		await rejected;
		expect(observations).toEqual([]);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('page close owns cancellation after the observer follows a superseded query', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const superseded = createBridgeProductDeferred<void>();
	const observed = startProjectionObserver(transport, observations, (): void =>
		superseded.resolve(),
	);
	const rejected = expect(observed).rejects.toThrow(/Page closed/);
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		await superseded.promise;
		transport.close();
		await rejected;
		expect(transport.responseListeners.size).toBe(0);
		expect(transport.closeListeners.size).toBe(0);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('a superseded query for a different session is ignored, rather than recorded or followed', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const observed = startProjectionObserver(transport, observations);
	const completed = expect(observed).resolves.toBeUndefined();
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		queryAdmission(transport, 'query-other-session', 12, '00000000-0000-7000-8000-000000000023');
		refusedResult(transport, 'query-other-session', 'superseded');
		queryAdmission(transport, 'query-B', 13);
		successfulProjection(transport, 'query-B', 13, 'descriptor-B');
		await completed;
		expect(observations).toEqual([
			{ operationId: 'query-A', requestSequence: 11, failureCode: 'superseded' },
		]);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('page close settles content observation even after its successful query waiter has detached', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observed = startProjectionObserver(transport, []);
	const rejected = expect(observed).rejects.toThrow(/Page closed/);
	try {
		queryAdmission(transport, 'query-B', 12);
		successfulProjection(transport, 'query-B', 12, 'descriptor-B', false);
		await transport.operationObserverReleased.promise;
		transport.close();
		await rejected;
		expect(transport.responseListeners.size).toBe(0);
		expect(transport.closeListeners.size).toBe(0);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});

test('an exact replay of superseded A is not a newer query and cannot be followed again', async (): Promise<void> => {
	const transport = new ProjectionResponseTransport();
	const observations: SupersededObservation[] = [];
	const superseded = createBridgeProductDeferred<void>();
	const observed = startProjectionObserver(transport, observations, (): void =>
		superseded.resolve(),
	);
	const completed = expect(observed).resolves.toBeUndefined();
	try {
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		await superseded.promise;
		queryAdmission(transport, 'query-A', 11);
		refusedResult(transport, 'query-A', 'superseded');
		queryAdmission(transport, 'query-B', 12);
		successfulProjection(transport, 'query-B', 12, 'descriptor-B');
		await completed;
		expect(observations).toEqual([
			{ operationId: 'query-A', requestSequence: 11, failureCode: 'superseded' },
		]);
	} finally {
		transport.close();
		await observed.catch((): void => {});
	}
});
