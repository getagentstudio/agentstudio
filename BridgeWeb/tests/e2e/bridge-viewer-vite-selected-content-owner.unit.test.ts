import { runInNewContext } from 'node:vm';

import { expect, test } from 'vitest';

import { publishBridgeCommWorkerUpdatingChrome } from '../../src/core/comm-worker/bridge-comm-worker-updating-chrome.js';
import {
	bridgeWorkerFileRenderPatchEventSchema,
	bridgeWorkerSelectCommandSchema,
	type BridgeWorkerServerToMainWireMessage,
} from '../../src/core/comm-worker/bridge-worker-contracts.js';
import { bridgeWorkerViewRecoveryStatusEventSchema } from '../../src/core/comm-worker/bridge-worker-view-recovery-contracts.js';
import {
	selectedContentTerminalFailure,
	createSelectedContentOwnerRecorder,
	type SelectedContentOwnerIdentity,
} from './bridge-viewer-vite-selected-content-owner.ts';

const current = {
	channelId: 2,
	itemId: 'selected-file',
	workerDerivationEpoch: 7,
	publicationId: 'publication-current',
} satisfies SelectedContentOwnerIdentity;

test.each(['content_unavailable'] as const)(
	'ends a selected File read from the current owner reason %s',
	(reason) => {
		expect(
			selectedContentTerminalFailure({
				surface: 'file',
				current,
				observed: current,
				availability: { state: 'unavailable', reason },
			}),
		).toEqual({ ...current, state: 'unavailable', reason });
	},
);

test('a terminal selected Review load failure retains the exact publication and reason', () => {
	expect(
		selectedContentTerminalFailure({
			surface: 'review',
			current,
			observed: current,
			availability: { state: 'failed', reason: 'load_failed' },
		}),
	).toEqual({ ...current, state: 'failed', reason: 'load_failed' });
});

test.each([
	{ ...current, itemId: 'another-file' },
	{ ...current, channelId: 1 },
	{ ...current, workerDerivationEpoch: 6 },
	{ ...current, publicationId: 'retired-publication' },
])('ignores a failed operation outside the current identity: %j', (observed) => {
	expect(
		selectedContentTerminalFailure({
			surface: 'review',
			current,
			observed,
			availability: { state: 'failed', reason: 'load_failed' },
		}),
	).toBeNull();
});

test('File load_failed remains pending because its owner may automatically retry', () => {
	expect(
		selectedContentTerminalFailure({
			surface: 'file',
			current,
			observed: current,
			availability: { state: 'failed', reason: 'load_failed' },
		}),
	).toBeNull();
});

test.each(['loading', 'stale', 'ready'] as const)(
	'keeps %s pending for the paint oracle',
	(state) => {
		expect(
			selectedContentTerminalFailure({
				surface: 'review',
				current,
				observed: current,
				availability: { state },
			}),
		).toBeNull();
	},
);

test('source reset does not terminate automatic successor recovery', () => {
	expect(
		selectedContentTerminalFailure({
			surface: 'review',
			current,
			observed: current,
			availability: { state: 'unavailable', reason: 'source_reset' },
		}),
	).toBeNull();
});

function selectedFileRecorder(): ReturnType<typeof createSelectedContentOwnerRecorder> {
	const recorder = createSelectedContentOwnerRecorder(selectedContentTerminalFailure);
	recorder.observe(1, { method: 'bridgeCommWorker.bootstrap' });
	recorder.observe(
		1,
		bridgeWorkerSelectCommandSchema.parse({
			wireVersion: 1,
			direction: 'mainToServerWorker',
			kind: 'command',
			command: 'select',
			requestId: 'select-file-1',
			epoch: 3,
			surface: 'fileView',
			selectedItemId: 'selected-file',
			selectedSource: 'programmatic',
			transferDescriptors: [],
		}),
	);
	recorder.observe(1, {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'fileDisplayPatch',
		surface: 'fileView',
		epoch: 7,
	});
	return recorder;
}

function fileRecoveryStatus(
	status: 'recovering' | 'ready' | 'failedRetryable',
	subscriptionId: string = 'file-subscription',
): unknown {
	return bridgeWorkerViewRecoveryStatusEventSchema.parse({
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'viewRecoveryStatus',
		transferDescriptors: [],
		view: { kind: 'file.metadata', subscriptionId },
		status,
	});
}

