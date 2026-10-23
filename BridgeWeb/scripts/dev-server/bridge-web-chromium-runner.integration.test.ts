import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { expect, test } from 'vitest';

import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import {
	createStuckChromiumFixture,
	ownNodeFixture,
	requireProcessAlive,
} from './bridge-web-chromium-test-support.ts';

test('isolated Vitest retires stuck acquisition and naturally advances to its next test', async (context) => {
	const stub = await createStuckChromiumFixture();
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
		{
			cwd: root,
			detached: true,
			env: { ...process.env, BRIDGE_STUB_BROWSER: stub.executablePath },
			stdio: ['pipe', 'pipe', 'pipe'],
		},
	);
	const abortSeen = makeDeferred<void>();
	const nextSeen = makeDeferred<void>();
	let output = '';
	const observeOutput = (chunk: Buffer): void => {
		output += chunk.toString();
		if (/BRIDGE_E2E_ABORT.*Chromium acquisition/u.test(output)) abortSeen.resolve();
		if (output.includes('CHROMIUM_NEXT_TEST_RAN')) nextSeen.resolve();
	};
	driver.stdout.on('data', observeOutput);
	driver.stderr.on('data', observeOutput);
	let driverHasExited = false;
	const exited = new Promise<number | null>((resolve, reject): void => {
		driver.once('exit', (code): void => {
			driverHasExited = true;
			resolve(code);
		});
		driver.once('error', reject);
	});
	let naturallyExited = false;
	const forceAndReap = async (): Promise<void> => {
		process.stdout.write(
			`CHROMIUM_DRIVER_RED innerBoundFired=${/BRIDGE_E2E_ABORT.*Chromium acquisition/u.test(output)} retirementPending=${!naturallyExited && !output.includes('CHROMIUM_NEXT_TEST_RAN')}\n`,
		);
		const forceEnded = !driverHasExited && driver.pid !== undefined;
		if (forceEnded && driver.pid !== undefined) process.kill(-driver.pid, 'SIGKILL');
		await exited;
		process.stdout.write(`CHROMIUM_DRIVER_RED driverForceEnded=${forceEnded}\n`);
		await stub.reap();
		process.stdout.write('CHROMIUM_DRIVER_RED stubReapedByOuter=true\n');
		process.stdout.write(output);
	};
	let abortCleanup: Promise<void> | undefined;
	const onAbort = (): void => {
		abortCleanup = forceAndReap();
	};
	context.signal.addEventListener('abort', onAbort, { once: true });
	try {
		await Promise.race([
			stub.ready,
			exited.then((): never => {
				throw new Error(`driver exited before browser ready: ${output}`);
			}),
		]);
		process.stdout.write('CHROMIUM_DRIVER_GREEN stubReady=true\n');
		await decoy.ready;
		await Promise.race([
			abortSeen.promise,
			exited.then((): never => {
				throw new Error(`driver exited without acquisition abort: ${output}`);
			}),
		]);
		process.stdout.write('CHROMIUM_DRIVER_GREEN innerAbort=true\n');
		await stub.eof;
		process.stdout.write('CHROMIUM_DRIVER_GREEN stubFIFO=EOF\n');
		await Promise.race([
			nextSeen.promise,
			exited.then((): never => {
				throw new Error(`driver exited without continuation: ${output}`);
			}),
		]);
		process.stdout.write('CHROMIUM_DRIVER_GREEN nextTestRan=true\n');
		const code = await exited;
		naturallyExited = true;
		process.stdout.write(`CHROMIUM_DRIVER_GREEN naturalExit=${code}\n`);
		process.stdout.write(output);
		expect(output).toMatch(/BRIDGE_E2E_ABORT.*Chromium acquisition/u);
		expect(output).toContain('CHROMIUM_NEXT_TEST_RAN');
		expect(output).toContain('BridgeWeb launch aborted during Chromium acquisition');
		expect(code).toBe(1);
		requireProcessAlive(decoy.child.pid);
	} finally {
		context.signal.removeEventListener('abort', onAbort);
		if (abortCleanup !== undefined) await abortCleanup;
		else {
			if (!driverHasExited && driver.pid !== undefined) process.kill(-driver.pid, 'SIGKILL');
			await exited;
			await stub.reap();
		}
		await decoy.reap();
	}
});
