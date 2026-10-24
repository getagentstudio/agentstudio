import { ChildProcess } from 'node:child_process';
import { channel } from 'node:diagnostics_channel';

import type { BrowserServer } from 'playwright';
import { z } from 'zod';

import type { BrowserHostMessage } from './bridge-web-browser-host-protocol.ts';

const browserGroups = new Set<number>();
let browserServer: BrowserServer | undefined;
let stopping = false;

function announce(message: BrowserHostMessage): void {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

// Subscribe before importing Playwright: its synchronous spawn registration and
// exit hook own even a browser that never completes its protocol handshake.
channel('child_process').subscribe((message: unknown): void => {
	if (
		typeof message !== 'object' ||
		message === null ||
		!('process' in message) ||
		!(message.process instanceof ChildProcess)
	)
		return;
	const child = message.process;
	child.once('spawn', (): void => {
		if (child.pid === undefined) return;
		browserGroups.add(child.pid);
		announce({ kind: 'browserSpawned', pid: child.pid });
	});
});

async function stopHost(): Promise<void> {
	if (stopping) return;
	stopping = true;
	try {
		await browserServer?.kill();
	} finally {
		process.exit(0);
	}
}
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP'] as const)
	process.on(signal, (): void => {
		void stopHost();
	});

// A dead harness cannot supply escalation. End reported groups synchronously;
// process.exit also invokes Playwright's killSet for a not-yet-reported spawn.
process.stdin.resume();
process.stdin.once('end', (): void => {
	for (const group of browserGroups) {
		try {
			process.kill(-group, 'SIGKILL');
		} catch (error: unknown) {
			if (!(error instanceof Error && 'code' in error && error.code === 'ESRCH'))
				process.stderr.write(`Browser group ${group} kill failed: ${String(error)}\n`);
		}
	}
	process.exit(0);
});

try {
	const options = z.record(z.string(), z.unknown()).parse(JSON.parse(process.argv[2] ?? '{}'));
	const { chromium } = await import('playwright');
	browserServer = await chromium.launchServer({
		...options,
		timeout: 0,
		handleSIGTERM: false,
		handleSIGINT: false,
		handleSIGHUP: false,
	});
	announce({ kind: 'ready', wsEndpoint: browserServer.wsEndpoint() });
} catch (error: unknown) {
	const failure: BrowserHostMessage = {
		kind: 'failed',
		message: error instanceof Error ? error.message : String(error),
	};
	process.stdout.write(`${JSON.stringify(failure)}\n`, (): never => process.exit(1));
}
