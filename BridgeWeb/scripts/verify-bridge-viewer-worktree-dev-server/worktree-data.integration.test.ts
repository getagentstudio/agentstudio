import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { afterEach, describe, expect, test, vi } from 'vitest';

import { BridgeWebTestLaunch } from '../dev-server/bridge-web-test-launch.ts';

const repoRootPath = fileURLToPath(new URL('../../..', import.meta.url));
const execFileAsync = promisify(execFile);

describe('Bridge viewer typed product File worktree data', () => {
	let launch: BridgeWebTestLaunch | null = null;
	let bridgeDevelopmentServerWorktreeRootPath: string | null = null;
	const initialBackendOrigin = process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
	const initialDevServerUrl = process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];

	afterEach(async (): Promise<void> => {
		try {
			await launch?.dispose();
		} finally {
			launch = null;
			if (bridgeDevelopmentServerWorktreeRootPath !== null)
				await rm(bridgeDevelopmentServerWorktreeRootPath, { force: true, recursive: true });
			bridgeDevelopmentServerWorktreeRootPath = null;
			if (initialDevServerUrl === undefined) {
				delete process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
			} else {
				process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] = initialDevServerUrl;
			}
			if (initialBackendOrigin === undefined) {
				delete process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
			} else {
				process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = initialBackendOrigin;
			}
			vi.resetModules();
		}
	});

	test('opens typed File data and drains every verifier-owned metadata stream', async () => {
		// Arrange
		bridgeDevelopmentServerWorktreeRootPath = await mkdtemp(
			join(tmpdir(), 'bridge-worktree-data-fixture-'),
		);
		await writeFile(
			join(bridgeDevelopmentServerWorktreeRootPath, 'README.md'),
			'# Agent Studio\n\nDeterministic Bridge File integration fixture.\n',
		);
		await writeFile(
			join(bridgeDevelopmentServerWorktreeRootPath, 'fixture.txt'),
			'bounded fixture content\n',
		);
		// A coverage window and its certificate must cross credit boundaries;
		// a tiny inventory can arrive together and hide early coverage settlement.
		const fixtureRoot = bridgeDevelopmentServerWorktreeRootPath;
		await Promise.all(
			Array.from({ length: 300 }, (_, index) =>
				writeFile(join(fixtureRoot, `window-${index}.txt`), 'progressive inventory\n'),
			),
		);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, ['init', '--initial-branch=main']);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'config',
			'user.name',
			'Bridge Worktree Data Integration',
		]);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'config',
			'user.email',
			'bridge-worktree-data@example.invalid',
		]);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, ['add', '--all']);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'fixture base',
		]);
		launch = await BridgeWebTestLaunch.start({
			backend: {
				initialTarget: 'HEAD',
				paneId: randomUUID(),
				repoRootPath,
				worktreeRoot: bridgeDevelopmentServerWorktreeRootPath,
			},
		});
		process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = launch.backend.origin;
		const viteServer = await launch.startViteChild({
			bridgeWebRootPath: fileURLToPath(new URL('../../', import.meta.url)),
			observeMetadataResponses: true,
		});
		const metadataResponses = launch.observeViteMetadataResponses(
			'verifier-owned metadata response close',
		);
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] =
			`${viteServer.startProof.origin}/?fixture=worktree&viewer=file&workers=on&scenario=current-worktree`;
		vi.resetModules();
		const worktreeData = await import('./worktree-data.js');

		// Act
		const surface = await worktreeData.fetchWorktreeSurface();
		const secondSurface = await worktreeData.fetchWorktreeSurface();
		const descriptor = await worktreeData.fetchFetchableWorktreeFileDescriptorForPath({
			path: 'README.md',
			surface: secondSurface,
		});
		const content = await worktreeData.fetchWorktreeFileContent(descriptor);
		await worktreeData.closeAllWorktreeFileSurfaces();
		const closedResponses = [await metadataResponses.next(), await metadataResponses.next()];
		metadataResponses.close();

		// Assert
		expect(surface.frames.at(-1)?.begin.mode).toBe('snapshot');
		expect(secondSurface.frames.at(-1)?.begin.mode).toBe('snapshot');
		expect(worktreeData.worktreeFileTreeRows(surface.frames).length).toBeGreaterThan(0);
		expect(worktreeData.openWorktreeFileSurfaceCount()).toBe(0);
		expect(metadataResponses.receivedCount).toBe(2);
		expect(
			closedResponses.map((fact) => fact.requestSequence).sort((left, right) => left - right),
		).toEqual([1, 2]);
		expect(closedResponses.every((fact) => fact.route.startsWith('/__bridge-product/stream'))).toBe(
			true,
		);
		expect(descriptor.availability.availabilityKind).toBe('available');
		expect(descriptor.contentHandle).toBe(
			descriptor.availability.availabilityKind === 'available'
				? descriptor.availability.contentDescriptor.descriptorId
				: '',
		);
		expect(content).toContain('Agent Studio');
	});
});

async function runFixtureGit(
	worktreeRootPath: string,
	arguments_: readonly string[],
): Promise<void> {
	await execFileAsync('git', ['-C', worktreeRootPath, ...arguments_]);
}
