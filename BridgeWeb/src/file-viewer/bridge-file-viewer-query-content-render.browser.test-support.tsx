import { expect } from 'vitest';
import { render } from 'vitest-browser-react';

import { BridgeTestFactRecorder } from '../../tests/test-support/bridge-test-fact-recorder.js';
import type { BridgePaneSessionPort } from '../core/comm-worker/bridge-pane-runtime.js';
import type {
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainWireMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	BridgeFileViewerBrowserHarnessApp,
	type BridgeFileViewerBrowserTestProductSession,
} from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcomeForContent,
} from './bridge-file-viewer-browser-test-batches.js';
import { createBridgeFileViewerBrowserTestPaneSessionFactory } from './bridge-file-viewer-browser-test-comm-worker.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actUpdate,
	makeDeferredContent,
	waitForMetadataTreeRowCount,
	waitForOpenFileState,
} from './bridge-file-viewer-browser-test-harness.js';

/** Content-ready is not the worker's terminal render disposition. */
export async function assertUnchangedQueryContentPublication(props: {
	readonly holdApplied: boolean;
	readonly signal: AbortSignal;
}): Promise<void> {
	const content = makeFileContent('export const queryLifecycle = "settled";\n');
	const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
		content,
		descriptorId: 'query-lifecycle-content',
		fileId: 'file-query-lifecycle',
		path: 'src/query-lifecycle.ts',
	});
	const dispatchedMessages: BridgeWorkerMainToServerMessage[] = [];
	const commandFacts = new BridgeTestFactRecorder<BridgeWorkerMainToServerMessage>();
	const workerFacts = new BridgeTestFactRecorder<BridgeWorkerServerToMainWireMessage>();
	const deferredContent = makeDeferredContent();
	const fileProductSession = {
		onWorkerCommand: (message: BridgeWorkerMainToServerMessage): void => {
			dispatchedMessages.push(message);
			commandFacts.record(message);
		},
		readContent: (): Promise<string> => deferredContent.promise,
	} satisfies BridgeFileViewerBrowserTestProductSession;
	const initialFileBatch = makeBrowserFileBatchWithDescriptors('open', descriptor);
	const baseFactory = createBridgeFileViewerBrowserTestPaneSessionFactory({
		observeAppliedWorkerMessage: (message): void => workerFacts.record(message),
		productSessionRef: { current: { ...fileProductSession, initialFileBatch } },
	});
	const heldFacts = new BridgeTestFactRecorder<BridgeWorkerMainToServerMessage>();
	const heldDeliveries: Array<() => void> = [];
	let released = false;
	const fileViewPaneSessionFactory = Object.assign(
		(): BridgePaneSessionPort => {
			const session = baseFactory();
			return {
				...session,
				createDispatcher: (dispatcherProps) => {
					const dispatcher = session.createDispatcher(dispatcherProps);
					return {
						...dispatcher,
						dispatch: (message: BridgeWorkerMainToServerMessage): void => {
							if (
								props.holdApplied &&
								!released &&
								message.command === 'renderDisposition' &&
								message.receipts.some(
									(receipt) =>
										receipt.kind === 'render.disposition' &&
										receipt.itemId === descriptor.fileId &&
										(receipt.disposition === 'applied' || receipt.disposition === 'painted'),
								)
							) {
								heldDeliveries.push((): void => dispatcher.dispatch(message));
								heldFacts.record(message);
								return;
							}
							dispatcher.dispatch(message);
						},
					};
				},
			};
		},
		{ renderStoreFactory: baseFactory.renderStoreFactory },
	);
	const close = (): void => {
		const error = new Error('File query content render observation owner retired.');
		commandFacts.close(error);
		workerFacts.close(error);
		heldFacts.close(error);
	};
	props.signal.addEventListener('abort', close, { once: true });
	try {
		await render(
			<BridgeFileViewerBrowserHarnessApp
				autoOpenInitialFile={true}
				fileProductSession={fileProductSession}
				fileViewPaneSessionFactory={fileViewPaneSessionFactory}
				initialFileBatch={initialFileBatch}
			/>,
		);
		await waitForMetadataTreeRowCount(2);
		await waitForOpenFileState('loading');
		await actUpdate((): void => {
			deferredContent.resolve(content);
		});
		await waitForOpenFileState('ready');

		const publication = await workerFacts.waitFor(
			(message): boolean =>
				message.kind === 'filePierreRenderJob' &&
				message.renderReceiptIdentity.itemId === descriptor.fileId,
			'the selected File content render publication',
		);
		if (publication.kind !== 'filePierreRenderJob')
			throw new Error('Expected selected File render publication.');
		if (props.holdApplied) {
			await heldFacts.waitFor(
				(message): boolean =>
					message.command === 'renderDisposition' &&
					message.receipts.some(
						(receipt) =>
							receipt.kind === 'render.disposition' &&
							receipt.disposition === 'applied' &&
							receipt.publicationId === publication.renderReceiptIdentity.publicationId &&
							receipt.attemptId === publication.renderReceiptIdentity.attemptId,
					),
				'the File applied receipt held before worker delivery',
			);
			const queuedCommand = await commandFacts.waitFor(
				(message): boolean =>
					message.command === 'renderDisposition' &&
					message.receipts.some(
						(receipt) =>
							receipt.kind === 'render.disposition' &&
							receipt.disposition === 'queued' &&
							receipt.publicationId === publication.renderReceiptIdentity.publicationId &&
							receipt.attemptId === publication.renderReceiptIdentity.attemptId,
					),
				'the selected File queued disposition command',
			);
			await workerFacts.waitFor(
				(message): boolean =>
					message.kind === 'health' &&
					message.requestId === queuedCommand.requestId &&
					message.status === 'ready',
				'the worker acceptance arming the selected File queued lease',
			);
			expect(
				baseFactory.renderWakes().pendingWakeCount(),
				'The selected File queued lease remains armed while its applied receipt is withheld.',
			).toBe(1);
			// The query claim is already true while the terminal receipt remains undelivered.
			assertUnchangedQueryCommands(dispatchedMessages);
			await actUpdate((): void => {
				released = true;
				for (const delivery of heldDeliveries.splice(0)) delivery();
			});
		}
		const paintedCommand = await commandFacts.waitFor(
			(message): boolean =>
				message.command === 'renderDisposition' &&
				message.receipts.some(
					(receipt) =>
						receipt.kind === 'render.disposition' &&
						receipt.disposition === 'painted' &&
						receipt.publicationId === publication.renderReceiptIdentity.publicationId &&
						receipt.attemptId === publication.renderReceiptIdentity.attemptId,
				),
			'the selected File publication painted disposition command',
		);
		await workerFacts.waitFor(
			(message): boolean =>
				message.kind === 'health' &&
				message.requestId === paintedCommand.requestId &&
				message.status === 'ready',
			'the worker acceptance of the selected File painted disposition',
		);
		expect(
			baseFactory.renderWakes().pendingWakeCount(),
			'The accepted painted receipt discharges the File render lifecycle wake.',
		).toBe(0);
		assertUnchangedQueryCommands(dispatchedMessages);
	} finally {
		released = true;
		for (const delivery of heldDeliveries.splice(0)) delivery();
		props.signal.removeEventListener('abort', close);
		close();
	}
}

function assertUnchangedQueryCommands(messages: readonly BridgeWorkerMainToServerMessage[]): void {
	const queryUpdates = messages.filter((message): boolean => message.command === 'fileQueryUpdate');
	expect(queryUpdates).toHaveLength(1);
	expect(messages.filter((message): boolean => message.command === 'select')).toHaveLength(1);
}
