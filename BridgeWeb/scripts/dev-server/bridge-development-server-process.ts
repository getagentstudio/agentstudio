import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { join } from 'node:path';

import { reserveLoopbackPort as reserveBridgeDevelopmentServerPort } from './reserve-loopback-port.js';

export { reserveBridgeDevelopmentServerPort };

const shutdownTimeoutMilliseconds = 10_000;
const maximumLogTailCharacters = 8_192;
// Printed once by the Swift development server after its listener is bound
// (BridgeDevelopmentServerReadinessAnnouncement.swift).
const readinessAnnouncementPattern = /^bridge-development-server ready port=(\d+) pid=(\d+)$/u;

export interface OwnedBridgeDevelopmentServer {
	readonly origin: string;
	readonly pid: number;
	readonly stderrTail: () => string;
	readonly stop: () => Promise<OwnedBridgeDevelopmentServerCleanup>;
	readonly stdoutTail: () => string;
	readonly whenExited: Promise<void>;
}

export interface OwnedBridgeDevelopmentServerCleanup {
	readonly exitCode: number | null;
	readonly exitSignal: NodeJS.Signals | null;
	readonly forcedTerminationRequired: boolean;
	readonly ownedProcessAliveAfterStop: boolean;
}

interface ChildProcessExit {
	readonly code: number | null;
	readonly signal: NodeJS.Signals | null;
}

export type BridgeDevelopmentServerLifecycleOutcome =
	| ({ readonly kind: 'exit' } & ChildProcessExit)
	| { readonly error: Error; readonly kind: 'spawn-error' };

export interface OwnedCleanupOperation {
	readonly name: string;
	readonly run: () => Promise<void>;
}

export interface OwnedBridgeDevelopmentServerProcessControl {
	readonly pid?: number | undefined;
	readonly kill: (signal: NodeJS.Signals) => boolean;
}

export interface BridgeDevelopmentServerReadinessAnnouncement {
	readonly pid: number;
	readonly port: number;
}

type BridgeDevelopmentServerReadinessOutcome =
	| { readonly announcement: BridgeDevelopmentServerReadinessAnnouncement; readonly kind: 'ready' }
	| { readonly kind: 'lifecycle'; readonly outcome: BridgeDevelopmentServerLifecycleOutcome };

// Assembles stdout chunks into lines, so a readiness line split across chunks is
// still recognized, and settles `announcement` on the first readiness line.
export class BridgeDevelopmentServerReadinessLineReader {
	readonly announcement: Promise<BridgeDevelopmentServerReadinessAnnouncement>;
	#partialLine = '';
	#resolveAnnouncement: ((value: BridgeDevelopmentServerReadinessAnnouncement) => void) | null =
		null;

	constructor() {
		this.announcement = new Promise((resolve): void => {
			this.#resolveAnnouncement = resolve;
		});
	}

