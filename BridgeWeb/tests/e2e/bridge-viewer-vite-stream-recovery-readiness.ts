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
	if (props.itemId !== undefined) {
		await props.testLaunch
			.observeStep(
				`File metadata ${props.streamState}: invalidation delivery and new descriptor prepared for source ${props.expectedSha256}`,
				waitForSelectedContentOwnerReady({
					page: props.page,
					label: `File metadata ${props.streamState} new descriptor preparation`,
					target: {
						surface: 'file',
						itemId: props.itemId,
						expectedSha256: props.expectedSha256,
						goal: 'descriptor-prepared',
					},
				}),
			)
			.value();
		await props.testLaunch
			.observeStep(
				`File metadata ${props.streamState}: selected-content close for source ${props.expectedSha256}`,
				waitForSelectedContentOwnerReady({
					page: props.page,
					label: `File metadata ${props.streamState} selected-content close`,
					target: {
						surface: 'file',
						itemId: props.itemId,
						expectedSha256: props.expectedSha256,
						goal: 'content-closed',
					},
				}),
			)
			.value();
	}
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
