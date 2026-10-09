import { describe, expect, test } from 'vitest';

import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerServerToMainMessageSchema,
} from './bridge-worker-contracts.js';

describe('Bridge worker annotation convergence authority', () => {
	test('requires exact Review identity on Review ready convergence and forbids it for File', () => {
		const readyState = {
			contentSessionIds: [],
			kind: 'ready' as const,
			stageAttempt: 0,
			snapshot: {
				expectedMessageCount: 0,
				expectedSessionCount: 0,
				expectedThreadCount: 0,
				projectionRevision: 1,
				recoveryStatus: 'available' as const,
				sessions: [],
				sourceGeneration: 7,
				threads: [],
				worktreeId: 'worktree-1',
			},
		};
		const convergence = {
			direction: 'serverWorkerToMain' as const,
			kind: 'annotationProjectionConvergence' as const,
			operationCorrelationId: 'a'.repeat(64),
			transferDescriptors: [],
			wireVersion: BRIDGE_WORKER_WIRE_VERSION,
		};
		const reviewPublicationIdentity = {
			packageId: 'package-1',
			publicationId: '00000000-0000-7000-8000-000000000041',
			reviewGeneration: 7,
			revision: 3,
			sourceIdentity: 'source-1',
		};

		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...convergence,
				state: readyState,
				surface: 'review',
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerServerToMainMessageSchema.parse({
				...convergence,
				state: { ...readyState, reviewPublicationIdentity },
				surface: 'review',
			}),
		).toMatchObject({ state: { reviewPublicationIdentity }, surface: 'review' });
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...convergence,
				state: { ...readyState, reviewPublicationIdentity },
				surface: 'fileView',
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerServerToMainMessageSchema.safeParse({
				...convergence,
				state: readyState,
				surface: 'fileView',
			}).success,
		).toBe(true);
	});
});
