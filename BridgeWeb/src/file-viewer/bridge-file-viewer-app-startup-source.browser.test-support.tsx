import { expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

import { BridgeFileViewerBrowserHarnessApp as BridgeFileViewerApp } from './bridge-file-viewer-browser-test-app.js';
import {
	makeBrowserFileBatchWithDescriptors,
	makeBrowserFileDescriptorOutcome,
} from './bridge-file-viewer-browser-test-batches.js';
import { waitForMetadataTreeRowCount } from './bridge-file-viewer-browser-test-harness.js';

export function registerFileSourceDiscoveryTest(): void {
	test('discovers File source and opens one typed metadata subscription', async () => {
		let sourceCallCount = 0;
		let subscriptionOpenCount = 0;
		await render(
			<BridgeFileViewerApp
				initialFileBatch={makeBrowserFileBatchWithDescriptors(
					'open',
					makeBrowserFileDescriptorOutcome({ path: 'src/app.ts' }),
				)}
				fileProductSession={{
					currentSource: () => {
						sourceCallCount += 1;
						return {
							status: 'available',
							source: {
								cwdScope: null,
								freshness: 'live',
								includeStatuses: true,
								repoId: '00000000-0000-4000-8000-000000000001',
								rootPathToken: 'root-token',
								worktreeId: '00000000-0000-4000-8000-000000000002',
							},
						};
					},
					onMetadataSubscriptionOpen: () => {
						subscriptionOpenCount += 1;
					},
				}}
			/>,
		);

		await waitForMetadataTreeRowCount(2);
		expect(sourceCallCount).toBe(1);
		expect(subscriptionOpenCount).toBe(1);
	});
}
