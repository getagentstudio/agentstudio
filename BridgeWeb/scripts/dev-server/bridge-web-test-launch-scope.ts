import { AsyncLocalStorage } from 'node:async_hooks';

import type { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';

export interface BridgeWebLaunchScope {
	readonly signal: AbortSignal;
	readonly ownLaunch: (launch: BridgeWebTestLaunch, created: boolean) => void;
}

// SSR module copies must share the same causal owner, like the exit registry.
const scopeKey = Symbol.for('agentstudio.bridge-web-launch.scope');
const scopeGlobal = globalThis as typeof globalThis & {
	[scopeKey]?: AsyncLocalStorage<BridgeWebLaunchScope>;
};
const launchScope = (scopeGlobal[scopeKey] ??= new AsyncLocalStorage<BridgeWebLaunchScope>());

export function currentBridgeWebLaunchScope(): BridgeWebLaunchScope | undefined {
	return launchScope.getStore();
}

export async function runWithBridgeWebLaunchScope<TValue>(
	scope: BridgeWebLaunchScope,
	operation: () => Promise<TValue>,
): Promise<TValue> {
	return await launchScope.run(scope, operation);
}
