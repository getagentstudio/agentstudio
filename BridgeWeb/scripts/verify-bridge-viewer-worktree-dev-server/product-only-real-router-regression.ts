// Vite process adapter used only by the authoritative test-launch harness.
// Keep the frozen A5/A16 deadline at its existing ledger source home until
// its process-owner deadline contract is redesigned; the journey is in
// product-only-real-router-regression-runner.ts.
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { access } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { reserveLoopbackPort } from '../dev-server/reserve-loopback-port.ts';
const serverStartupTimeoutMilliseconds = 30_000;
const serverShutdownTimeoutMilliseconds = 10_000;
const maximumServerLogTailCharacters = 8_192;
export interface BridgeViewerViteServerStartProof {
	readonly origin: string;
	readonly pid: number;
	readonly version: string | null;
}
export interface BridgeViewerViteServerCleanupProof {
	readonly exitCode: number | null;
	readonly exitSignal: NodeJS.Signals | null;
	readonly exitedWithinTimeout: boolean;
	readonly forcedTerminationRequired: boolean;
	readonly ownedProcessAliveAfterStop: boolean;
	readonly pid: number | null;
}
export interface BridgeViewerOwnedViteProductServerCleanup {
	readonly exitCode: number | null;
	readonly exitObserved: boolean;
	readonly exitSignal: NodeJS.Signals | null;
	readonly forcedTerminationRequired: boolean;
	readonly ownedProcessAliveAfterStop: boolean;
}
interface ChildProcessExit {
	readonly code: number | null;
	readonly signal: NodeJS.Signals | null;
}
export class BridgeViewerOwnedViteServer {
	readonly #child: ChildProcessWithoutNullStreams;
	readonly #exitPromise: Promise<ChildProcessExit>;
	readonly stdoutTail: () => string;
	readonly stderrTail: () => string;
	#startProof: BridgeViewerViteServerStartProof;
	get startProof(): BridgeViewerViteServerStartProof {
		return this.#startProof;
	}

	private constructor(props: {
		readonly child: ChildProcessWithoutNullStreams;
		readonly stdoutTail: () => string;
		readonly stderrTail: () => string;
		readonly exitPromise: Promise<ChildProcessExit>;
		readonly startProof: BridgeViewerViteServerStartProof;
	}) {
		this.#child = props.child;
		this.stdoutTail = props.stdoutTail;
		this.stderrTail = props.stderrTail;
		this.#exitPromise = props.exitPromise;
		this.#startProof = props.startProof;
	}

	static async start(props: {
		readonly bridgeDevelopmentServerOrigin: string;
		readonly bridgeWebRootPath: string;
		readonly environment?: Readonly<Record<string, string>>;
		readonly onSpawn: (server: BridgeViewerOwnedViteServer) => void;
	}): Promise<BridgeViewerOwnedViteServer> {
		const viteCLIPath = join(props.bridgeWebRootPath, 'node_modules/vite/bin/vite.js');
		await access(viteCLIPath);
		const port = await reserveLoopbackPort();
		const child = spawn(
			process.execPath,
			[
				'--import',
				fileURLToPath(
					new URL('../dev-server/bridge-web-test-launch-vite-input-lifetime.ts', import.meta.url),
				),
				viteCLIPath,
				'--host',
				'127.0.0.1',
				'--port',
				String(port),
				'--strictPort',
			],
			{
				cwd: props.bridgeWebRootPath,
				env: {
					...process.env,
					BRIDGE_WEB_DEV_BACKEND_ORIGIN: props.bridgeDevelopmentServerOrigin,
					...props.environment,
				},
				stdio: ['pipe', 'pipe', 'pipe'],
			},
		);
		const exitPromise = new Promise<ChildProcessExit>((resolve): void => {
			child.once('exit', (code, signal): void => resolve({ code, signal }));
			child.once('error', (): void => resolve({ code: null, signal: null }));
		});
		let stdoutTail = '';
		let stderrTail = '';
		child.stdout.setEncoding('utf8');
		child.stderr.setEncoding('utf8');
		child.stdout.on('data', (chunk: string): void => {
			stdoutTail = appendBoundedTail(stdoutTail, chunk);
		});
		child.stderr.on('data', (chunk: string): void => {
			stderrTail = appendBoundedTail(stderrTail, chunk);
		});
		const server = new BridgeViewerOwnedViteServer({
			child,
			exitPromise,
			stdoutTail: (): string => stdoutTail,
			stderrTail: (): string => stderrTail,
			startProof: { origin: `http://127.0.0.1:${port}`, pid: child.pid ?? 0, version: null },
		});
		let readyOutput: string;
		try {
			props.onSpawn(server);
			readyOutput = await withBoundedTimeout(
				new Promise<string>((resolve, reject): void => {
					const inspectOutput = (): void => {
						const normalizedOutput = stripANSI(`${stdoutTail}\n${stderrTail}`);
						if (normalizedOutput.includes(`http://127.0.0.1:${port}/`)) {
							resolve(normalizedOutput);
						}
					};
					child.stdout.on('data', inspectOutput);
					child.stderr.on('data', inspectOutput);
					void exitPromise.then((exit): void => {
						reject(
							new Error(
								`Owned Vite exited before readiness: ${JSON.stringify({
									exit,
									stderrTail,
									stdoutTail,
								})}`,
							),
						);
					});
				}),
				serverStartupTimeoutMilliseconds,
				'owned loopback Vite readiness',
			);
		} catch (error: unknown) {
			await server.stop();
			throw error;
		}
		const origin = `http://127.0.0.1:${port}`;
		if (new URL(origin).hostname !== '127.0.0.1') {
			throw new Error(`Refusing non-loopback verifier Vite origin: ${origin}`);
		}
		server.#startProof = {
			origin,
			pid: child.pid ?? 0,
			version: /VITE v(?<version>\d+\.\d+\.\d+)/u.exec(readyOutput)?.groups?.['version'] ?? null,
		};
		return server;
	}

	#stopPromise: Promise<BridgeViewerViteServerCleanupProof> | null = null;
	async stop(): Promise<BridgeViewerViteServerCleanupProof> {
		this.#stopPromise ??= this.#stop();
		return await this.#stopPromise;
	}
	async #stop(): Promise<BridgeViewerViteServerCleanupProof> {
		const cleanup = await stopOwnedViteServer({
			child: this.#child,
			exitPromise: this.#exitPromise,
		});
		return {
			exitCode: cleanup.exitCode,
			exitSignal: cleanup.exitSignal,
			exitedWithinTimeout: !cleanup.forcedTerminationRequired,
			forcedTerminationRequired: cleanup.forcedTerminationRequired,
			ownedProcessAliveAfterStop: cleanup.ownedProcessAliveAfterStop,
			pid: this.#child.pid ?? null,
		};
	}
}

