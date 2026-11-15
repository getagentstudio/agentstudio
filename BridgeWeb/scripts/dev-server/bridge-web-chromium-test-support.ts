import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { closeSync, constants, createReadStream, openSync } from 'node:fs';
import { chmod, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function ownNodeFixture(source: string): {
	readonly child: ChildProcessWithoutNullStreams;
	readonly exited: Promise<void>;
	readonly ready: Promise<void>;
	readonly hasExited: () => boolean;
	readonly reap: () => Promise<void>;
} {
	const child = spawn(process.execPath, ['--eval', source], { stdio: ['pipe', 'pipe', 'pipe'] });
	let hasExited = false;
	const exited = new Promise<void>((resolve, reject): void => {
		child.once('exit', (): void => {
			hasExited = true;
			resolve();
		});
		child.once('error', reject);
	});
	const ready = Promise.race([
		once(child.stdout, 'data').then((): void => {}),
		exited.then((): never => {
			throw new Error('fixture exited before ready');
		}),
	]);
	return {
		child,
		exited,
		ready,
		hasExited: (): boolean => hasExited,
		reap: async (): Promise<void> => {
			child.kill('SIGKILL');
			await exited;
		},
	};
}

export async function createStuckChromiumFixture(): Promise<{
	readonly executablePath: string;
	readonly fifoPath: string;
	readonly hasEnded: () => boolean;
	readonly ready: Promise<number>;
	readonly eof: Promise<void>;
	readonly reap: () => Promise<void>;
}> {
	const root = await mkdtemp(join(tmpdir(), 'bridge-chromium-proof-'));
	const fifoPath = join(root, 'browser.fifo');
	const executablePath = join(root, 'stuck-browser');
	const mkfifo = spawn('/usr/bin/mkfifo', [fifoPath]);
	await once(mkfifo, 'exit');
	await writeFile(
		executablePath,
		`#!/usr/bin/env python3\nimport os\nwith open(${JSON.stringify(fifoPath)}, 'w') as receipt:\n receipt.write('ready %d\\n' % os.getpid())\n receipt.flush()\n while os.read(3, 65536):\n  pass\n import signal\n signal.pause()\n`,
	);
	await chmod(executablePath, 0o700);
	let resolveReady: (pid: number) => void = (): void => {};
	let rejectReady: (error: unknown) => void = (): void => {};
	const ready = new Promise<number>((resolve, reject): void => {
		resolveReady = resolve;
		rejectReady = reject;
	});
	let hasEnded = false;
	let resolveEof: () => void = (): void => {};
	let rejectEof: (error: unknown) => void = (): void => {};
	const eof = new Promise<void>((resolve, reject): void => {
		resolveEof = resolve;
		rejectEof = reject;
	});
	// Keep open/read cancellation bounded even if the browser never starts. Close
	// this setup writer on the real stub's acknowledgement; only its writer then
	// holds the FIFO open, so EOF observes its death.
	let setupWriter: number | undefined = openSync(fifoPath, constants.O_RDWR | constants.O_NONBLOCK);
	const closeSetupWriter = (): void => {
		if (setupWriter === undefined) return;
		closeSync(setupWriter);
		setupWriter = undefined;
	};
	const stream = createReadStream(fifoPath, { encoding: 'utf8' });
	await once(stream, 'open');
	let partial = '';
	let browserPid: number | undefined;
	let reaping: Promise<void> | undefined;
	stream.on('data', (chunk: string | Buffer): void => {
		partial += String(chunk);
		const match = /^ready (\d+)\n/u.exec(partial);
		if (match?.[1] !== undefined) {
			browserPid = Number(match[1]);
			closeSetupWriter();
			resolveReady(browserPid);
		}
	});
	stream.once('end', (): void => {
		hasEnded = true;
		resolveEof();
		rejectReady(new Error('stub EOF before ready'));
	});
	stream.once('error', (error): void => {
		rejectReady(error);
		rejectEof(error);
	});
	// Attach handlers before a caller can fail during setup.
	void ready.catch((): void => {});
	void eof.catch((): void => {});
	return {
		executablePath,
		fifoPath,
		hasEnded: (): boolean => hasEnded,
		ready: ready,
		eof: eof,
		reap: async (): Promise<void> => {
			reaping ??= (async (): Promise<void> => {
				if (browserPid !== undefined && !hasEnded) {
					try {
						process.kill(-browserPid, 'SIGKILL');
					} catch (error: unknown) {
						if (!(error instanceof Error && 'code' in error && error.code === 'ESRCH')) throw error;
					}
					await eof;
				}
				closeSetupWriter();
				stream.destroy();
				await rm(root, { recursive: true, force: true });
			})();
			await reaping;
		},
	};
}

export function requireProcessAlive(pid: number | undefined): void {
	if (pid === undefined) throw new Error('Missing owned fixture pid');
	process.kill(pid, 0);
}
