import { describe, expect, test } from 'vitest';

import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import { BRIDGE_WORKER_WIRE_VERSION } from '../core/comm-worker/bridge-worker-contracts.js';
import {
	createSurfaceClientHarness,
	sessionId,
} from './worktree-annotation-surface-client.test-support.js';

type SurfaceClientHarness = ReturnType<typeof createSurfaceClientHarness>;
type AnnotationCommand = Extract<
	Parameters<BridgePaneSurfaceClient['send']>[0],
	{ readonly command: 'annotationCommand' }
>;

describe('source refresh depends on current committed annotation demand', () => {
	test.for(['fileView', 'review'] as const)(
		'holds refresh until %s acquisition commits',
		(surface) => {
			const harness = createSurfaceClientHarness([], surface);
			const releaseSession = harness.client.acquireSession(sessionId);
			try {
				// The real client has sent acquisition; its transport outcome is held.
				expect(demandRequestIds(harness)).toHaveLength(1);
				expect(sourceRefreshCommands(harness)).toEqual([]);

				settleDemand(harness, demandRequestIds(harness)[0]);
				expect(sourceRefreshCommands(harness)).toHaveLength(1);
				expect(sourceRefreshCommands(harness)[0]?.operation).toEqual({
					kind: 'source.refresh',
					sessionId,
					sourceEpoch: 1,
				});
			} finally {
				releaseSession();
				harness.client.dispose();
			}
		},
	);

	test('retains the latest source epoch while acquisition is held', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			advanceSourceEpoch(harness, 3);
			advanceSourceEpoch(harness, 5);
			expect(sourceRefreshCommands(harness)).toEqual([]);
			settleDemand(harness, demandRequestIds(harness)[0]);
			expect(sourceRefreshCommands(harness)).toEqual([
				{
					command: 'annotationCommand',
					epoch: 5,
					surface: 'fileView',
					operation: { kind: 'source.refresh', sessionId, sourceEpoch: 1 },
				},
			]);

			advanceSourceEpoch(harness, 6);
			expect(sourceRefreshCommands(harness).at(-1)).toMatchObject({
				epoch: 6,
				operation: { kind: 'source.refresh', sourceEpoch: 2 },
			});
			expect(sourceRefreshCommands(harness)).toHaveLength(2);
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('holds replacement refresh until the replacement acquisition commits', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			const initialRequestId = demandRequestIds(harness)[0];
			settleDemand(harness, initialRequestId);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
			harness.fireWorkerReplacement();
			publishWorkerConvergence(harness);
			advanceSourceEpoch(harness, 9);
			expect(demandRequestIds(harness)).toHaveLength(2);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);

			// A retired worker's duplicate outcome cannot release the current dependency.
			settleDemand(harness, initialRequestId);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
			settleDemand(harness, demandRequestIds(harness)[1]);
			expect(sourceRefreshCommands(harness)).toHaveLength(2);
			expect(sourceRefreshCommands(harness).at(-1)).toMatchObject({
				epoch: 9,
				operation: { kind: 'source.refresh', sourceEpoch: 2 },
			});
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('does not refresh when demand is released before the held commit', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		releaseSession();
		settleDemand(harness, demandRequestIds(harness)[0]);
		advanceSourceEpoch(harness, 3);
		expect(sourceRefreshCommands(harness)).toEqual([]);
		harness.client.dispose();
	});

	test('does not let an old acquisition release newly acquired demand for the same session', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseOldDemand = harness.client.acquireSession(sessionId);
		const oldRequestId = demandRequestIds(harness)[0];
		releaseOldDemand();
		const releaseNewDemand = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, oldRequestId);
			expect(sourceRefreshCommands(harness)).toEqual([]);
			settleDemand(harness, demandRequestIds(harness)[1]);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
		} finally {
			releaseNewDemand();
			harness.client.dispose();
		}
	});

	test('a File source change recovers parked demand without worker convergence', () => {
		const harness = createSurfaceClientHarness([], 'fileView');
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, demandRequestIds(harness)[0], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[1], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[2], { kind: 'failed', code: 'unavailable' });
			expect(demandRequestIds(harness)).toHaveLength(3);
			expect(sourceRefreshCommands(harness)).toEqual([]);

			// File activation/source acceptance advances the owner's epoch after early failures.
			advanceSourceEpoch(harness, 7);
			expect(demandRequestIds(harness)).toHaveLength(4);
			expect(sourceRefreshCommands(harness)).toEqual([]);
			advanceSourceEpoch(harness, 9);
			expect(demandRequestIds(harness)).toHaveLength(4);
			settleDemand(harness, demandRequestIds(harness)[3]);

			expect(sourceRefreshCommands(harness)).toEqual([
				{
					command: 'annotationCommand',
					epoch: 9,
					surface: 'fileView',
					operation: { kind: 'source.refresh', sessionId, sourceEpoch: 1 },
				},
			]);
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('a source change during the final held acquisition still re-admits demand', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, demandRequestIds(harness)[0], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[1], { kind: 'failed', code: 'unavailable' });
			advanceSourceEpoch(harness, 7);
			expect(demandRequestIds(harness)).toHaveLength(3);
			expect(sourceRefreshCommands(harness)).toEqual([]);

			// The pre-activation rejection arrives after the new source was accepted.
			settleDemand(harness, demandRequestIds(harness)[2], { kind: 'failed', code: 'unavailable' });
			expect(demandRequestIds(harness)).toHaveLength(4);
			settleDemand(harness, demandRequestIds(harness)[3]);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
			expect(sourceRefreshCommands(harness)[0]?.epoch).toBe(7);
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('each source change re-admits only one attempt after the failed-acquisition budget', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, demandRequestIds(harness)[0], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[1], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[2], { kind: 'failed', code: 'unavailable' });

			advanceSourceEpoch(harness, 7);
			expect(demandRequestIds(harness)).toHaveLength(4);
			settleDemand(harness, demandRequestIds(harness)[3], { kind: 'failed', code: 'unavailable' });
			expect(demandRequestIds(harness)).toHaveLength(4);
			advanceSourceEpoch(harness, 8);
			expect(demandRequestIds(harness)).toHaveLength(5);
			settleDemand(harness, demandRequestIds(harness)[4], { kind: 'failed', code: 'unavailable' });
			expect(demandRequestIds(harness)).toHaveLength(5);
			expect(sourceRefreshCommands(harness)).toEqual([]);
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('source changes wait for convergence when the worker itself is being replaced', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, demandRequestIds(harness)[0]);
			harness.fireWorkerReplacement();
			advanceSourceEpoch(harness, 7);
			expect(demandRequestIds(harness)).toHaveLength(1);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);

			publishWorkerConvergence(harness);
			expect(demandRequestIds(harness)).toHaveLength(2);
			settleDemand(harness, demandRequestIds(harness)[1]);
			expect(sourceRefreshCommands(harness).at(-1)).toMatchObject({
				epoch: 7,
				operation: { kind: 'source.refresh', sourceEpoch: 2 },
			});
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('keeps refresh pending through failed attempts and worker recovery', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseSession = harness.client.acquireSession(sessionId);
		try {
			settleDemand(harness, demandRequestIds(harness)[0], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[1], { kind: 'failed', code: 'unavailable' });
			settleDemand(harness, demandRequestIds(harness)[2], { kind: 'failed', code: 'unavailable' });
			expect(sourceRefreshCommands(harness)).toEqual([]);
			expect(demandRequestIds(harness)).toHaveLength(3);

			publishWorkerConvergence(harness);
			advanceSourceEpoch(harness, 7);
			expect(demandRequestIds(harness)).toHaveLength(4);
			expect(sourceRefreshCommands(harness)).toEqual([]);
			settleDemand(harness, demandRequestIds(harness)[3]);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
			expect(sourceRefreshCommands(harness)[0]?.epoch).toBe(7);
		} finally {
			releaseSession();
			harness.client.dispose();
		}
	});

	test('ignores a held commit after client disposal', () => {
		const harness = createSurfaceClientHarness([]);
		harness.client.acquireSession(sessionId);
		harness.client.dispose();
		settleDemand(harness, demandRequestIds(harness)[0]);
		expect(sourceRefreshCommands(harness)).toEqual([]);
	});

	test('refreshes a held shared acquisition while one demander remains', () => {
		const harness = createSurfaceClientHarness([]);
		const releaseFirst = harness.client.acquireSession(sessionId);
		const releaseSecond = harness.client.acquireSession(sessionId);
		try {
			releaseFirst();
			expect(sourceRefreshCommands(harness)).toEqual([]);
			settleDemand(harness, demandRequestIds(harness)[0]);
			expect(demandRequestIds(harness)).toHaveLength(1);
			expect(sourceRefreshCommands(harness)).toHaveLength(1);
		} finally {
			releaseSecond();
			harness.client.dispose();
		}
	});
});