	observeStdoutChunk(chunk: string): void {
		if (this.#resolveAnnouncement === null) return;
		const lines = `${this.#partialLine}${chunk}`.split('\n');
		this.#partialLine = (lines.pop() ?? '').slice(-maximumLogTailCharacters);
		for (const line of lines) {
			const announcement = parseBridgeDevelopmentServerReadinessLine(line);
			if (announcement === null) continue;
			this.#resolveAnnouncement(announcement);
			this.#resolveAnnouncement = null;
			this.#partialLine = '';
			return;
		}
	}
}

export function parseBridgeDevelopmentServerReadinessLine(
	line: string,
): BridgeDevelopmentServerReadinessAnnouncement | null {
	const match = readinessAnnouncementPattern.exec(line.trimEnd());
	if (match?.[1] === undefined || match[2] === undefined) return null;
	return { pid: Number(match[2]), port: Number(match[1]) };
}

export async function startOwnedBridgeDevelopmentServer(props: {
	readonly dataRootPath: string;
	readonly initialTarget: string;
	readonly onSpawn?: (server: OwnedBridgeDevelopmentServer) => void;
	readonly paneId: string;
	readonly port?: number;
	readonly repoRootPath: string;
	readonly worktreeRoot: string;
}): Promise<OwnedBridgeDevelopmentServer> {
	const port = await resolveBridgeDevelopmentServerPort({
		...(props.port === undefined ? {} : { configuredPort: props.port }),
		reservePort: reserveBridgeDevelopmentServerPort,
	});
	const origin = `http://127.0.0.1:${port}`;
	const executablePath = bridgeDevelopmentServerExecutablePath(props.repoRootPath);
	await access(executablePath);
	const child = spawn(
		executablePath,
		bridgeDevelopmentServerArguments({
			dataRootPath: props.dataRootPath,
			initialTarget: props.initialTarget,
			paneId: props.paneId,
			port,
			worktreeRoot: props.worktreeRoot,
		}),
		{
			cwd: props.repoRootPath,
			env: { ...process.env },
			stdio: ['pipe', 'pipe', 'pipe'],
		},
	);
	const lifecycleOutcome = new Promise<BridgeDevelopmentServerLifecycleOutcome>((resolve): void => {
		child.once('exit', (code, signal): void => resolve({ code, kind: 'exit', signal }));
		child.once('error', (error): void => resolve({ error, kind: 'spawn-error' }));
	});
	let stdoutTail = '';
	let stderrTail = '';
	const readinessLineReader = new BridgeDevelopmentServerReadinessLineReader();
	child.stdout.setEncoding('utf8');
	child.stderr.setEncoding('utf8');
	child.stdout.on('data', (chunk: string): void => {
		stdoutTail = appendBoundedTail(stdoutTail, chunk);
		readinessLineReader.observeStdoutChunk(chunk);
	});
	child.stderr.on('data', (chunk: string): void => {
		stderrTail = appendBoundedTail(stderrTail, chunk);
	});
	let stopPromise: Promise<OwnedBridgeDevelopmentServerCleanup> | null = null;
	const ownedServer: OwnedBridgeDevelopmentServer = {
		origin,
		pid: child.pid ?? 0,
		stderrTail: (): string => stderrTail,
		stop: async (): Promise<OwnedBridgeDevelopmentServerCleanup> => {
			stopPromise ??= stopOwnedBridgeDevelopmentServerProcess(child, lifecycleOutcome);
			return await stopPromise;
		},
		stdoutTail: (): string => stdoutTail,
		whenExited: lifecycleOutcome.then((): void => {}),
	};
	try {
		props.onSpawn?.(ownedServer);
		await waitForBridgeDevelopmentServerReadiness({
			expectedProcess: { pid: child.pid ?? 0, port },
			lifecycleOutcome,
			readinessAnnouncement: readinessLineReader.announcement,
			readinessOwnershipProbe: async (): Promise<boolean> =>
				await bridgeDevelopmentServerProcessOwnsListeningPort({
					pid: child.pid ?? 0,
					port,
				}),
			stderrTail: (): string => stderrTail,
			stdoutTail: (): string => stdoutTail,
		});
	} catch (error: unknown) {
		await ownedServer.stop();
		throw error;
	}
	return ownedServer;
}

export async function resolveBridgeDevelopmentServerPort(props: {
	readonly configuredPort?: number;
	readonly reservePort: () => Promise<number>;
}): Promise<number> {
	return props.configuredPort ?? (await props.reservePort());
}

export function bridgeDevelopmentServerArguments(props: {
	readonly dataRootPath: string;
	readonly initialTarget: string;
	readonly paneId: string;
	readonly port: number;
	readonly worktreeRoot: string;
}): string[] {
	return [
		'--data-root',
		props.dataRootPath,
		'--pane-id',
		props.paneId,
		'--seed-worktree',
		props.worktreeRoot,
		'--seed-target',
		props.initialTarget,
		'--port',
		String(props.port),
	];
}

export function bridgeDevelopmentServerExecutablePath(repoRootPath: string): string {
	return join(repoRootPath, '.build-bridge-development-server', 'agentstudio-bridge-dev-server');
}

// Readiness is an event: the owned child announces its bound listener on stdout,
// or its lifecycle ends first. Ownership is then checked once, so a process that
// merely collides on the port cannot satisfy readiness. No clock is involved;
// the calling suite's declared hang bound is the only time limit.
export async function waitForBridgeDevelopmentServerReadiness(props: {
	readonly expectedProcess: BridgeDevelopmentServerReadinessAnnouncement;
	readonly lifecycleOutcome: Promise<BridgeDevelopmentServerLifecycleOutcome>;
	readonly readinessAnnouncement: Promise<BridgeDevelopmentServerReadinessAnnouncement>;
	readonly readinessOwnershipProbe: () => Promise<boolean>;
	readonly stderrTail: () => string;
	readonly stdoutTail: () => string;
}): Promise<void> {
	const logTails = (): string =>
		JSON.stringify({ stderrTail: props.stderrTail(), stdoutTail: props.stdoutTail() });
	const readinessOutcome = await Promise.race<BridgeDevelopmentServerReadinessOutcome>([
		props.lifecycleOutcome.then(
			(outcome): BridgeDevelopmentServerReadinessOutcome => ({ kind: 'lifecycle', outcome }),
		),
		props.readinessAnnouncement.then(
			(announcement): BridgeDevelopmentServerReadinessOutcome => ({ announcement, kind: 'ready' }),
		),
	]);
	if (readinessOutcome.kind === 'lifecycle') {
		const outcome = readinessOutcome.outcome;
		if (outcome.kind === 'spawn-error') {
			throw new Error(
				`Owned Swift development backend failed to spawn before readiness: ${JSON.stringify({ error: outcome.error.message, stderrTail: props.stderrTail(), stdoutTail: props.stdoutTail() })}`,
				{ cause: outcome.error },
			);
		}
		throw new Error(
			`Owned Swift development backend exited before readiness: ${JSON.stringify({ exit: outcome, stderrTail: props.stderrTail(), stdoutTail: props.stdoutTail() })}`,
		);
	}
	const { announcement } = readinessOutcome;
	if (
		announcement.pid !== props.expectedProcess.pid ||
		announcement.port !== props.expectedProcess.port
	) {
		throw new Error(
			`Owned Swift development backend announced an unexpected listener ${JSON.stringify({ announcement, expected: props.expectedProcess })}: ${logTails()}`,
		);
	}
	if (!(await props.readinessOwnershipProbe())) {
		throw new Error(
			`Owned Swift development backend announced readiness but does not own its listening port: ${logTails()}`,
		);
	}
}

export async function bridgeDevelopmentServerProcessOwnsListeningPort(props: {
	readonly pid: number;
	readonly port: number;
}): Promise<boolean> {
	if (props.pid <= 0) return false;
	return await new Promise<boolean>((resolve, reject): void => {
		// Agent Studio's development loop is macOS-only; lsof binds readiness to the exact child PID.
		const inspector = spawn(
			'/usr/sbin/lsof',
			['-nP', '-a', '-p', String(props.pid), `-iTCP:${props.port}`, '-sTCP:LISTEN', '-Fp'],
			{ stdio: ['ignore', 'pipe', 'pipe'] },
		);
		let settled = false;
		let stderr = '';
		let stdout = '';
		const finish = (result: {
			readonly error?: Error;
			readonly ownsListeningPort?: boolean;
		}): void => {
			if (settled) return;
			settled = true;
			if (result.error === undefined) resolve(result.ownsListeningPort ?? false);
			else reject(result.error);
		};
		inspector.stdout.setEncoding('utf8');
		inspector.stderr.setEncoding('utf8');
		inspector.stdout.on('data', (chunk: string): void => {
			stdout += chunk;
		});
		inspector.stderr.on('data', (chunk: string): void => {
			stderr = appendBoundedTail(stderr, chunk);
		});
		inspector.once('error', (error): void => {
			finish({
				error: new Error(`Failed to inspect owned Bridge backend listener: ${error.message}`, {
					cause: error,
				}),
			});
		});
		inspector.once('close', (code): void => {
			if (code === 0) {
				finish({ ownsListeningPort: stdout.split('\n').includes(`p${props.pid}`) });
				return;
			}
			if (code === 1) {
				finish({ ownsListeningPort: false });
				return;
			}
			finish({
				error: new Error(
					`Failed to inspect owned Bridge backend listener: lsof exited with code ${code ?? 'unknown'}${stderr === '' ? '' : `: ${stderr}`}`,
				),
			});
		});
	});
}

export async function stopOwnedBridgeDevelopmentServerProcess(
	child: OwnedBridgeDevelopmentServerProcessControl,
	lifecycleOutcome: Promise<BridgeDevelopmentServerLifecycleOutcome>,
): Promise<OwnedBridgeDevelopmentServerCleanup> {
	const pid = child.pid ?? null;
	const outcomeBeforeStop = await settledValue(lifecycleOutcome);
	if (outcomeBeforeStop?.kind === 'spawn-error') {
		return {
			exitCode: null,
			exitSignal: null,
			forcedTerminationRequired: false,
			ownedProcessAliveAfterStop: pid === null ? false : processIsAlive(pid),
		};
	}
	child.kill('SIGTERM');
	let forcedTerminationRequired = false;
	let outcome = await withBoundedTimeoutOrNull(lifecycleOutcome, shutdownTimeoutMilliseconds);
	if (outcome === null) {
		forcedTerminationRequired = true;
		child.kill('SIGKILL');
		outcome = await withBoundedTimeoutOrNull(lifecycleOutcome, shutdownTimeoutMilliseconds);
	}
	const exit = outcome?.kind === 'exit' ? outcome : null;
	return {
		exitCode: exit?.code ?? null,
		exitSignal: exit?.signal ?? null,
		forcedTerminationRequired,
		ownedProcessAliveAfterStop: pid === null ? false : processIsAlive(pid),
	};
}

export async function runAllOwnedCleanupOperations(props: {
	readonly operations: readonly OwnedCleanupOperation[];
	readonly primaryError?: unknown;
}): Promise<void> {
	const cleanupFailures: unknown[] = [];
	const failedCleanupNames: string[] = [];
	for (const operation of props.operations) {
		try {
			// oxlint-disable-next-line no-await-in-loop -- Cleanup order is owned and every operation must run after a predecessor failure.
			await operation.run();
		} catch (error: unknown) {
			cleanupFailures.push(error);
			failedCleanupNames.push(operation.name);
		}
	}
	if (cleanupFailures.length > 0) {
		throw new AggregateError(
			props.primaryError === undefined ? cleanupFailures : [props.primaryError, ...cleanupFailures],
			`Owned cleanup failed: ${failedCleanupNames.join(', ')}.`,
		);
	}
	if (props.primaryError !== undefined) throw props.primaryError;
}

async function settledValue<TValue>(promise: Promise<TValue>): Promise<TValue | null> {
	return await Promise.race([promise, Promise.resolve(null)]);
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

function appendBoundedTail(current: string, next: string): string {
	return `${current}${next}`.slice(-maximumLogTailCharacters);
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
