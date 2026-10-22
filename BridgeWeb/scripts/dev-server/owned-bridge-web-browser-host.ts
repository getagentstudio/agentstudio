import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import type { LaunchOptions } from 'playwright';

import {
	stopOwnedBridgeDevelopmentServerProcess,
	type BridgeDevelopmentServerLifecycleOutcome,
	type OwnedBridgeDevelopmentServerCleanup,
} from './bridge-development-server-process.ts';
import {
	browserHostMessageSchema,
	type BrowserHostMessage,
} from './bridge-web-browser-host-protocol.ts';

export interface OwnedBridgeWebBrowserHost {
	readonly pid: number;
	readonly wsEndpoint: string;
	readonly stop: () => Promise<OwnedBridgeDevelopmentServerCleanup>;
	readonly whenExited: Promise<void>;
	readonly whenStopped: Promise<OwnedBridgeDevelopmentServerCleanup>;
	readonly stdoutTail: () => string;
	readonly stderrTail: () => string;
}

export async function startOwnedBridgeWebBrowserHost(
	props: {
		readonly options: LaunchOptions;
		readonly onSpawn?: (host: OwnedBridgeWebBrowserHost) => void;
	},
	dependencies?: {
		readonly spawnChild: () => ChildProcessWithoutNullStreams;
	},
): Promise<OwnedBridgeWebBrowserHost> {
	const child =
		dependencies?.spawnChild() ??
		spawn(
			process.execPath,
			[
				'--experimental-strip-types',
				fileURLToPath(new URL('./bridge-web-browser-host.ts', import.meta.url)),
				JSON.stringify(props.options),
			],
			{ stdio: ['pipe', 'pipe', 'pipe'] },
		);
	const lifecycle = new Promise<BridgeDevelopmentServerLifecycleOutcome>((resolve): void => {
		child.once('exit', (code, signal): void => resolve({ kind: 'exit', code, signal }));
		child.once('error', (error): void => resolve({ kind: 'spawn-error', error }));
	});
	type Readiness = Extract<BrowserHostMessage, { readonly kind: 'ready' | 'failed' }>;
	let resolveReadiness: (message: Readiness) => void = (): void => {};
	const readiness = new Promise<Readiness>((resolve): void => {
		resolveReadiness = resolve;
	});
	let resolveStopped: (cleanup: OwnedBridgeDevelopmentServerCleanup) => void = (): void => {};
	let rejectStopped: (error: unknown) => void = (): void => {};
	const stopped = new Promise<OwnedBridgeDevelopmentServerCleanup>((resolve, reject): void => {
		resolveStopped = resolve;
		rejectStopped = reject;
	});
	// Both promises are consumed by the race before any asynchronous child event.
	const browserGroups = new Set<number>();
	let partial = '';
	let stdoutTail = '';
	let stderrTail = '';
	let wsEndpoint = '';
	let stopPromise: Promise<OwnedBridgeDevelopmentServerCleanup> | undefined;
	child.stdout.setEncoding('utf8');
	child.stderr.setEncoding('utf8');
	child.stderr.on('data', (chunk: string): void => {
		stderrTail = `${stderrTail}${chunk}`.slice(-8192);
	});
	child.stdout.on('data', (chunk: string): void => {
		stdoutTail = `${stdoutTail}${chunk}`.slice(-8192);
		const lines = `${partial}${chunk}`.split('\n');
		partial = (lines.pop() ?? '').slice(-8192);
		for (const line of lines) {
			try {
				const message = browserHostMessageSchema.parse(JSON.parse(line));
				if (message.kind === 'browserSpawned') browserGroups.add(message.pid);
				else resolveReadiness(message);
			} catch (error: unknown) {
				resolveReadiness({
					kind: 'failed',
					message: `Invalid browser host announcement: ${String(error)}`,
				});
			}
		}
	});
	const host: OwnedBridgeWebBrowserHost = {
		pid: child.pid ?? 0,
		get wsEndpoint(): string {
			return wsEndpoint;
		},
		stdoutTail: (): string => stdoutTail,
		stderrTail: (): string => stderrTail,
		whenExited: lifecycle.then((): void => {}),
		whenStopped: stopped,
		stop: async (): Promise<OwnedBridgeDevelopmentServerCleanup> => {
			stopPromise ??= stopOwnedBridgeDevelopmentServerProcess(child, lifecycle, () => [
				...browserGroups,
			]);
			void stopPromise.then(resolveStopped, rejectStopped);
			return await stopPromise;
		},
	};
	const acquisition = Promise.race([
		readiness.then((message) => ({ kind: 'announcement' as const, message })),
		lifecycle.then((outcome) => ({ kind: 'lifecycle' as const, outcome })),
		stopped.then((cleanup) => ({ kind: 'stopped' as const, cleanup })),
	]);
	try {
		props.onSpawn?.(host);
		const outcome = await acquisition;
		if (outcome.kind === 'stopped')
			throw new Error(
				outcome.cleanup.ownedProcessAliveAfterStop
					? 'host alive after stop'
					: 'browser host stopped before readiness',
			);
		if (outcome.kind === 'lifecycle') {
			if (outcome.outcome.kind === 'spawn-error')
				throw new Error(`Browser host failed to spawn: ${outcome.outcome.error.message}`, {
					cause: outcome.outcome.error,
				});
			throw new Error(
				`Browser host exited before readiness: ${JSON.stringify(outcome.outcome)}; ${stderrTail}`,
			);
		}
		if (outcome.message.kind === 'failed')
			throw new Error(`Browser host launch failed: ${outcome.message.message}`);
		wsEndpoint = outcome.message.wsEndpoint;
		return host;
	} catch (error: unknown) {
		await host.stop();
		throw error;
	}
}
