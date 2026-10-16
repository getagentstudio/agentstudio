import { act } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import type { BridgeTelemetrySample } from '../foundation/telemetry/bridge-telemetry-event.js';
import { waitForBridgeViewerTreeItemButton } from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { terminateBridgePierreWorkerPoolSingletonForTest } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { waitForFileViewerTreeItemButtonInAct } from './bridge-file-viewer-app-startup.browser.test-support.js';
import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
	makeBrowserFileDescriptorOutcomeForContent,
} from './bridge-file-viewer-browser-test-batches.js';
import { makeFileContent } from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actFrame,
	actUpdate,
	makeBrowserFileBatchPublisherObservation,
	makeTestTelemetryRecorder,
	settleBridgeFileViewerBrowserUpdates,
	waitForOpenFileState,
	waitForTelemetrySampleCount,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

describe('Bridge File activation telemetry', () => {
	afterEach(async () => {
		await settleBridgeFileViewerBrowserUpdates();
		await act(async (): Promise<void> => {
			await cleanup();
			await Promise.resolve();
		});
		await actFrame();
		document.body.replaceChildren();
		terminateBridgePierreWorkerPoolSingletonForTest();
	});

	test('records File TTFI when metadata arrives after the mounted tree setup frame', async () => {
		const publisherObservation = makeBrowserFileBatchPublisherObservation();
		const telemetrySamples: BridgeTelemetrySample[] = [];
		await render(
			<BridgeFileViewerApp
				isActive={true}
				telemetryRecorder={makeTestTelemetryRecorder(telemetrySamples)}
				fileProductSession={{
					onFileBatchPublisher: (publisher) => {
						publisherObservation.observe(publisher);
					},
				}}
			/>,
		);
		const publishFileBatch = await publisherObservation.publisher;
		await actFrame();
		await actFrame();

		await actUpdate(() => {
			publishFileBatch(
				makeBrowserFileBatchWithDescriptors(
					'open',
					makeBrowserFileDescriptorOutcome({
						descriptorId: 'delayed-ttfi-content',
						fileId: 'delayed-ttfi-file',
						path: 'src/delayed-ttfi.ts',
					}),
				),
			);
		});
		expect(await waitForBridgeViewerTreeItemButton('src/delayed-ttfi.ts')).not.toBeNull();

		const sample = await waitForTelemetrySampleCount({
			count: 1,
			name: 'performance.bridge.viewer.time_to_first_interaction',
			samples: telemetrySamples,
		});
		expect(sample.stringAttributes['agentstudio.bridge.viewer']).toBe('file');
	});

	test('records one File selection commit and one file-open-ready terminal', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const content = makeFileContent('export const activationTelemetryReady = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			descriptorId: 'activation-ready-content',
			fileId: 'activation-ready-file',
			path: 'src/activation-ready.ts',
		});

		await render(
			<BridgeFileViewerApp
				activationCause="review_file_corner"
				activationSequence={17}
				activationStartedAtPerfNow={performance.now()}
				isActive={true}
				initialFileBatch={makeBrowserFileBatchWithDescriptors('open', descriptor)}
				openPathCommand={{
					activationStartedAtPerfNow: performance.now(),
					commandId: 17,
					path: 'src/activation-ready.ts',
					traceContext: null,
				}}
				telemetryRecorder={makeTestTelemetryRecorder(telemetrySamples)}
				fileProductSession={{ readContent: async () => content }}
			/>,
		);

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('activationTelemetryReady');
		const selectionCommit = await waitForTelemetrySampleCount({
			count: 1,
			name: 'performance.bridge.web.selection_commit',
			samples: telemetrySamples,
		});
		const fileOpenReady = await waitForTelemetrySampleCount({
			count: 1,
			name: 'performance.bridge.web.file_open_ready',
			samples: telemetrySamples,
		});

		expect(selectionCommit.stringAttributes['agentstudio.bridge.viewer']).toBe('file');
		expect(fileOpenReady.stringAttributes['agentstudio.bridge.viewer']).toBe('file');
		expect(
			telemetrySamples.filter(
				(sample): boolean => sample.name === 'performance.bridge.web.file_open_ready',
			),
		).toHaveLength(1);
		expect(JSON.stringify([selectionCommit, fileOpenReady])).not.toContain('activation-ready.ts');
	});

	test('records context-switcher selection and open-ready without remounting File', async () => {
		const telemetrySamples: BridgeTelemetrySample[] = [];
		const content = makeFileContent('export const contextSwitcherReady = true;\n');
		const descriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content,
			descriptorId: 'context-switcher-ready-content',
			fileId: 'context-switcher-ready-file',
			path: 'src/context-switcher-ready.ts',
		});
		const telemetryRecorder = makeTestTelemetryRecorder(telemetrySamples);
		const fileProductSession = { readContent: async (): Promise<string> => content };
		const initialFileBatch = makeBrowserFileBatchWithDescriptors('open', descriptor);
		const { rerender } = await render(
			<BridgeFileViewerApp
				autoOpenInitialFile={true}
				initialFileBatch={initialFileBatch}
				isActive={false}
				telemetryRecorder={telemetryRecorder}
				fileProductSession={fileProductSession}
			/>,
		);
		await waitForFileViewerTreeItemButtonInAct({ path: 'src/context-switcher-ready.ts' });
		const activationStartedAtPerfNow = performance.now();

		await actUpdate(async () => {
			await rerender(
				<BridgeFileViewerApp
					activationCause="context_switcher"
					activationSequence={3}
					activationStartedAtPerfNow={activationStartedAtPerfNow}
					autoOpenInitialFile={true}
					initialFileBatch={initialFileBatch}
					isActive={true}
					telemetryRecorder={telemetryRecorder}
					fileProductSession={fileProductSession}
				/>,
			);
		});
		await actFrame();

		await waitForOpenFileState('ready');
		await waitForVisibleCodeText('contextSwitcherReady');
		const selectionCommit = await waitForTelemetrySampleCount({
			count: 1,
			name: 'performance.bridge.web.selection_commit',
			samples: telemetrySamples,
		});
		const fileOpenReady = await waitForTelemetrySampleCount({
			count: 1,
			name: 'performance.bridge.web.file_open_ready',
			samples: telemetrySamples,
		});

		expect(selectionCommit.stringAttributes['agentstudio.bridge.selection.origin']).toBe(
			'context_switcher',
		);
		expect(fileOpenReady.numericAttributes['agentstudio.bridge.demand.request.sequence']).toBe(3);
	});
});
