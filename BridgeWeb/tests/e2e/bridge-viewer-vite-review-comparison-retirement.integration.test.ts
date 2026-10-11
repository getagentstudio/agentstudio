import { access } from 'node:fs/promises';

import type { Browser } from 'playwright';
import { expect, test, vi } from 'vitest';

import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { createOwnedVerifierJourneyDeadline } from '../../scripts/verify-bridge-viewer-worktree-dev-server/verifier-journey-deadline.ts';
import * as browserHelper from './bridge-viewer-vite-e2e-browser.ts';
import * as productFixture from './bridge-viewer-vite-product-fixture.ts';
import BridgeWebE2ERunner from './bridge-web-e2e-runner.ts';
import type { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

type ControlledE2EContext = Parameters<typeof runBridgeWebE2ETestBody>[0];

test('the active Review round-trip body joins its held fixture cleanup after backend abort', async (context) => {
	let registeredBody: ((context: ControlledE2EContext) => Promise<void>) | undefined;
	// Capture the active test registration, without changing its body or adding a
	// probe-only body join. Invoke the runner boundary that dispatches the next test.
	vi.doMock('vitest', async () => ({
		...(await vi.importActual<typeof import('vitest')>('vitest')),
		test: (_name: string, body: (context: ControlledE2EContext) => Promise<void>): void => {
			registeredBody = body;
		},
	}));
	await import('./bridge-viewer-vite-review-comparison-round-trip.e2e.test.ts');
	vi.doUnmock('vitest');
	if (registeredBody === undefined)
		throw new Error('Active round-trip test body was not registered');
	const nativeCreateFixture = productFixture.createBridgeViewerViteProductFixture;
	let fixture: Awaited<ReturnType<typeof nativeCreateFixture>> | undefined;
	const browserAcquiring = makeDeferred<void>();
	const cleanupEntered = makeDeferred<void>();
	const cleanupRelease = makeDeferred<void>();
	let cleanupFinished = false;
	let nextTestEntered = false;
	let expire: () => void = (): void => {
		throw new Error('Bound not scheduled');
	};
	const deadline = createOwnedVerifierJourneyDeadline(
		{
			pendingSteps: (): readonly string[] => ['round-trip browser acquisition'],
			closePages: async (): Promise<void> => {},
		},
		{
			schedule: (onExpiry): (() => void) => {
				expire = onExpiry;
				return (): void => {};
			},
		},
	);
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const createFixture = vi
		.spyOn(productFixture, 'createBridgeViewerViteProductFixture')
		.mockImplementation(async (options) => {
			const realFixture = await nativeCreateFixture(options);
			fixture = {
				...realFixture,
				dispose: async (): Promise<void> => {
					cleanupEntered.resolve();
					await cleanupRelease.promise;
					await realFixture.dispose();
					cleanupFinished = true;
				},
			};
			return fixture;
		});
	const browserLaunch = vi
		.spyOn(browserHelper, 'launchBridgeViewerE2EChromium')
		.mockImplementation(async ({ testSignal }): Promise<Browser> => {
			browserAcquiring.resolve();
			return await new Promise<never>((_resolve, reject): void => {
				testSignal.addEventListener('abort', (): void => reject(testSignal.reason), { once: true });
			});
		});
	const rawBody = handleLaunchPromise(
		registeredBody({ signal: deadline.signal, task: context.task }),
		'active round-trip body',
	);
	try {
		await browserAcquiring.promise; // Real fixture, Swift and Vite startup completed.
		expire();
		const boundary = handleLaunchPromise(
			BridgeWebE2ERunner.prototype
				.onTaskFinished({ id: context.task.id, result: { state: 'fail' } })
				.finally((): void => {
					nextTestEntered = true;
				}),
			'active round-trip runner boundary',
		);
		await cleanupEntered.promise;
		expect(nextTestEntered).toBe(false);
		expect(cleanupFinished).toBe(false);
		cleanupRelease.resolve();
		await expect(boundary.value()).rejects.toThrow('round-trip browser acquisition');
		expect(cleanupFinished).toBe(true);
		expect(nextTestEntered).toBe(true);
		expect(fixture?.oracle.testLaunch.cleanup.dataRootRemoved).toBe(true);
		if (fixture === undefined) throw new Error('Real round-trip fixture missing');
		await expect(access(fixture.oracle.worktreeRoot)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		cleanupRelease.resolve();
		await rawBody.settled;
		await fixture?.dispose();
		await deadline.dispose();
		createFixture.mockRestore();
		browserLaunch.mockRestore();
		stderr.mockRestore();
	}
});
