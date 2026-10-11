import { mkdir, readFile, rmdir, unlink, utimes, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import { createBridgeProductDeferred } from '../src/core/comm-worker/bridge-product-async-queue.js';
import { withBridgeWebAppBuildLock } from './build-app-assets-lock.ts';

const buildLockParentDirectoryPath = new URL('../../tmp/bridge-web-assets/', import.meta.url);
const buildLockDirectoryPath = join(buildLockParentDirectoryPath.pathname, 'build-app-assets.lock');
const buildLockOwnerFilePath = join(buildLockDirectoryPath, 'owner.json');
const staleLockTimestamp = new Date(Date.now() - 121_000);

describe('BridgeWeb app asset build lock', () => {
	beforeEach(async () => {
		await removeTestLockDirectory();
	});

	afterEach(async () => {
		vi.useRealTimers();
		await removeTestLockDirectory();
	});

	test('recovers a lock left behind by a dead owner process', async () => {
		await mkdir(buildLockDirectoryPath, { recursive: true });
		await writeFile(
			buildLockOwnerFilePath,
			JSON.stringify({
				pid: 2_147_483_647,
				acquiredAtMilliseconds: Date.now() - 10_000,
				token: 'abandoned-test-owner',
			}),
		);

		await expectBuildLockRecovery();
	});

	test('recovers a stale ownerless lock directory', async () => {
		await mkdir(buildLockDirectoryPath, { recursive: true });
		await utimes(buildLockDirectoryPath, staleLockTimestamp, staleLockTimestamp);

		await expectBuildLockRecovery();
	});

	test('reports the production lock deadline before the runner bound for a live owner', async (): Promise<void> => {
		await mkdir(buildLockDirectoryPath, { recursive: true });
		await writeFile(
			buildLockOwnerFilePath,
			JSON.stringify({
				pid: process.pid,
				acquiredAtMilliseconds: Date.now(),
				token: 'live-test-owner',
			}),
		);
		const startedAt = Date.now();
		const clock = vi
			.spyOn(Date, 'now')
			.mockReturnValueOnce(startedAt)
			.mockReturnValue(startedAt + 120_001);
		try {
			await expect(withBridgeWebAppBuildLock(async (): Promise<void> => {})).rejects.toThrow(
				'Timed out waiting for BridgeWeb app asset build lock:',
			);
		} finally {
			clock.mockRestore();
		}
	});

	test('harness guard follows a held critical section through release instead of a timer', async () => {
		vi.useFakeTimers();
		const criticalSectionEntered = createBridgeProductDeferred<void>();
		const releaseCriticalSection = createBridgeProductDeferred<void>();
		const recoveryOutcome = expectBuildLockRecovery(async (): Promise<void> => {
			criticalSectionEntered.resolve();
			await releaseCriticalSection.promise;
		}).then(
			(): null => null,
			(error: unknown): unknown => error,
		);
		try {
			await criticalSectionEntered.promise;
			// Drive the former oracle's timer while the lock owner is explicitly held.
			await vi.advanceTimersByTimeAsync(1_000);
		} finally {
			releaseCriticalSection.resolve();
		}
		expect(await recoveryOutcome).toBeNull();
	});
});

async function expectBuildLockRecovery(
	runCriticalSection: () => Promise<void> = async (): Promise<void> => {},
): Promise<void> {
	let didEnterCriticalSection = false;
	const buildLockPromise = withBridgeWebAppBuildLock(async (): Promise<void> => {
		didEnterCriticalSection = true;
		await runCriticalSection();
	});
	const outcomeClock = Date.now();
	// Time is controlled input to the production failure branch, not a test verdict.
	// A failed reap must throw the lock owner's named error before the equal runner bound.
	const deadlineClock = vi
		.spyOn(Date, 'now')
		.mockReturnValueOnce(outcomeClock)
		.mockReturnValue(outcomeClock + 120_001);
	try {
		await buildLockPromise;
	} finally {
		deadlineClock.mockRestore();
	}
	expect(didEnterCriticalSection).toBe(true);
	await expect(readFile(buildLockOwnerFilePath)).rejects.toMatchObject({ code: 'ENOENT' });
}

async function removeTestLockDirectory(): Promise<void> {
	await unlink(buildLockOwnerFilePath).catch(ignoreMissingPath);
	await rmdir(buildLockDirectoryPath).catch(ignoreMissingPath);
}

function ignoreMissingPath(error: unknown): void {
	if (!isNodeErrorWithCode(error, 'ENOENT')) {
		throw error;
	}
}

function isNodeErrorWithCode(error: unknown, code: string): boolean {
	return (
		typeof error === 'object' &&
		error !== null &&
		'code' in error &&
		(error as { readonly code?: unknown }).code === code
	);
}
