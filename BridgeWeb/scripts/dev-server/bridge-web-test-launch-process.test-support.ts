import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

export async function runLaunchProcessFixture(): Promise<void> {
	const mode = process.env['BRIDGE_TEST_LAUNCH_FIXTURE_MODE'];
	if (mode === 'unsafe-startup-control') {
		const dataRootPath = await mkdtemp(join(tmpdir(), 'bridge-unsafe-startup-control-'));
		process.stdout.write(`${JSON.stringify({ event: 'ready', dataRootPath, backendPid: 0 })}\n`);
		try {
			// Negative control: reproduce the former create-early/await-late
			// timing promise under Node's actual unhandled-rejection behavior.
			const failure = Promise.reject(new Error('unsafe early startup promise'));
			process.stdin.resume();
			await once(process.stdin, 'end');
			await failure;
		} finally {
			await rm(dataRootPath, { recursive: true, force: true });
		}
		return;
	}
	const repoRootPath = fileURLToPath(new URL('../../../', import.meta.url));
	const backend = {
		initialTarget: 'HEAD',
		paneId: '00000000-0000-7000-8000-000000000002',
		repoRootPath,
		worktreeRoot: repoRootPath,
	};
	const launch =
		mode === 'swift-parent-kill'
			? await BridgeWebTestLaunch.start({ backend })
			: await BridgeWebTestLaunch.start(
					{ backend },
					{
						startBackend: async (props) => {
							const earlyFailure =
								mode === 'startup-rejection'
									? handleLaunchPromise(
											Promise.reject(new Error('injected File metadata startup step')),
											'File metadata startup',
										)
									: null;
							const child = spawn(
								process.execPath,
								[
									'--eval',
									"process.stdin.resume(); process.stdin.on('end', () => process.exit(0)); process.stdout.write('ready\\n');",
								],
								{ stdio: ['pipe', 'pipe', 'pipe'] },
							);
							const exited = new Promise<{
								readonly code: number | null;
								readonly signal: NodeJS.Signals | null;
							}>((resolve): void => {
								child.once('exit', (code, signal): void => resolve({ code, signal }));
							});
							const server = {
								origin: 'http://127.0.0.1:1',
								pid: child.pid ?? 0,
								stderrTail: (): string => '',
								stdoutTail: (): string => '',
								whenExited: exited.then((): void => {}),
								stop: async () => {
									child.stdin.end();
									const exit = await exited;
									return {
										exitCode: exit.code,
										exitSignal: exit.signal,
										forcedTerminationRequired: false,
										ownedProcessAliveAfterStop: false,
									};
								},
							};
							props.onSpawn?.(server);
							await Promise.race([
								once(child.stdout, 'data'),
								exited.then((): never => {
									throw new Error('fixture backend exited before readiness');
								}),
							]);
							if (mode !== 'vite-parent-kill')
								process.stdout.write(
									`${JSON.stringify({ event: 'ready', dataRootPath: props.dataRootPath, backendPid: server.pid })}\n`,
								);
							if (earlyFailure !== null) return await earlyFailure.value();
							return server;
						},
					},
				);
	if (mode === 'swift-parent-kill')
		process.stdout.write(
			`${JSON.stringify({ event: 'ready', dataRootPath: launch.dataRootPath, backendPid: launch.backend.pid })}\n`,
		);
	if (mode === 'vite-parent-kill') {
		const vite = await launch.startViteChild({
			bridgeWebRootPath: fileURLToPath(new URL('../../', import.meta.url)),
		});
		process.stdout.write(
			`${JSON.stringify({ event: 'ready', dataRootPath: launch.dataRootPath, backendPid: vite.startProof.pid })}\n`,
		);
	}
	if (mode === 'unhandled-rejection')
		void Promise.reject(new Error('injected unhandled startup step'));
	process.stdin.resume();
	try {
		await once(process.stdin, 'end');
	} finally {
		await launch.dispose();
	}
}
