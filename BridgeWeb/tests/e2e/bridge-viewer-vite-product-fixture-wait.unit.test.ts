import { writeFile } from 'node:fs/promises';

import { expect, test, vi } from 'vitest';

import { runWithBridgeWebLaunchScope } from '../../scripts/dev-server/bridge-web-test-launch-scope.ts';
import type { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { createBridgeViewerViteProductFixture } from './bridge-viewer-vite-product-fixture.ts';

vi.mock('node:fs/promises', async (importOriginal) => {
	const actual = await importOriginal<typeof import('node:fs/promises')>();
	return { ...actual, writeFile: vi.fn(actual.writeFile) };
});

test('names held product fixture preparation and inherits the test owner signal', async () => {
	const actual = await vi.importActual<typeof import('node:fs/promises')>('node:fs/promises');
	const entered = makeDeferred<void>();
	const release = makeDeferred<void>();
	const owner = new AbortController();
	const launches: BridgeWebTestLaunch[] = [];
	vi.mocked(writeFile).mockImplementationOnce(
		async (...arguments_: Parameters<typeof writeFile>): Promise<void> => {
			entered.resolve();
			await release.promise;
			await actual.writeFile(...arguments_);
		},
	);
	const preparation = handleLaunchPromise(
		runWithBridgeWebLaunchScope(
			{
				signal: owner.signal,
				ownLaunch: (launch): void => {
					if (!launches.includes(launch)) launches.push(launch);
				},
			},
			async () => await createBridgeViewerViteProductFixture(),
		),
		'held actual product fixture',
	);
	try {
		await entered.promise;
		expect(launches).toHaveLength(1);
		expect(launches[0]?.signal).toBe(owner.signal);
		expect(launches[0]?.pendingSteps).toContain('prepare disposable live-worktree product fixture');
		release.resolve();
		const fixture = await preparation.value();
		expect(fixture.oracle.changedPaths).toHaveLength(16);
		expect(launches[0]?.pendingSteps).not.toContain(
			'prepare disposable live-worktree product fixture',
		);
		await fixture.dispose();
		console.log(
			'TQ86_OWNER_PROOF pending=fixture-preparation signal=test-owner release=real-fixture-ready',
		);
	} finally {
		release.resolve();
		const outcome = await preparation.settled;
		if (outcome.kind === 'succeeded') await outcome.value.dispose();
		await Promise.all(
			launches.map(async (launch): Promise<void> => {
				await launch.dispose();
			}),
		);
		vi.mocked(writeFile).mockReset();
	}
});
