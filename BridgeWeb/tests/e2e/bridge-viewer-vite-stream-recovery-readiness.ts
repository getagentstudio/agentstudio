import type { Page } from 'playwright';

import type { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';

export async function waitForStreamRecoveryFilePaint(props: {
	readonly page: Page;
	readonly expectedSha256: string;
	readonly streamState: 'direct' | 'healthy' | 'disconnected';
	readonly testLaunch: BridgeWebTestLaunch;
}): Promise<void> {
	await props.testLaunch
		.observeStep(
			`File metadata ${props.streamState}: selected File ready and painted source ${props.expectedSha256}`,
			props.page.evaluate(
				(expectedSha256: string): Promise<void> =>
					new Promise((resolve, reject): void => {
						const inspect = (): void => {
							try {
								const canvas = document.querySelector(
									'[data-testid="bridge-file-viewer-code-canvas"]',
								);
								const painted = canvas?.querySelector(
									'diffs-container[data-bridge-painted-source-correlations]',
								);
								const correlations: unknown = JSON.parse(
									painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
								);
								if (
									canvas?.getAttribute('data-worktree-open-file-state') !== 'ready' ||
									!Array.isArray(correlations) ||
									!correlations.some(
										(correlation: unknown): boolean =>
											typeof correlation === 'object' &&
											correlation !== null &&
											'observedSha256' in correlation &&
											correlation.observedSha256 === expectedSha256,
									)
								)
									return;
								observer.disconnect();
								resolve();
							} catch (error: unknown) {
								observer.disconnect();
								reject(error);
							}
						};
						const observer = new MutationObserver(inspect);
						observer.observe(document, { attributes: true, childList: true, subtree: true });
						inspect();
					}),
				props.expectedSha256,
			),
		)
		.value();
}
