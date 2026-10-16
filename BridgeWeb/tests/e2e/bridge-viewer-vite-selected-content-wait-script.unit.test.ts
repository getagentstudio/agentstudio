import { runInNewContext } from 'node:vm';

import { expect, test } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import type { BridgePaneCommWorkerSessionDiagnosticState } from '../../src/foundation/diagnostics/bridge-review-selection-diagnostic.js';
import {
	createSelectedContentOwnerRecorder,
	selectedContentTerminalFailure,
	type SelectedContentOwnerSnapshot,
} from './bridge-viewer-vite-selected-content-owner.ts';
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
	readonly sessionState?: BridgePaneCommWorkerSessionDiagnosticState;
	readonly withDiagnosticLifecycle?: boolean;
	readonly displayedPublication?: string;
	readonly recorder?: ReturnType<typeof createSelectedContentOwnerRecorder>;
}): {
	readonly outcome: Promise<unknown>;
	readonly retire: () => void;
	readonly publishFailureAfterCanvasRemoval: () => void;
	readonly disconnected: () => boolean;
	readonly diagnosticSubscription: Promise<void>;
	readonly publishWorkerSessionState: (state: BridgePaneCommWorkerSessionDiagnosticState) => void;
	readonly publishOwnerMessage: (message: unknown) => void;
	readonly publishSuccessor: (state: {
		readonly contentState: string;
		readonly paintedSha: string;
		readonly renderedItemId: string;
	}) => void;
} {
	let canvasPresent = props.hasCanvas ?? true;
	let disconnected = false;
	let contentState = props.contentState ?? 'loading';
	let paintedSha = props.paintedSha ?? 'old-sha';
	let renderedItemId = props.renderedItemId ?? 'selected-file';
	const diagnosticSubscription = createBridgeProductDeferred<void>();
	const diagnosticObservers = new Set<
		(snapshot: { readonly state: BridgePaneCommWorkerSessionDiagnosticState }) => void
	>();
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
				return renderedItemId;
			if (name === 'data-worktree-open-file-state' || name === 'data-selected-content-state')
				return contentState;
			return null;
		},
		querySelector: (): { readonly getAttribute: () => string } => ({
			getAttribute: (): string => JSON.stringify([{ observedSha256: paintedSha }]),
		}),
	};
	const documentTarget = Object.assign(new EventTarget(), {
		querySelector: (selector: string): typeof canvas | null =>
			selector.includes('inactive') || !canvasPresent ? null : canvas,
		querySelectorAll: (): readonly (typeof canvas)[] => (canvasPresent ? [canvas] : []),
	});
	const windowTarget = Object.assign(new EventTarget(), {
		bridgeSelectedContentOwnerObservation: {
			read: (): SelectedContentOwnerSnapshot =>
				props.recorder?.read(props.target.surface) ?? observation,
		},
		__bridgeReviewSelectionDiagnostic: {
			sessionState: props.sessionState ?? 'ready',
			reviewInstallationGate: {
				activeIdentity: { publicationId: props.displayedPublication ?? 'publication-current' },
			},
		},
	});
	const workerDiagnostic = {
		readBridgeReviewSelectionDiagnostic: (): { readonly sessionState: string } =>
			windowTarget['__bridgeReviewSelectionDiagnostic'],
		observeBridgePaneCommWorkerSessionDiagnosticSnapshots: (
			observer: (snapshot: { readonly state: BridgePaneCommWorkerSessionDiagnosticState }) => void,
		): (() => void) => {
			diagnosticObservers.add(observer);
			diagnosticSubscription.resolve();
			return (): void => {
				diagnosticObservers.delete(observer);
			};
		},
	};
	let script = selectedContentOwnerWaitScript({
		label: 'selected-content-proof',
		target: props.target,
	});
	if (props.withDiagnosticLifecycle === true) {
		// Only Vite's external module loader is a stand-in. The generated subscription,
		// diagnostic callback, currentness predicate and cleanup run unchanged.
		const loader =
			"await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href)";
		expect(script.split(loader)).toHaveLength(2);
		script = script.replace(loader, 'await workerDiagnostic');
	}
	const result: unknown = runInNewContext(script, {
		document: documentTarget,
		window: windowTarget,
		location: { protocol: props.withDiagnosticLifecycle === true ? 'http:' : 'about:' },
		workerDiagnostic,
		MutationObserver: class {
			observe(): void {}
			disconnect(): void {
				disconnected = true;
			}
		},
	});
	const publishWorkerSessionState = (state: BridgePaneCommWorkerSessionDiagnosticState): void => {
		windowTarget['__bridgeReviewSelectionDiagnostic'].sessionState = state;
		for (const observer of diagnosticObservers) observer({ state });
	};
	return {
		outcome: Promise.resolve(result),
		diagnosticSubscription: diagnosticSubscription.promise,
		publishWorkerSessionState,
		publishOwnerMessage: (message): void => {
			props.recorder?.observe(1, message);
			documentTarget.dispatchEvent(new Event('__bridge_selected_content_owner_changed'));
		},
		publishSuccessor: (state): void => {
			contentState = state.contentState;
			paintedSha = state.paintedSha;
			renderedItemId = state.renderedItemId;
			observation = {
				...observation,
				failure: null,
				workerDerivationEpoch: 8,
				selectionRequestId: 'successor-selection-request',
				publicationId: 'successor-publication',
			};
			windowTarget[
				'__bridgeReviewSelectionDiagnostic'
			].reviewInstallationGate.activeIdentity.publicationId = 'successor-publication';
			publishWorkerSessionState('ready');
			documentTarget.dispatchEvent(new Event('__bridge_selected_content_owner_changed'));
		},
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

function recoveringFileRecorder(): ReturnType<typeof createSelectedContentOwnerRecorder> {
	const recorder = createSelectedContentOwnerRecorder(selectedContentTerminalFailure);
	recorder.observe(1, { method: 'bridgeCommWorker.bootstrap' });
	recorder.observe(1, {
		wireVersion: 1,
		direction: 'mainToServerWorker',
		command: 'select',
		surface: 'fileView',
		selectedItemId: 'selected-file',
		requestId: 'selection',
	});
	recorder.observe(1, {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'fileDisplayPatch',
		surface: 'fileView',
		epoch: 7,
	});
	return recorder;
}

function viewRecovery(status: 'recovering' | 'failedRetryable' | 'ready'): unknown {
	return {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'viewRecoveryStatus',
		view: { kind: 'file.metadata', subscriptionId: 'live-file-subscription' },
		status,
	};
}

const fileContentReadyMessage = (sequence: number): unknown => ({
	wireVersion: 1,
	direction: 'serverWorkerToMain',
	kind: 'fileRenderPatch',
	surface: 'file',
	workerDerivationEpoch: 7,
	publicationSequence: sequence,
	patches: [
		{
			slice: 'contentAvailability',
			operation: 'upsert',
			itemId: 'selected-file',
			payload: { state: 'ready' },
		},
	],
});
const fileSourceJobMessage = (sequence: number, sha256: string): unknown => ({
	wireVersion: 1,
	direction: 'serverWorkerToMain',
	kind: 'filePierreRenderJob',
	surface: 'file',
	workerDerivationEpoch: 7,
	publicationSequence: sequence,
	job: {
		itemId: 'selected-file',
		sourceCorrelations: [{ itemId: 'selected-file', observedSha256: sha256 }],
	},
});

test('the new-descriptor phase ends from exact-source preparation while selected-content close is held', async () => {
	const wait = runWaitScript({
		recorder: recoveringFileRecorder(),
		target: {
			surface: 'file',
			itemId: 'selected-file',
			expectedSha256: 'new-sha',
			goal: 'descriptor-prepared',
		},
	});
	const assertion = expect(wait.outcome).resolves.toBeUndefined();
	try {
		wait.publishOwnerMessage(fileSourceJobMessage(1, 'old-sha'));
		expect.soft(wait.disconnected()).toBe(false);
		wait.publishOwnerMessage(fileSourceJobMessage(3, 'new-sha'));
		expect.soft(wait.disconnected()).toBe(true);
	} finally {
		// Close an old waiter deterministically; ready and paint were never delivered.
		wait.retire();
		await assertion;
	}
});

test('selected-content close requires the exact source job and its correlated ready result before paint', async () => {
	const wait = runWaitScript({
		recorder: recoveringFileRecorder(),
		target: {
			surface: 'file',
			itemId: 'selected-file',
			expectedSha256: 'new-sha',
			goal: 'content-closed',
		},
	});
	const assertion = expect(wait.outcome).resolves.toBeUndefined();

	try {
		wait.publishOwnerMessage(fileSourceJobMessage(1, 'old-sha'));
		wait.publishOwnerMessage(fileContentReadyMessage(1));
		expect.soft(wait.disconnected()).toBe(false);
		wait.publishOwnerMessage(fileSourceJobMessage(3, 'new-sha'));
		wait.publishOwnerMessage(fileContentReadyMessage(2));
		expect.soft(wait.disconnected()).toBe(false);
		wait.publishOwnerMessage(fileContentReadyMessage(3));
		expect.soft(wait.disconnected()).toBe(true);
	} finally {
		wait.retire();
		await assertion;
	}
});

test('the File waiter consumes the actual view-owner final failure before document retirement', async () => {
	const wait = runWaitScript({
		recorder: recoveringFileRecorder(),
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
	});
	const assertion = expect(wait.outcome).rejects.toThrow(
		'file-view-recovery:failedRetryable:live-file-subscription',
	);
	try {
		wait.publishOwnerMessage(viewRecovery('recovering'));
		expect.soft(wait.disconnected()).toBe(false);
		wait.publishOwnerMessage(viewRecovery('failedRetryable'));
		expect.soft(wait.disconnected()).toBe(true);
	} finally {
		// Retire even a broken positive-only waiter, so its red names the wrong owner.
		wait.retire();
		await assertion;
	}
});

test('recovering and transient failed File presentation stay pending until ready exact-SHA paint', async () => {
	const wait = runWaitScript({
		recorder: recoveringFileRecorder(),
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
	});
	try {
		wait.publishOwnerMessage(viewRecovery('recovering'));
		wait.publishOwnerMessage({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			kind: 'fileRenderPatch',
			surface: 'file',
			workerDerivationEpoch: 7,
			publicationSequence: 1,
			patches: [
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'selected-file',
					payload: { state: 'failed', reason: 'load_failed' },
				},
			],
		});
		expect(wait.disconnected()).toBe(false);
		wait.publishOwnerMessage(viewRecovery('ready'));
		wait.publishSuccessor({
			contentState: 'ready',
			paintedSha: 'old-sha',
			renderedItemId: 'selected-file',
		});
		expect(wait.disconnected()).toBe(false);
		wait.publishSuccessor({
			contentState: 'ready',
			paintedSha: 'new-sha',
			renderedItemId: 'selected-file',
		});
		await wait.outcome;
		expect(wait.disconnected()).toBe(true);
	} finally {
		wait.retire();
		await Promise.allSettled([wait.outcome]);
	}
});

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

