import type { Browser } from 'playwright';

let verifierBrowser: Browser | null = null;
let verifierJourneySignal: AbortSignal | undefined;

export function installVerifierBrowser(browser: Browser, signal?: AbortSignal): void {
	verifierBrowser = browser;
	verifierJourneySignal = signal;
}

export function clearVerifierBrowser(): void {
	verifierBrowser = null;
	verifierJourneySignal = undefined;
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
