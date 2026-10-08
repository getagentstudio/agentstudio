import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatch,
	makeBrowserFileDescriptorOutcomeForContent,
	makeBrowserFileRow,
	makeBrowserFileSourceIdentity,
	type PublishBrowserFileBatch,
} from './bridge-file-viewer-browser-test-batches.js';
import {
	fileNavigationCommandForPath,
	makeFileContent,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actUpdate,
	waitForOpenFileState,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';

export function registerBridgeFileViewerSourceSnapshotDemandTest(): void {
	test('opens a selected metadata-only file when certified descriptor coverage installs', async () => {
		const path = 'src/source-snapshot-demand.ts';
		const replacementContent = makeFileContent('export const sourceSnapshotDemandFresh = true;\n');
		const replacementSource = makeBrowserFileSourceIdentity({
			sourceCursor: 'cursor-2',
			subscriptionGeneration: 2,
		});
		const replacementDescriptor = await makeBrowserFileDescriptorOutcomeForContent({
			content: replacementContent,
			descriptorId: 'source-snapshot-demand-content-2',
			fileId: 'file-source-snapshot-demand',
			path,
			source: replacementSource,
		});
		let publishFileBatch: PublishBrowserFileBatch | null = null;

		await render(
			<BridgeFileViewerApp
				codeViewWorkerPoolEnabled={false}
				initialFileBatch={makeBrowserFileBatch({
					snapshotCause: 'open',
					rows: [makeBrowserFileRow({ path, fileId: 'file-source-snapshot-demand' })],
				})}
				navigationCommand={fileNavigationCommandForPath(path)}
				fileProductSession={{
					readContent: async () => replacementContent,
					onFileBatchPublisher: (publisher) => {
						publishFileBatch = publisher;
					},
				}}
			/>,
		);

		await waitForOpenFileState('loading');
		if (publishFileBatch === null) throw new Error('Expected File batch publisher.');
		const publishRequiredFileBatch: PublishBrowserFileBatch = publishFileBatch;
		await actUpdate(() => {
			publishRequiredFileBatch(
				makeBrowserFileBatch({
					snapshotCause: 'open',
					rows: [makeBrowserFileRow({ path, descriptorOutcome: replacementDescriptor })],
					revision: 2,
					source: replacementSource,
				}),
			);
		});
		await waitForVisibleCodeText('sourceSnapshotDemandFresh');
		await waitForOpenFileState('ready');
		expect(document.querySelector('[data-testid="worktree-file-refresh"]')).toBeNull();
	});
}
