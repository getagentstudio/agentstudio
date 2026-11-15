import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

import { expect, test } from 'vitest';

import {
	createStuckChromiumFixture,
	ownNodeFixture,
	requireProcessAlive,
} from './bridge-web-chromium-test-support.ts';

test('harness death ends the real host and its already-spawned stuck browser', async (context) => {
	const stub = await createStuckChromiumFixture();
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	const driver = spawn(
		process.execPath,
		[
			'--experimental-strip-types',
			fileURLToPath(new URL('./bridge-web-chromium-harness.fixture.ts', import.meta.url)),
		],
		{
			env: { ...process.env, BRIDGE_STUB_BROWSER: stub.executablePath },
			stdio: ['pipe', 'pipe', 'pipe', 'pipe'],
		},
	);
	let output = '';
	driver.stdout.on('data', (chunk: Buffer): void => {
		output += String(chunk);
	});
	driver.stderr.on('data', (chunk: Buffer): void => {
		output += String(chunk);
	});
	const exited = new Promise<void>((resolve, reject): void => {
		driver.once('exit', (): void => resolve());
		driver.once('error', reject);
	});
	const witness = driver.stdio[3];
	if (witness === null || witness === undefined || !('read' in witness))
		throw new Error('Missing host exit witness');
	const hostExited = once(witness, 'end');
	witness.resume();
	const abort = (): void => {
		driver.kill('SIGKILL');
		void stub.reap();
	};
	context.signal.addEventListener('abort', abort, { once: true });
	try {
		await Promise.race([
			stub.ready,
			exited.then((): never => {
				throw new Error(`driver exited before stub ready: ${output}`);
			}),
		]);
		await decoy.ready;
		expect(output).toMatch(/HOST \d+/u);
		driver.kill('SIGKILL');
		await exited;
		await stub.eof;
		await hostExited;
		const hostPid = Number(output.match(/HOST (\d+)/u)?.[1]);
		expect(hostPid).toBeGreaterThan(0);
		process.stdout.write(`CHROMIUM_PARENT_DEATH hostExited=${hostPid} browserFIFO=EOF\n`);
		requireProcessAlive(decoy.child.pid);
	} finally {
		context.signal.removeEventListener('abort', abort);
		driver.kill('SIGKILL');
		await exited;
		await stub.reap();
		await hostExited;
		await decoy.reap();
	}
});