function demandRequestIds(harness: SurfaceClientHarness): readonly string[] {
	return harness.sentCommands.flatMap((command, index): readonly string[] =>
		command.command === 'annotationCommand' && command.operation.kind === 'demand.acquire'
			? [`worker-save-${(index + 1).toString()}`]
			: [],
	);
}

function sourceRefreshCommands(harness: SurfaceClientHarness): readonly AnnotationCommand[] {
	return harness.sentCommands.filter(
		(command): command is AnnotationCommand =>
			command.command === 'annotationCommand' && command.operation.kind === 'source.refresh',
	);
}

function settleDemand(
	harness: SurfaceClientHarness,
	requestId: string | undefined,
	status:
		| { readonly kind: 'committed' }
		| { readonly kind: 'failed'; readonly code: 'unavailable' } = { kind: 'committed' },
): void {
	if (requestId === undefined) throw new Error('Expected a dispatched held acquisition.');
	const surface = harness.surfaceClient.surface;
	const productRequestId = `product-${requestId}`;
	harness.publish({
		direction: 'serverWorkerToMain',
		kind: 'annotationCommandAccepted',
		outcome: {
			requestId: productRequestId,
			sessionId,
			status,
			surface: surface === 'fileView' ? 'file' : 'review',
		},
		productRequestId,
		requestId,
		surface,
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

function publishWorkerConvergence(harness: SurfaceClientHarness): void {
	harness.publish({
		direction: 'serverWorkerToMain',
		kind: 'annotationProjectionConvergence',
		operationCorrelationId: null,
		state: { catalogAuthorityRetired: false, kind: 'refreshing' },
		surface: harness.surfaceClient.surface,
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}

function advanceSourceEpoch(harness: SurfaceClientHarness, epoch: number): void {
	harness.surfaceClient.renderStore.applyFileDisplayPatchEvent({
		direction: 'serverWorkerToMain',
		kind: 'fileDisplayPatch',
		surface: 'fileView',
		epoch,
		sequence: 1,
		projectionRevision: epoch,
		patches: [
			{
				slice: 'fileTree',
				operation: 'reset',
				payload: { sourceGeneration: epoch, sourceId: `source-${epoch.toString()}` },
			},
		],
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	});
}