function appendBoundedTail(current: string, next: string): string {
	return `${current}${next}`.slice(-maximumServerLogTailCharacters);
}

function stripANSI(value: string): string {
	return value.replace(new RegExp(`${String.fromCharCode(27)}\\[[0-?]*[ -/]*[@-~]`, 'gu'), '');
}
function processIsAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error: unknown) {
		return !(
			typeof error === 'object' &&
			error !== null &&
			'code' in error &&
			error.code === 'ESRCH'
		);
	}
}
async function withBoundedTimeout<TValue>(
	promise: Promise<TValue>,
	timeoutMilliseconds: number,
	label: string,
): Promise<TValue> {
	const result = await withBoundedTimeoutOrNull(promise, timeoutMilliseconds);
	if (result === null) throw new Error(`Timed out waiting for ${label}.`);
	return result;
}

async function withBoundedTimeoutOrNull<TValue>(
	promise: Promise<TValue>,
	timeoutMilliseconds: number,
): Promise<TValue | null> {
	let timeout: ReturnType<typeof setTimeout> | null = null;
	try {
		return await Promise.race([
			promise,
			new Promise<null>((resolve): void => {
				timeout = setTimeout((): void => resolve(null), timeoutMilliseconds);
			}),
		]);
	} finally {
		if (timeout !== null) clearTimeout(timeout);
	}
}

export interface BridgeViewerOwnedViteProcessExit {
	readonly code: number | null;
	readonly signal: NodeJS.Signals | null;
}

export interface BridgeViewerOwnedViteProcessControl {
	readonly pid?: number | undefined;
	readonly kill: (signal: NodeJS.Signals) => boolean;
}

export interface BridgeViewerOwnedViteShutdownDependencies {
	readonly processIsAlive: (pid: number) => boolean;
	readonly waitForExitWithinDeadline: (
		exitPromise: Promise<BridgeViewerOwnedViteProcessExit>,
	) => Promise<BridgeViewerOwnedViteProcessExit | null>;
}

async function stopOwnedViteServer(props: {
	readonly child: BridgeViewerOwnedViteProcessControl;
	readonly exitPromise: Promise<BridgeViewerOwnedViteProcessExit>;
	readonly shutdownDependencies?: BridgeViewerOwnedViteShutdownDependencies;
}): Promise<BridgeViewerOwnedViteProductServerCleanup> {
	const shutdownDependencies = props.shutdownDependencies ?? defaultOwnedViteShutdownDependencies();
	const pid = props.child.pid ?? null;
	props.child.kill('SIGTERM');
	let forcedTerminationRequired = false;
	let exit = await shutdownDependencies.waitForExitWithinDeadline(props.exitPromise);
	if (exit === null) {
		forcedTerminationRequired = true;
		props.child.kill('SIGKILL');
		exit = await shutdownDependencies.waitForExitWithinDeadline(props.exitPromise);
	}
	return {
		exitCode: exit?.code ?? null,
		exitObserved: exit !== null,
		exitSignal: exit?.signal ?? null,
		forcedTerminationRequired,
		ownedProcessAliveAfterStop: pid === null ? false : shutdownDependencies.processIsAlive(pid),
	};
}

export async function rejectOwnedViteStartupAfterCleanup(props: {
	readonly child: BridgeViewerOwnedViteProcessControl;
	readonly exitPromise: Promise<BridgeViewerOwnedViteProcessExit>;
	readonly shutdownDependencies?: BridgeViewerOwnedViteShutdownDependencies;
	readonly startupError: unknown;
}): Promise<never> {
	const cleanup = await stopOwnedViteServer(props);
	if (!cleanup.exitObserved || cleanup.ownedProcessAliveAfterStop) {
		throw new AggregateError(
			[props.startupError],
			`OWNED_VITE_STARTUP_CLEANUP_FAILED:${JSON.stringify(cleanup)}`,
		);
	}
	throw props.startupError;
}

function defaultOwnedViteShutdownDependencies(): BridgeViewerOwnedViteShutdownDependencies {
	return {
		processIsAlive,
		waitForExitWithinDeadline: async (
			exitPromise,
		): Promise<BridgeViewerOwnedViteProcessExit | null> =>
			await withBoundedTimeoutOrNull(exitPromise, serverShutdownTimeoutMilliseconds),
	};
}
