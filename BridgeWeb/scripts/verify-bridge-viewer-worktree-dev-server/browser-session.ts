import type { Browser } from 'playwright';

import type { BridgeWebTestLaunch } from '../dev-server/bridge-web-test-launch.ts';
import type { HandledLaunchPromise } from '../dev-server/handled-launch-promise.ts';

let verifierBrowser: Browser | null = null;
let verifierJourneySignal: AbortSignal | undefined;
let verifierLaunch: BridgeWebTestLaunch | null = null;

export function installVerifierBrowser(
	browser: Browser,
	signal: AbortSignal,
	launch: BridgeWebTestLaunch,
): void {
	verifierBrowser = browser;
	verifierJourneySignal = signal;
	verifierLaunch = launch;
}

export function clearVerifierBrowser(): void {
	verifierBrowser = null;
	verifierJourneySignal = undefined;
	verifierLaunch = null;
}

export function observeVerifierStartupStep<TValue>(
	name: string,
	promise: Promise<TValue>,
): HandledLaunchPromise<TValue> {
	if (verifierLaunch === null) throw new Error('Expected the verifier launch owner.');
	return verifierLaunch.observeStep(name, promise);
}

export function requireVerifierBrowser(): Browser {
	if (verifierBrowser === null) {
		throw new Error('Expected BridgeViewer worktree dev-server verifier browser to be installed');
	}
	return verifierBrowser;
}

export function currentVerifierJourneySignal(): AbortSignal | undefined {
	return verifierJourneySignal;
}
