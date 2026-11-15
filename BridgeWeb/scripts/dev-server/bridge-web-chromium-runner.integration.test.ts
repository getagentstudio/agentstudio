import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { expect, test } from 'vitest';

import { ownNodeFixture, requireProcessAlive } from './bridge-web-chromium-test-support.ts';

test('isolated Vitest retires stuck acquisition and naturally advances to its next test', async (context) => {
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	const root = fileURLToPath(new URL('../../', import.meta.url));
	const driver = spawn(
		process.execPath,
		[
			'node_modules/vitest/vitest.mjs',
			'run',
			'--config',
			'tests/e2e/chromium-acquisition.fixture.config.ts',
		],
		{ cwd: root, detached: true, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] },
	);
	let output = '';
	const observeOutput = (chunk: Buffer): void => {
		output += chunk.toString();
	};
	driver.stdout.on('data', observeOutput);
	driver.stderr.on('data', observeOutput);
	let driverHasExited = false;
	// close includes the output pipes: proof markers cannot still be in flight.
	const exited = new Promise<number | null>((resolve, reject): void => {
		driver.once('close', (code): void => {
			driverHasExited = true;
			resolve(code);
		});
		driver.once('error', reject);
	});
	const rescueOwnedProcesses = (): void => {
		if (!driverHasExited && driver.pid !== undefined) process.kill(-driver.pid, 'SIGKILL');
		const browserPid = /CHROMIUM_STUB_READY pid=(\d+)/u.exec(output)?.[1];
		if (browserPid === undefined) return;
		try {
			process.kill(-Number(browserPid), 'SIGKILL');
		} catch (error: unknown) {
			if (!(error instanceof Error && 'code' in error && error.code === 'ESRCH')) throw error;
		}
	};
	context.signal.addEventListener('abort', rescueOwnedProcesses, { once: true });
	try {
		await decoy.ready;
		const code = await exited;
		context.signal.throwIfAborted();
		process.stdout.write(output);
		expect(output).toContain('CHROMIUM_STUB_READY');
		expect(output).toContain('CHROMIUM_FIXTURE_FAILURE_AFTER_READY');
		expect(output).toContain(
			'CHROMIUM_RUNNER_RETIRED acquisition=settled stubFIFO=EOF rootRemoved=true',
		);
		expect(output).toContain('CHROMIUM_NEXT_TEST_RAN');
		expect(output).not.toContain('Test timed out');
		expect(code).toBe(1);
		requireProcessAlive(decoy.child.pid);
	} finally {
		context.signal.removeEventListener('abort', rescueOwnedProcesses);
		rescueOwnedProcesses();
		await exited;
		await decoy.reap();
	}
});
