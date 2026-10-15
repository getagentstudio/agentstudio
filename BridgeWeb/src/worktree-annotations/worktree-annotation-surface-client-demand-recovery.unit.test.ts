import { describe, expect, test } from 'vitest';

import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	createSurfaceClientHarness,
	projectionSnapshot,
	sessionId,
} from './worktree-annotation-surface-client.test-support.js';

describe('worktree annotation session demand recovery', () => {
	test('retries a demand acquisition that did not commit within a bounded budget', () => {
		// Arrange
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);

		// Act: the first two attempts fail, one degraded and one with a non-committed outcome.
		harness.publish(degradedWorkerRequest(demandAcquireRequestIds(harness)[0]));
		harness.publish(
			demandAcquireOutcome(demandAcquireRequestIds(harness)[1], {
				code: 'unavailable',
				kind: 'failed',
			}),
		);
		harness.publish(degradedWorkerRequest(demandAcquireRequestIds(harness)[2]));

		// Assert: three attempts total, then the client waits for a worker event.
		expect(demandAcquireRequestIds(harness)).toHaveLength(3);

		// Act: the worker converges again, which re-admits one attempt that commits.
		harness.publish(refreshingConvergence());
		harness.publish(
			demandAcquireOutcome(demandAcquireRequestIds(harness)[3], { kind: 'committed' }),
		);
		harness.publish(refreshingConvergence());

		// Assert: committed demand is not re-acquired by later convergence.
		expect(demandAcquireRequestIds(harness)).toHaveLength(4);
		releaseSession();
		harness.client.dispose();
	});

	test('replays committed demand to a replacement worker once the replacement converges', () => {
		// Arrange
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		harness.publish(
			demandAcquireOutcome(demandAcquireRequestIds(harness)[0], { kind: 'committed' }),
		);
		const commandCountBeforeReplacement = harness.sentCommands.length;

		// Act: the retiring worker cannot receive commands, so nothing is sent yet.
		harness.fireWorkerReplacement();
		const commandsDuringReplacement = harness.sentCommands.slice(commandCountBeforeReplacement);
		harness.publish(controlOnlyReadyConvergence());

		// Assert
		expect(commandsDuringReplacement).toEqual([]);
		expect(demandAcquireRequestIds(harness)).toHaveLength(2);
		expect(harness.sentCommands.slice(commandCountBeforeReplacement)).toContainEqual(
			expect.objectContaining({
				operation: expect.objectContaining({ kind: 'source.refresh', sessionId }),
			}),
		);

		// Act: the replayed acquisition commits, and later convergence stays quiet.
		harness.publish(
			demandAcquireOutcome(demandAcquireRequestIds(harness)[1], { kind: 'committed' }),
		);
		harness.publish(refreshingConvergence());

		// Assert
		expect(demandAcquireRequestIds(harness)).toHaveLength(2);
		releaseSession();
		harness.client.dispose();
	});

	test('ignores a retired attempt that settles after worker replacement', () => {
		// Arrange
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		const retiredAttemptRequestId = demandAcquireRequestIds(harness)[0];

		// Act
		harness.fireWorkerReplacement();
		harness.publish(degradedWorkerRequest(retiredAttemptRequestId));

		// Assert: the retired failure spends no retry against the replacement worker.
		expect(demandAcquireRequestIds(harness)).toHaveLength(1);
		harness.publish(refreshingConvergence());
		expect(demandAcquireRequestIds(harness)).toHaveLength(2);
		releaseSession();
		harness.client.dispose();
	});

	test('does not re-acquire a session whose demand was released', () => {
		// Arrange
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);

		// Act
		releaseSession();
		harness.publish(degradedWorkerRequest(demandAcquireRequestIds(harness)[0]));
		harness.publish(refreshingConvergence());

		// Assert
		expect(demandAcquireRequestIds(harness)).toHaveLength(1);
		harness.client.dispose();
	});
});

function demandAcquireRequestIds(
	harness: ReturnType<typeof createSurfaceClientHarness>,
): readonly string[] {
	return harness.sentCommands.flatMap((command, index): readonly string[] =>
		command.command === 'annotationCommand' && command.operation.kind === 'demand.acquire'
			? [`worker-save-${(index + 1).toString()}`]
			: [],
	);
}

function degradedWorkerRequest(requestId: string | undefined): BridgeWorkerServerToMainMessage {
	if (requestId === undefined) throw new Error('Expected a sent demand acquisition.');
	return {
		direction: 'serverWorkerToMain',
		kind: 'health',
		message: 'Bridge annotation command failed.',
		requestId,
		status: 'degraded',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function demandAcquireOutcome(
	requestId: string | undefined,
	status:
		| { readonly kind: 'committed' }
		| { readonly code: 'unavailable'; readonly kind: 'failed' },
): BridgeWorkerServerToMainMessage {
	if (requestId === undefined) throw new Error('Expected a sent demand acquisition.');
	const productRequestId = `product-${requestId}`;
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationCommandAccepted',
		outcome: { requestId: productRequestId, sessionId, status, surface: 'file' },
		productRequestId,
		requestId,
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function refreshingConvergence(): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationProjectionConvergence',
		operationCorrelationId: null,
		state: { catalogAuthorityRetired: false, kind: 'refreshing' },
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function controlOnlyReadyConvergence(): BridgeWorkerServerToMainMessage {
	return {
		direction: 'serverWorkerToMain',
		kind: 'annotationProjectionConvergence',
		operationCorrelationId: 'b'.repeat(64),
		state: {
			contentSessionIds: [],
			kind: 'ready',
			stageAttempt: 0,
			snapshot: { ...projectionSnapshot(9, 12), threads: [] },
		},
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}
