import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { runCopyFileChurnReproduction } from './bridge-viewer-vite-copy-file-churn-journey.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';

test.for([
	'retire edited projection: false',
	'retire edited projection: true',
	'retire initial draft projection: true',
	'retire edited before file refresh: true',
])(
	'copies a current saved File annotation while the next real file refresh is pending (%s)',
	async (scenario, context) => {
		const retireEditedProjectionDuringRefresh =
			scenario === 'retire edited projection: true' ||
			scenario === 'retire edited before file refresh: true';
		const retireEditedBeforeFileRefresh = scenario === 'retire edited before file refresh: true';
		const retireInitialDraftProjectionDuringRefresh =
			scenario === 'retire initial draft projection: true';
		const fixture = await createBridgeViewerViteProductFixture();
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let primaryFailure: unknown = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const observations = await runCopyFileChurnReproduction({
				testSignal: context.signal,
				retireEditedProjectionDuringRefresh,
				retireEditedBeforeFileRefresh,
				retireInitialDraftProjectionDuringRefresh,
				oracle: fixture.oracle,
				server,
			});

			expect(observations.completedBurstCount).toBe(3);
			if (retireEditedProjectionDuringRefresh) {
				expect(observations.editedProjectionRetirement).not.toBeNull();
				const retirement = observations.editedProjectionRetirement;
				if (retirement !== null && retirement.retiredRequestFailure !== null) {
					expect(retirement.heldDescriptorId).toBeTypeOf('string');
					expect(retirement.retiredRequestFailure).toContain('ERR_ABORTED');
				}
				if (retireEditedBeforeFileRefresh) {
					expect(retirement?.atRetirement).toEqual({
						sourceRefreshRequestCount: 0,
						successorDescriptorIds: [],
					});
					expect(retirement?.retiredRequestFailure).toContain('ERR_ABORTED');
				}
			} else {
				expect(observations.editedProjectionRetirement).toBeNull();
			}
			if (retireInitialDraftProjectionDuringRefresh) {
				expect(observations.initialProjectionRetirement?.heldDescriptorId).toBeTypeOf('string');
				expect(observations.initialProjectionRetirement?.retiredRequestFailure).toContain(
					'ERR_ABORTED',
				);
				expect(
					observations.initialProjectionRetirement?.successorDescriptorIds.length,
				).toBeGreaterThan(0);
				expect(observations.initialProjectionRetirement?.sourceRefreshRequestCount).toBeGreaterThan(
					0,
				);
			} else {
				expect(observations.initialProjectionRetirement).toBeNull();
			}
			expect(observations.evidence.copyRefreshOverlap).toMatchObject({
				interceptedBeforeCopy: true,
				paintedBeforeCopy: false,
				releasedBy: 'output.scope.commit',
			});
			expect(observations.evidence.annotationOutcomes).toContainEqual({
				operationKind: 'draft.save',
				status: 'committed',
			});
			expect(observations.evidence.annotationOutcomes).toContainEqual({
				operationKind: 'output.scope.commit',
				status: 'output',
			});
			expect(observations.evidence.fileAnnotationOpens.length).toBeGreaterThan(0);
			// Within one worker, File annotations follow the File surface epoch forward; a
			// reopen at an older epoch is the stale-subscription failure this journey guards
			// against. A page reload starts a new worker whose epochs begin again.
			const openEpochsByWorker = new Map<string, number[]>();
			for (const open of observations.evidence.fileAnnotationOpens) {
				const epochs = openEpochsByWorker.get(open.workerInstanceId) ?? [];
				epochs.push(open.workerDerivationEpoch);
				openEpochsByWorker.set(open.workerInstanceId, epochs);
			}
			for (const epochs of openEpochsByWorker.values()) {
				expect(epochs).toEqual(epochs.toSorted((left, right) => left - right));
			}
			expect(observations.evidence.fileScopeUpdateCount).toBeGreaterThan(0);
			expect(observations.evidence.transportRequests).toContainEqual(
				expect.objectContaining({
					method: 'file.annotations.command',
					operationKind: 'output.scope.commit',
				}),
			);
		} catch (error: unknown) {
			primaryFailure = error;
			throw error;
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'Vite and Swift',
						run: async (): Promise<void> => {
							if (server === null) return;
							const cleanup = await server.stop();
							expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
							expect(cleanup.forcedTerminationRequired).toBe(false);
						},
					},
					{ name: 'fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure }),
			});
		}
	},
);