test('File view recovery exhaustion retains the existing subscription owner fact', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(1, fileRecoveryStatus('recovering'));
	expect(recorder.read('file').failure).toBeNull();
	recorder.observe(1, fileRecoveryStatus('failedRetryable'));
	expect(recorder.read('file').failure).toMatchObject({
		itemId: 'selected-file',
		reason: 'file-view-recovery:failedRetryable:file-subscription',
	});
});

test('a retired File subscription and worker cannot fail the current recovery', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(1, fileRecoveryStatus('recovering', 'old-subscription'));
	recorder.observe(1, fileRecoveryStatus('recovering'));
	recorder.observe(1, fileRecoveryStatus('failedRetryable', 'old-subscription'));
	recorder.observe(0, fileRecoveryStatus('failedRetryable'));
	expect(recorder.read('file').failure).toBeNull();
	recorder.observe(1, fileRecoveryStatus('ready'));
	expect(recorder.read('file').failure).toBeNull();
});

function unavailableFilePatch(
	props: {
		readonly epoch?: number;
		readonly itemId?: string;
		readonly sequence?: number;
	} = {},
): unknown {
	return bridgeWorkerFileRenderPatchEventSchema.parse({
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'fileRenderPatch',
		surface: 'file',
		workerDerivationEpoch: props.epoch ?? 7,
		publicationSequence: props.sequence ?? 10,
		patches: [
			{
				slice: 'contentAvailability',
				operation: 'upsert',
				itemId: props.itemId ?? 'selected-file',
				payload: { state: 'unavailable', reason: 'content_unavailable' },
			},
		],
	});
}

test('the port recorder retains the current selected operation reason from the real wire shape', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(1, unavailableFilePatch());
	expect(recorder.read('file')).toMatchObject({
		selectedItemId: 'selected-file',
		selectionRequestId: 'select-file-1',
		phase: 'content-result',
		failure: { reason: 'content_unavailable', workerDerivationEpoch: 7 },
	});
});

test('another item, retired channel, source and out-of-order patch cannot end the current wait', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(0, unavailableFilePatch());
	recorder.observe(1, unavailableFilePatch({ itemId: 'unselected-file' }));
	recorder.observe(1, unavailableFilePatch({ epoch: 6 }));
	expect(recorder.read('file').failure).toBeNull();
	recorder.observe(1, unavailableFilePatch({ sequence: 11 }));
	expect(recorder.read('file').failure?.reason).toBe('content_unavailable');
	recorder.observe(1, {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		kind: 'fileDisplayPatch',
		surface: 'fileView',
		epoch: 8,
	});
	recorder.observe(1, unavailableFilePatch({ epoch: 7, sequence: 12 }));
	expect(recorder.read('file').failure).toBeNull();
});

test('worker replacement clears the predecessor failure and ignores its late messages', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(1, unavailableFilePatch());
	recorder.observe(2, { method: 'bridgeCommWorker.bootstrap' });
	recorder.observe(1, unavailableFilePatch());
	expect(recorder.read('file').selectedItemId).toBeNull();
	expect(recorder.read('file').failure).toBeNull();
});

test('an older terminal patch cannot overwrite the current ready content result', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(1, unavailableFilePatch({ sequence: 10 }));
	recorder.observe(
		1,
		bridgeWorkerFileRenderPatchEventSchema.parse({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'fileRenderPatch',
			surface: 'file',
			workerDerivationEpoch: 7,
			publicationSequence: 12,
			patches: [
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'selected-file',
					payload: { state: 'ready' },
				},
			],
		}),
	);
	recorder.observe(1, unavailableFilePatch({ sequence: 11 }));
	expect(recorder.read('file').failure).toBeNull();
});

test('the init-script reducer runs in a fresh realm without imported globals', () => {
	const result: unknown = runInNewContext(`
		const recorder = (${createSelectedContentOwnerRecorder.toString()})(${selectedContentTerminalFailure.toString()});
		recorder.observe(1, { method: 'bridgeCommWorker.bootstrap' });
		recorder.read('file').phase;
	`);
	expect(result).toBe('awaiting-selection');
});

