import { expect, test } from 'vitest';

import { observeBridgeStartupDOMFact } from '../scripts/verify-bridge-viewer-worktree-dev-server/startup-dom-facts.ts';

test('startup observes metadata publication and already published state without a lost wakeup', async () => {
	const shell = document.createElement('div');
	shell.dataset['testid'] = 'bridge-file-viewer-shell';
	document.body.append(shell);
	try {
		const published = observeBridgeStartupDOMFact({ kind: 'file.metadata' });
		shell.setAttribute('data-worktree-metadata-file-row-count', '1');
		await published;
		await observeBridgeStartupDOMFact({ kind: 'file.metadata' });
		expect(shell.getAttribute('data-worktree-metadata-file-row-count')).toBe('1');
	} finally {
		shell.remove();
	}
});

test('startup content state is correlated to the selected path', async () => {
	const panel = document.createElement('div');
	panel.dataset['testid'] = 'bridge-file-viewer-code-canvas';
	document.body.append(panel);
	try {
		let wrongPathCompleted = false;
		const wrongPath = observeBridgeStartupDOMFact({ kind: 'file.content', path: 'other.txt' }).then(
			(): void => {
				wrongPathCompleted = true;
			},
		);
		const selectedPath = observeBridgeStartupDOMFact({
			kind: 'file.content',
			path: 'selected.txt',
		});
		panel.setAttribute('data-worktree-open-file-path', 'selected.txt');
		panel.setAttribute('data-worktree-open-file-state', 'ready');
		await selectedPath;
		expect(wrongPathCompleted).toBe(false);
		panel.setAttribute('data-worktree-open-file-path', 'other.txt');
		await wrongPath;
		expect(wrongPathCompleted).toBe(true);
	} finally {
		panel.remove();
	}
});

test('startup handshake closes on the ready acknowledgement event', async () => {
	const original = window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds;
	delete window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds;
	try {
		const ready = observeBridgeStartupDOMFact({ kind: 'handshake' });
		window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds = 42;
		document.dispatchEvent(new Event('__bridge_ready_ack'));
		await ready;
		expect(window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds).toBe(42);
	} finally {
		if (original === undefined) delete window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds;
		else window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds = original;
	}
});
