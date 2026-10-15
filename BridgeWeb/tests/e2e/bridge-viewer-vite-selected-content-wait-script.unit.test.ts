import { runInNewContext } from 'node:vm';

import { expect, test } from 'vitest';

import type { SelectedContentOwnerSnapshot } from './bridge-viewer-vite-selected-content-owner.ts';
import {
	selectedContentOwnerWaitScript,
	type SelectedContentReadyTarget,
} from './bridge-viewer-vite-selected-content-wait.ts';

function runWaitScript(props: {
	readonly target: SelectedContentReadyTarget;
	readonly hasCanvas?: boolean;
	readonly contentState?: string;
	readonly paintedSha?: string;
	readonly renderedItemId?: string;
	readonly ownerFailure?: string;
	readonly sessionState?: string;
	readonly displayedPublication?: string;
}): {
	readonly outcome: Promise<unknown>;
	readonly retire: () => void;
	readonly publishFailureAfterCanvasRemoval: () => void;
	readonly disconnected: () => boolean;
} {
	let canvasPresent = props.hasCanvas ?? true;
	let disconnected = false;
	let observation: SelectedContentOwnerSnapshot = {
		selectedItemId: 'selected-file',
		selectionRequestId: 'selection-request',
		workerDerivationEpoch: 7,
		publicationId: 'publication-current',
		phase: 'content-result',
		failure:
			props.ownerFailure === undefined
				? null
				: {
						channelId: 1,
						itemId: 'selected-file',
						workerDerivationEpoch: 7,
						publicationId: 'publication-current',
						reason: props.ownerFailure,
						state: 'failed',
					},
	};
	const canvas = {
		getAttribute: (name: string): string | null => {
			if (name === 'data-worktree-rendered-item-id' || name === 'data-selected-item-id')
				return props.renderedItemId ?? 'selected-file';
			if (name === 'data-worktree-open-file-state' || name === 'data-selected-content-state')
				return props.contentState ?? 'loading';
			return null;
		},
		querySelector: (): { readonly getAttribute: () => string } => ({
			getAttribute: (): string =>
				JSON.stringify([{ observedSha256: props.paintedSha ?? 'old-sha' }]),
		}),
	};
	const documentTarget = Object.assign(new EventTarget(), {
		querySelector: (selector: string): typeof canvas | null =>
			selector.includes('inactive') || !canvasPresent ? null : canvas,
		querySelectorAll: (): readonly (typeof canvas)[] => (canvasPresent ? [canvas] : []),
	});
	const windowTarget = Object.assign(new EventTarget(), {
		bridgeSelectedContentOwnerObservation: {
			read: (): SelectedContentOwnerSnapshot => observation,
		},
		__bridgeReviewSelectionDiagnostic: {
			sessionState: props.sessionState ?? 'ready',
			reviewInstallationGate: {
				activeIdentity: { publicationId: props.displayedPublication ?? 'publication-current' },
			},
		},
	});
	const result: unknown = runInNewContext(
		selectedContentOwnerWaitScript({ label: 'selected-content-proof', target: props.target }),
		{
			document: documentTarget,
			window: windowTarget,
			location: { protocol: 'about:' },
			MutationObserver: class {
				observe(): void {}
				disconnect(): void {
					disconnected = true;
				}
			},
		},
	);
	return {
		outcome: Promise.resolve(result),
		retire: (): void => {
			windowTarget.dispatchEvent(new Event('pagehide'));
		},
		disconnected: (): boolean => disconnected,
		publishFailureAfterCanvasRemoval: (): void => {
			canvasPresent = false;
			observation = {
				...observation,
				failure: {
					channelId: 1,
					itemId: 'selected-file',
					workerDerivationEpoch: 7,
					publicationId: 'publication-current',
					reason: 'file-refresh:producerRejected',
					state: 'failed',
				},
			};
			documentTarget.dispatchEvent(new Event('__bridge_selected_content_owner_changed'));
		},
	};
}

test('a current File owner failure ends the wait even when its canvas is already absent', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		hasCanvas: false,
		ownerFailure: 'file-refresh:producerRejected',
	});
	const assertion = expect(wait.outcome).rejects.toThrow('file-refresh:producerRejected');
	// Closure provides a deterministic closing fact for an incorrectly positive-only waiter.
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('a File failure arriving after canvas removal still belongs to the requested operation', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
	});
	const assertion = expect(wait.outcome).rejects.toThrow('file-refresh:producerRejected');
	wait.publishFailureAfterCanvasRemoval();
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('File success still requires the ready state and exact requested painted SHA', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		contentState: 'ready',
		paintedSha: 'new-sha',
	});
	await wait.outcome;
	expect(wait.disconnected()).toBe(true);
});

test.each([
	{ contentState: 'ready', paintedSha: 'old-sha' },
	{ contentState: 'loading', paintedSha: 'new-sha' },
])('does not accept incomplete File paint: %j', async (state) => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		...state,
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('an undisplayed Review candidate failure cannot terminate the current displayed publication', async () => {
	const wait = runWaitScript({
		target: { surface: 'review', itemId: 'selected-file' },
		displayedPublication: 'displayed-predecessor',
		ownerFailure: 'load_failed',
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('worker owner exhaustion is terminal before DOM readiness or observer registration', async () => {
	const wait = runWaitScript({
		target: { surface: 'review', itemId: 'selected-file' },
		sessionState: 'failed',
		hasCanvas: false,
	});
	await expect(wait.outcome).rejects.toThrow('worker-recovery-exhausted');
});

test('matching File bytes on another rendered item cannot satisfy the requested operation', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		renderedItemId: 'another-file',
		contentState: 'ready',
		paintedSha: 'new-sha',
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});
