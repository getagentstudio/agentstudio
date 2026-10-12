import type { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';

// A process has one exit backstop, shared by every launch in it. Normal callers
// still await dispose(); a fatal process event reports its error and exits only
// after every registered owner has attempted cleanup.
const registryKey = Symbol.for('agentstudio.bridge-web-test-launch.registry');
interface LaunchRegistry {
	readonly launches: Set<BridgeWebTestLaunch>;
	removeExitHooks: (() => void) | null;
	fatalCleanup: Promise<void> | null;
}
const registryGlobal = globalThis as typeof globalThis & { [registryKey]?: LaunchRegistry };
const registry = (registryGlobal[registryKey] ??= {
	launches: new Set(),
	removeExitHooks: null,
	fatalCleanup: null,
});
export const activeLaunches = registry.launches;

export function installExitHooks(): void {
	if (registry.removeExitHooks !== null) return;
	const terminate = (error: unknown, exitCode: number): void => {
		registry.fatalCleanup ??= (async (): Promise<void> => {
			process.stderr.write(`BridgeWeb test launch terminated: ${String(error)}\n`);
			const results = await Promise.allSettled(
				[...activeLaunches].map((launch) => launch.dispose()),
			);
			for (const result of results) {
				if (result.status === 'rejected')
					process.stderr.write(`BridgeWeb teardown failed: ${String(result.reason)}\n`);
			}
			process.exit(exitCode);
		})();
		// The backstop itself cannot create an unhandled rejection.
		void registry.fatalCleanup.catch((failure: unknown): void => {
			process.stderr.write(`BridgeWeb fatal teardown failed: ${String(failure)}\n`);
			process.exit(exitCode);
		});
	};
	const unhandled = (error: unknown): void => terminate(error, 1);
	const uncaught = (error: Error): void => terminate(error, 1);
	const interrupt = (): void => terminate('SIGINT', 130);
	const terminated = (): void => terminate('SIGTERM', 143);
	process.on('unhandledRejection', unhandled);
	process.on('uncaughtException', uncaught);
	process.on('SIGINT', interrupt);
	process.on('SIGTERM', terminated);
	registry.removeExitHooks = (): void => {
		process.off('unhandledRejection', unhandled);
		process.off('uncaughtException', uncaught);
		process.off('SIGINT', interrupt);
		process.off('SIGTERM', terminated);
		registry.removeExitHooks = null;
	};
}

export function removeUnusedExitHooks(): void {
	if (activeLaunches.size === 0) registry.removeExitHooks?.();
}
