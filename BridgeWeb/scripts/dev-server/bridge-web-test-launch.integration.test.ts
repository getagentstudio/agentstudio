import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { access, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { expect, test } from 'vitest';

import { BridgeVerifierProductFileSession } from '../verify-bridge-viewer-worktree-dev-server/product-file-session.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise, type HandledLaunchPromise } from './handled-launch-promise.ts';

const bridgeWebRootPath = fileURLToPath(new URL('../../', import.meta.url));
const driver = `import { createServer } from 'vite';
const loader = await createServer({ configFile: false, optimizeDeps: { noDiscovery: true }, server: { hmr: false, middlewareMode: true } });
try { const fixture = await loader.ssrLoadModule('/scripts/dev-server/bridge-web-test-launch-process.test-support.ts'); await fixture.runLaunchProcessFixture(); }
catch (error) { process.stderr.write(String(error) + '\\n'); process.exitCode = 1; }
finally { await loader.close(); }`;

function startFixture(mode: string): {
	readonly child: ReturnType<typeof spawn>;
	readonly ready: Promise<{ readonly dataRootPath: string; readonly backendPid: number }>;
	readonly exit: ReturnType<typeof handleLaunchPromise<readonly unknown[]>>;
	readonly stderr: () => string;
} {
	const child = spawn(process.execPath, ['--input-type=module', '--eval', driver], {
		cwd: bridgeWebRootPath,
		env: {
			...process.env,
			BRIDGE_TEST_LAUNCH_FIXTURE_MODE: mode,
			NODE_OPTIONS:
				mode === 'unhandled-strict'
					? '--unhandled-rejections=strict'
					: '--unhandled-rejections=throw',
		},
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	if (child.stdout === null || child.stderr === null) throw new Error('Fixture pipes missing.');
	const exit = handleLaunchPromise(once(child, 'close'), 'harness process and pipe closure');
	let stderr = '';
	child.stderr.setEncoding('utf8');
	child.stderr.on('data', (chunk: string): void => {
		stderr += chunk;
	});
	const lines = createInterface({ input: child.stdout });
	const ready = new Promise<{ readonly dataRootPath: string; readonly backendPid: number }>(
		(resolve, reject): void => {
			lines.on('line', (line): void => {
				let value: unknown;
				try {
					value = JSON.parse(line);
				} catch {
					return;
				}
				if (
					typeof value === 'object' &&
					value !== null &&
					'event' in value &&
					value.event === 'ready' &&
					'dataRootPath' in value &&
					typeof value.dataRootPath === 'string' &&
					'backendPid' in value &&
					typeof value.backendPid === 'number'
				)
					resolve({ dataRootPath: value.dataRootPath, backendPid: value.backendPid });
			});
			void exit.settled.then((): void =>
				reject(new Error(`Harness exited before readiness: ${stderr}`)),
			);
		},
	);
	return { child, exit, ready, stderr: (): string => stderr };
}

test('unsafe startup promise bypasses finally in the negative control', async () => {
	const fixture = startFixture('unsafe-startup-control');
	const ready = await fixture.ready;
	try {
		const [code] = await fixture.exit.value();
		expect(code).toBe(1);
		expect(fixture.stderr()).toContain('unsafe early startup promise');
		await expect(access(ready.dataRootPath)).resolves.toBeUndefined();
	} finally {
		fixture.child.kill('SIGKILL');
		await fixture.exit.settled;
		await rm(ready.dataRootPath, { recursive: true, force: true });
	}
});

test.each([
	'startup-rejection',
	'swift-startup-rejection',
	'unhandled-rejection',
	'unhandled-strict',
	'SIGTERM',
	'SIGINT',
] as const)('%s stops the owned child and removes its data root', async (mode) => {
	const fixture = startFixture(mode);
	let ready: Awaited<typeof fixture.ready> | null = null;
	try {
		ready = await fixture.ready;
		if (mode === 'SIGTERM' || mode === 'SIGINT') fixture.child.kill(mode);
		const [code] = await fixture.exit.value();
		expect(code).toBe(mode === 'SIGINT' ? 130 : mode === 'SIGTERM' ? 143 : 1);
		await expect(access(ready.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
		const backendPid = ready.backendPid;
		expect(() => process.kill(backendPid, 0)).toThrow();
		if (mode === 'startup-rejection' || mode === 'swift-startup-rejection')
			expect(fixture.stderr()).toContain('File metadata startup');
		if (mode === 'unhandled-rejection' || mode === 'unhandled-strict')
			expect(fixture.stderr()).toContain('injected unhandled startup step');
	} finally {
		fixture.child.kill('SIGKILL');
		await fixture.exit.settled;
		if (ready !== null) await rm(ready.dataRootPath, { recursive: true, force: true });
	}
});

test.each(['swift-parent-kill', 'vite-parent-kill'] as const)(
	'SIGKILL of the harness closes stdin and its child exits: %s',
	async (mode) => {
		const fixture = startFixture(mode);
		let ready: Awaited<typeof fixture.ready> | null = null;
		let observer: ReturnType<typeof spawn> | null = null;
		let observerExit: HandledLaunchPromise<readonly unknown[]> | null = null;
		try {
			ready = await fixture.ready;
			// kqueue observes this exact PID's exit. Registration is acknowledged
			// before SIGKILL; neither correctness nor the wait uses a time budget.
			observer = spawn(
				'/usr/bin/python3',
				[
					'-u',
					'-c',
					`import select, sys
queue = select.kqueue()
queue.control([select.kevent(int(sys.argv[1]), filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE, fflags=select.KQ_NOTE_EXIT)], 0)
print('registered', flush=True)
queue.control([], 1, None)
print('exited', flush=True)
`,
					String(ready.backendPid),
				],
				{ stdio: ['ignore', 'pipe', 'pipe'] },
			);
			if (observer.stdout === null) throw new Error('Exit observer pipe missing.');
			const observed = handleLaunchPromise(
				once(observer, 'close'),
				'owned child NOTE_EXIT observer',
			);
			observerExit = observed;
			await Promise.race([
				once(observer.stdout, 'data'),
				observed.settled.then((): never => {
					throw new Error('Exit observer ended before registration.');
				}),
			]);
			fixture.child.kill('SIGKILL');
			const [code] = await observed.value();
			expect(code).toBe(0);
		} finally {
			fixture.child.kill('SIGKILL');
			observer?.kill('SIGTERM');
			await observerExit?.settled;
			await fixture.exit.settled;
			if (ready !== null) await rm(ready.dataRootPath, { recursive: true, force: true });
		}
	},
);

test('a harness data read releases its client before the real page bootstraps', async () => {
	const worktreeRoot = await mkdtemp(join(tmpdir(), 'bridge-launch-handoff-worktree-'));
	const initialBackendOrigin = process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
	let launch: BridgeWebTestLaunch | null = null;
	try {
		const runGit = promisify(execFile);
		await writeFile(join(worktreeRoot, 'README.md'), '# Harness handoff fixture\n');
		await runGit('git', ['-C', worktreeRoot, 'init', '--initial-branch=main']);
		await runGit('git', ['-C', worktreeRoot, 'add', 'README.md']);
		await runGit('git', [
			'-C',
			worktreeRoot,
			'-c',
			'user.name=Harness Fixture',
			'-c',
			'user.email=harness@example.invalid',
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'handoff fixture',
		]);
		launch = await BridgeWebTestLaunch.start({
			backend: {
				initialTarget: 'HEAD',
				paneId: '00000000-0000-7000-8000-000000000002',
				repoRootPath: fileURLToPath(new URL('../../../', import.meta.url)),
				worktreeRoot,
			},
		});
		process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = launch.backend.origin;
		const vite = await launch.startVite({
			configFile: join(bridgeWebRootPath, 'vite.config.ts'),
			logLevel: 'silent',
		});
		const address = vite.httpServer?.address();
		if (address === undefined || address === null || typeof address === 'string')
			throw new Error('Vite address missing.');
		const origin = `http://127.0.0.1:${address.port}`;
		const browser = await launch.launchBrowser({ channel: 'chrome', headless: true });
		const page = await browser.newPage();
		page.setDefaultTimeout(0);
		page.setDefaultNavigationTimeout(0);
		const client = new BridgeVerifierProductFileSession({
			baseUrl: origin,
			scenarioName: 'current-worktree',
		});
		const source = await launch.readProductData(async (ownClient) => {
			ownClient(client);
			const opened = await client.open();
			await client.demandDescriptor('README.md');
			// Negative control at the real ownership layer: before release,
			// the page's different-tab initial bootstrap is refused.
			const overlap = await fetch(`${origin}/__bridge-product/bootstrap`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					reason: 'initial',
					tabId: 'harness-page-tab',
					navigationIntent: {
						commandId: 'open-file-view',
						commandKind: 'activateContext',
						surface: 'file',
					},
				}),
			});
			expect(overlap.status).toBe(409);
			return opened;
		});
		expect(source.installations.length).toBeGreaterThan(0);
		expect(client.state).toBe('closed');
		const bootstrap = handleLaunchPromise(
			page.waitForResponse(
				(response): boolean => new URL(response.url()).pathname === '/__bridge-product/bootstrap',
			),
			'page bootstrap response',
		);
		await page.goto(
			`${origin}/?fixture=worktree&viewer=file&workers=on&scenario=current-worktree`,
			{ waitUntil: 'domcontentloaded' },
		);
		expect((await bootstrap.value()).status()).toBe(200);
		await page.getByTestId('bridge-file-viewer-shell').waitFor({ state: 'visible' });
		expect(await page.getByTestId('bridge-dev-session-inactive').count()).toBe(0);
		await browser.close();
		expect(launch.cleanup.browserDisconnected).toBe(true);
		await expect(access(launch.dataRootPath)).resolves.toBeUndefined();
		expect((await fetch(`${origin}/__bridge-product/health`)).status).toBe(204);
	} finally {
		try {
			await launch?.dispose();
		} finally {
			if (initialBackendOrigin === undefined) delete process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'];
			else process.env['BRIDGE_WEB_DEV_BACKEND_ORIGIN'] = initialBackendOrigin;
			await rm(worktreeRoot, { recursive: true, force: true });
		}
	}
});