test('cached File predecessor failure stays pending while replacement bootstrap is held', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		sessionState: 'replacement_requested',
		ownerFailure: 'file-refresh:producerRejected',
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	// The predecessor still exists in observation; only the owning session has retired it.
	// pagehide closes the negative interval without releasing the successor bootstrap.
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('the diagnostic replacement callback excludes a late predecessor failure before successor bootstrap', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		withDiagnosticLifecycle: true,
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	await wait.diagnosticSubscription;
	wait.publishWorkerSessionState('replacement_requested');
	wait.publishFailureAfterCanvasRemoval();
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test('successor ready settles held replacement only with the requested item and exact SHA', async () => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		sessionState: 'replacement_requested',
		ownerFailure: 'file-refresh:producerRejected',
		withDiagnosticLifecycle: true,
	});
	await wait.diagnosticSubscription;
	wait.publishSuccessor({
		contentState: 'ready',
		paintedSha: 'new-sha',
		renderedItemId: 'selected-file',
	});
	await wait.outcome;
	expect(wait.disconnected()).toBe(true);
});

test.each([
	{ contentState: 'ready', paintedSha: 'old-sha', renderedItemId: 'selected-file' },
	{ contentState: 'loading', paintedSha: 'new-sha', renderedItemId: 'selected-file' },
	{ contentState: 'ready', paintedSha: 'new-sha', renderedItemId: 'another-file' },
])('an incomplete successor cannot settle held replacement: %j', async (state) => {
	const wait = runWaitScript({
		target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
		sessionState: 'replacement_requested',
		ownerFailure: 'file-refresh:producerRejected',
		withDiagnosticLifecycle: true,
	});
	const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
	await wait.diagnosticSubscription;
	wait.publishSuccessor(state);
	wait.retire();
	await assertion;
	expect(wait.disconnected()).toBe(true);
});

test.each(['awaiting_bootstrap', 'bootstrapping', 'disposed'] as const)(
	'cached predecessor failures cannot end a wait while the owner is %s',
	async (sessionState) => {
		const wait = runWaitScript({
			target: { surface: 'file', itemId: 'selected-file', expectedSha256: 'new-sha' },
			sessionState,
			ownerFailure: 'file-refresh:producerRejected',
		});
		const assertion = expect(wait.outcome).rejects.toThrow('document-retired');
		wait.retire();
		await assertion;
		expect(wait.disconnected()).toBe(true);
	},
);
