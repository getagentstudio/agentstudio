// oxlint-disable unicorn/require-post-message-target-origin -- MessagePort postMessage does not accept a target origin.
import { describe, expect, test, vi } from 'vitest';

import pageConfigurationFixture from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import { BridgePaneCommWorkerSession } from './bridge-pane-comm-worker-session.js';
import {
	MessagePortRecorder,
	RecordingPaneCommWorker,
	RecordingPaneCommWorkerClient,
	createDeferredVoid,
	flushMicrotasks,
	makeNativeBootstrap,
	makeReadyHealth,
	makeRuntimeBootstrapRequest,
	makeSelectCommand,
} from './bridge-pane-comm-worker-session.test-support.js';
import { bridgePaneCommWorkerInstallSchema } from './bridge-product-session-contracts.js';
import { bridgeWorkerMainToServerMessageSchema } from './bridge-worker-contracts.js';

describe('Bridge pane comm worker session suspect recovery', () => {
	test('a typed suspect request replaces only the matching worker and serves the next command', async () => {
		const firstWorker = new RecordingPaneCommWorker();
		const secondWorker = new RecordingPaneCommWorker();
		const workerFactory = vi
			.fn<() => Worker>()
			.mockReturnValueOnce(firstWorker)
			.mockReturnValueOnce(secondWorker);
		const replacementRequest = createDeferredVoid();
		const replacementReasons: string[] = [];
		const replacementFacts: unknown[] = [];
		const session = new BridgePaneCommWorkerSession({
			bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
			recordDiagnosticSnapshot: (snapshot): void => {
				if (snapshot.state === 'replacement_requested') {
					replacementFacts.push(snapshot.lastReplacementReason);
				}
			},
			requestNativeBootstrap: (reason): void => {
				replacementReasons.push(reason);
				replacementRequest.resolve();
			},
			workerFactory,
		});
		const bootstrapRequest = makeRuntimeBootstrapRequest('suspect-bootstrap');
		const client = new RecordingPaneCommWorkerClient();
		const dispatcher = session.createDispatcher({
			bootstrapRequest,
			publishWorkerMessages: client.publish,
		});
		let firstPort: MessagePortRecorder | null = null;
		let secondPort: MessagePortRecorder | null = null;

		try {
			session.installNativeBootstrap(makeNativeBootstrap('suspect-worker-1'));
			await flushMicrotasks();
			const firstInstall = bridgePaneCommWorkerInstallSchema.parse(
				firstWorker.globalPosts[0]?.message,
			);
			firstPort = new MessagePortRecorder(firstInstall.productPort);
			await firstPort.waitForCount(1);
			const firstReady = client.waitForCount(1);
			firstInstall.productPort.postMessage(makeReadyHealth(bootstrapRequest.requestId));
			await firstReady;

			firstInstall.productPort.postMessage({
				ackAttemptOutcomes: [],
				droppedPriorControlRequestCount: 0,
				direction: 'serverWorkerToMain',
				kind: 'sessionSuspect',
				paneSessionId: firstInstall.bootstrap.paneSessionId,
				priorControlRequests: [],
				reason: 'admissionReplyExhausted',
				transferDescriptors: [],
				wireVersion: 1,
				workerInstanceId: firstInstall.bootstrap.workerInstanceId,
			});
			const suspectDisposition = await Promise.race([
				replacementRequest.promise.then((): 'replacement' => 'replacement'),
				client.waitForCount(2).then((): 'invalidMessage' => 'invalidMessage'),
			]);
			expect(suspectDisposition).toBe('replacement');
			expect(replacementReasons).toEqual(['workerReplacement']);
			expect(replacementFacts).toEqual([
				{
					ackAttemptOutcomes: [],
					droppedPriorControlRequestCount: 0,
					kind: 'sessionSuspect',
					priorControlRequests: [],
					reason: 'admissionReplyExhausted',
				},
			]);
			expect(firstWorker.terminateCount).toBe(1);

			session.installNativeBootstrap(makeNativeBootstrap('suspect-worker-2'));
			await flushMicrotasks();
			const secondInstall = bridgePaneCommWorkerInstallSchema.parse(
				secondWorker.globalPosts[0]?.message,
			);
			secondPort = new MessagePortRecorder(secondInstall.productPort);
			await secondPort.waitForCount(1);
			const secondReady = client.waitForCount(2);
			secondInstall.productPort.postMessage(makeReadyHealth(bootstrapRequest.requestId));
			await secondReady;
			dispatcher.dispatch(makeSelectCommand('after-suspect', 1, 'item-after', 'review'));
			const replacementMessages = await secondPort.waitForCount(2);
			expect(bridgeWorkerMainToServerMessageSchema.parse(replacementMessages[1]).requestId).toBe(
				'after-suspect',
			);
			expect(replacementReasons).toEqual(['workerReplacement']);
		} finally {
			firstPort?.close();
			secondPort?.close();
			dispatcher.dispose();
			session.dispose();
		}
	});
});
