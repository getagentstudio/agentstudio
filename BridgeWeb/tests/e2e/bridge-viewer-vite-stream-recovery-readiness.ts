import type { Page } from 'playwright';

import type { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { waitForSelectedContentOwnerReady } from './bridge-viewer-vite-selected-content-wait.ts';

export async function waitForStreamRecoveryFilePaint(props: {
	readonly page: Page;
	readonly itemId?: string;
	readonly expectedSha256: string;
	readonly streamState: 'direct' | 'healthy' | 'disconnected';
	readonly testLaunch: BridgeWebTestLaunch;
}): Promise<void> {
	await props.testLaunch
		.observeStep(
			`File metadata ${props.streamState}: selected File ready and painted source ${props.expectedSha256}`,
			waitForSelectedContentOwnerReady({
				page: props.page,
				label: `File metadata ${props.streamState} selected content`,
				target: {
					surface: 'file',
					expectedSha256: props.expectedSha256,
					...(props.itemId === undefined ? {} : { itemId: props.itemId }),
				},
			}),
		)
		.value();
}
