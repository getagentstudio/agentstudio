import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { afterEach, describe, expect, test } from 'vitest';

import { installBridgeProductFileBatch } from '../../src/core/comm-worker/bridge-product-file-batch-installer.js';
import { BridgeWebTestLaunch } from '../dev-server/bridge-web-test-launch.ts';
import { BridgeVerifierProductFileSession } from './product-file-session.js';

const viteConfigFile = fileURLToPath(new URL('../../vite.config.ts', import.meta.url));
const repoRootPath = fileURLToPath(new URL('../../..', import.meta.url));
const execFileAsync = promisify(execFile);

describe('Bridge verifier product File session', () => {
	let launch: BridgeWebTestLaunch | null = null;
	let bridgeDevelopmentServerWorktreeRootPath: string | null = null;
	let currentPhase = 'notStarted';
	const initialBackendOrigin = process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];

	afterEach(async (): Promise<void> => {
		process.stderr.write(`[product-file-session] cleanup after phase=${currentPhase}\n`);
		try {
			await launch?.dispose();
		} finally {
			launch = null;
			if (bridgeDevelopmentServerWorktreeRootPath !== null)
				await rm(bridgeDevelopmentServerWorktreeRootPath, { force: true, recursive: true });
			bridgeDevelopmentServerWorktreeRootPath = null;
			if (initialBackendOrigin === undefined) {
				delete process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
			} else {
				process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = initialBackendOrigin;
			}
		}
	});

	test('proves source, tree, descriptor, content, cancellation, and stream closure through the typed carrier', async () => {
		// Arrange
		currentPhase = 'fixture.creating';
		bridgeDevelopmentServerWorktreeRootPath = await mkdtemp(
			join(tmpdir(), 'bridge-product-file-worktree-'),
		);
		await writeFile(
			join(bridgeDevelopmentServerWorktreeRootPath, 'README.md'),
			'# Agent Studio\n\nDeterministic product File session fixture.\n',
		);
		await writeFile(
			join(bridgeDevelopmentServerWorktreeRootPath, 'fixture.txt'),
			'bounded fixture content\n',
		);
		currentPhase = 'fixture.gitPreparing';
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, ['init', '--initial-branch=main']);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'config',
			'user.name',
			'Bridge Product File Integration',
		]);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'config',
			'user.email',
			'bridge-product-file@example.invalid',
		]);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, ['add', '--all']);
		await runFixtureGit(bridgeDevelopmentServerWorktreeRootPath, [
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'fixture base',
		]);
		currentPhase = 'backend.starting';
		launch = await BridgeWebTestLaunch.start({
			backend: {
				initialTarget: 'HEAD',
				paneId: randomUUID(),
				repoRootPath,
				worktreeRoot: bridgeDevelopmentServerWorktreeRootPath,
			},
		});
		process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = launch.backend.origin;
		let resolveMetadataStreamClosed: (() => void) | null = null;
		const metadataStreamClosed = new Promise<void>((resolve): void => {
			resolveMetadataStreamClosed = resolve;
		});
		currentPhase = 'vite.creating';
		const viteServer = await launch.startVite({
			configFile: viteConfigFile,
			logLevel: 'silent',
			plugins: [
				{
					configureServer(server): void {
						server.middlewares.use((request, response, next): void => {
							if (request.url?.startsWith('/__bridge-product/stream') === true) {
								response.once('close', (): void => resolveMetadataStreamClosed?.());
							}
							next();
						});
					},
					enforce: 'pre',
					name: 'bridge-verifier-product-file-session-close-observer',
				},
			],
			server: { host: '127.0.0.1', port: 0, strictPort: false },
		});
		currentPhase = 'vite.listening';
		const address = viteServer.httpServer?.address();
		if (address === undefined || address === null || typeof address === 'string') {
			throw new Error('Expected a live Vite TCP address.');
		}
		const session = new BridgeVerifierProductFileSession({
			baseUrl: `http://127.0.0.1:${address.port}`,
			scenarioName: 'current-worktree',
		});

		// Act
		currentPhase = 'source.opening';
		const source = await session.open();
		const initialInstallation = source.installations.at(-1);
		if (initialInstallation === undefined) throw new Error('Expected a certified File snapshot.');
		const initialView = installBridgeProductFileBatch(initialInstallation);
		const targetPath = initialView.displayTreeRows.find(
			(row) => row.path === 'README.md' && !row.isDirectory,
		)?.path;
		if (targetPath === undefined) throw new Error('Expected README.md in the product File tree.');
		const secondTargetPath = initialView.displayTreeRows.find(
			(row) => row.path !== targetPath && !row.isDirectory,
		)?.path;
		if (secondTargetPath === undefined) {
			throw new Error('Expected a second file in the product File tree.');
		}
		currentPhase = 'descriptor.first';
		const descriptor = await session.demandDescriptor(targetPath);
		currentPhase = 'descriptor.second';
		const secondDescriptor = await session.demandDescriptor(secondTargetPath);
		currentPhase = 'descriptor.repeated';
		const repeatedDescriptor = await session.demandDescriptor(targetPath);
		currentPhase = 'content.initial';
		const content = await session.openContent(descriptor);
		currentPhase = 'file.mutating';
		await writeFile(
			join(bridgeDevelopmentServerWorktreeRootPath, 'README.md'),
			'# Agent Studio\n\nUpdated through the live development backend.\n',
		);
		if (descriptor.availability.availabilityKind !== 'available') {
			throw new Error('Expected the original README descriptor to be available.');
		}
		currentPhase = 'refresh.waiting';
		const refresh = await session.waitForRefresh(
			targetPath,
			descriptor.availability.contentDescriptor.descriptorId,
		);
		currentPhase = 'content.replacement';
		const replacementContent = await session.openContent(refresh.descriptor);
		if (refresh.descriptor.availability.availabilityKind !== 'available') {
			throw new Error('Expected the replacement README descriptor to be available.');
		}
		currentPhase = 'session.closing';
		await session.close();
		currentPhase = 'metadataStream.waitingClosed';
		await metadataStreamClosed;

		// Assert
		currentPhase = 'assertions';
		expect(source.acceptedStreamSequence).toBe(0);
		expect(initialView.memberStatus.source.sourceId).toBe(source.sourceIdentity.sourceId);
		expect(initialInstallation.begin.mode).toBe('snapshot');
		expect(initialView.displayTreeRows.length).toBeGreaterThan(0);
		expect(descriptor.path).toBe(targetPath);
		expect(descriptor.availability.availabilityKind).toBe('available');
		expect(secondDescriptor.path).toBe(secondTargetPath);
		expect(repeatedDescriptor).toBe(descriptor);
		expect(content.byteLength).toBeGreaterThan(0);
		expect(new TextDecoder().decode(content.bytes)).toContain('Agent Studio');
		expect(refresh.previousDescriptorId).toBe(
			descriptor.availability.contentDescriptor.descriptorId,
		);
		expect(refresh.descriptor.availability.contentDescriptor.descriptorId).not.toBe(
			refresh.previousDescriptorId,
		);
		expect(refresh.status.unstaged).toBe(1);
		expect(new TextDecoder().decode(replacementContent.bytes)).toContain(
			'Updated through the live development backend.',
		);
		expect(session.state).toBe('closed');
	});
});

async function runFixtureGit(
	worktreeRootPath: string,
	arguments_: readonly string[],
): Promise<void> {
	await execFileAsync('git', ['-C', worktreeRootPath, ...arguments_]);
}