test.each(['descriptor_missing', 'descriptor_rejected'] as const)(
	'File %s cannot end recovery while an automatic successor may exist',
	(reason) => {
		expect(
			selectedContentTerminalFailure({
				surface: 'file',
				current,
				observed: current,
				availability: { state: 'unavailable', reason },
			}),
		).toBeNull();
	},
);

const finalRefreshFailures = [
	{ failureKind: 'missingRoot', retryable: true },
	{ failureKind: 'unreadableRoot', retryable: true },
	{ failureKind: 'fileRefreshFailed', retryable: false },
	{ failureKind: 'fileSourceUnavailable', retryable: true },
	{ failureKind: 'producerRejected', retryable: false },
] as const;

test.each(finalRefreshFailures)(
	'ends on the current native refresh owner final fact $failureKind, even when explicit Retry is allowed',
	(fileRefreshFailure) => {
		const recorder = selectedFileRecorder();
		recorder.observe(
			1,
			bridgeWorkerFileRenderPatchEventSchema.parse({
				wireVersion: 1,
				direction: 'serverWorkerToMain',
				transferDescriptors: [],
				kind: 'fileRenderPatch',
				surface: 'file',
				workerDerivationEpoch: 7,
				publicationSequence: 11,
				patches: [{ slice: 'panelChrome', operation: 'upsert', payload: { fileRefreshFailure } }],
			}),
		);
		expect(recorder.read('file').failure).toMatchObject({
			itemId: 'selected-file',
			workerDerivationEpoch: 7,
			state: 'failed',
			reason: `file-refresh:${fileRefreshFailure.failureKind}`,
		});
	},
);

test('an old source refresh failure cannot end the new selected recovery', () => {
	const recorder = selectedFileRecorder();
	recorder.observe(
		1,
		bridgeWorkerFileRenderPatchEventSchema.parse({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'fileRenderPatch',
			surface: 'file',
			workerDerivationEpoch: 6,
			publicationSequence: 11,
			patches: [
				{
					slice: 'panelChrome',
					operation: 'upsert',
					payload: {
						fileRefreshFailure: { failureKind: 'producerRejected', retryable: false },
					},
				},
			],
		}),
	);
	expect(recorder.read('file').failure).toBeNull();
});

test('the real updating-chrome emitter delivers the final refresh reason to the recorder', () => {
	const recorder = selectedFileRecorder();
	const messages: BridgeWorkerServerToMainWireMessage[] = [];
	publishBridgeCommWorkerUpdatingChrome({
		activeFileWorkerDerivationEpoch: 7,
		activeReviewSourceIdentity: null,
		activeReviewPublicationIdentity: null,
		activeReviewWorkerDerivationEpoch: null,
		activeViewerMode: 'file',
		createSequence: (): number => 20,
		previousPublicationIdentity: undefined,
		previousReviewComparison: null,
		presentation: {
			nativeActivity: 'foreground',
			workAdmissionGeneration: 0,
			presentationRevision: 4,
			refreshingLanes: [],
			fileRefreshFailure: { failureKind: 'producerRejected', retryable: false },
			reviewComparison: null,
		},
		publish: (message): void => {
			messages.push(message);
		},
		publishCertifiedNoSourceComparison: (): void => {},
		surface: 'file',
		telemetryClient: undefined,
	});
	for (const message of messages) recorder.observe(1, message);
	expect(recorder.read('file').failure?.reason).toBe('file-refresh:producerRejected');
	// Last-complete content may still announce ready after native refresh has failed.
	recorder.observe(
		1,
		bridgeWorkerFileRenderPatchEventSchema.parse({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'fileRenderPatch',
			surface: 'file',
			workerDerivationEpoch: 7,
			publicationSequence: 21,
			patches: [
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'selected-file',
					payload: { state: 'ready' },
				},
			],
		}),
	);
	expect(recorder.read('file').failure?.reason).toBe('file-refresh:producerRejected');
	recorder.observe(
		1,
		bridgeWorkerFileRenderPatchEventSchema.parse({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'fileRenderPatch',
			surface: 'file',
			workerDerivationEpoch: 7,
			publicationSequence: 22,
			patches: [
				{ slice: 'panelChrome', operation: 'upsert', payload: { fileRefreshFailure: null } },
			],
		}),
	);
	expect(recorder.read('file').failure).toBeNull();
});
