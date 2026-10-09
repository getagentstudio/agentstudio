import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { z } from 'zod';

import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the real app's bootstrap callbacks and recovery UI.
import './bridge-app.css';
import type { BridgePaneCommWorkerSessionDiagnosticSnapshot } from '../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import {
	actUpdate,
	actWait,
	installControlledBridgeReadyHandshake,
} from './bridge-app-browser-test-actions.js';
import { BridgeAppProtocolRouter } from './bridge-app-protocol-router.js';

const bootstrapRequestSchema = z
	.object({ reason: z.enum(['initial', 'workerReplacement']), requestId: z.string() })
	.strict();

describe('BridgeApp initial bootstrap failure recovery', () => {
	let runtime: BridgePaneRuntime | null = null;
	afterEach(async (): Promise<void> => {
		await actWait(async (): Promise<void> => cleanup());
		runtime?.dispose();
		runtime = null;
		document.body.replaceChildren();
	});

	test('initial native failure reaches the bounded terminal state and exposes its actual pre-E3 presentation', async () => {
		let reloadRequestCount = 0;
		const requests: z.infer<typeof bootstrapRequestSchema>[] = [];
		const snapshots: BridgePaneCommWorkerSessionDiagnosticSnapshot[] = [];
		const receiveRequest = (event: Event): void => {
			if (!('detail' in event)) throw new Error('Missing native bootstrap request detail.');
			requests.push(bootstrapRequestSchema.parse(event.detail));
		};
		document.addEventListener('__bridge_product_session_bootstrap_request', receiveRequest);
		const ready = installControlledBridgeReadyHandshake();
		const paneRuntime = createBridgePaneRuntime({
			sessionProps: {
				bootstrapTimeoutMilliseconds: pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
				recordDiagnosticSnapshot: (snapshot): void => {
					snapshots.push(snapshot);
				},
			},
		});
		runtime = paneRuntime;
		try {
			await actWait(async (): Promise<void> => {
				await render(
					<BridgeAppProtocolRouter
						paneReloadPort={{
							command: 'reloadBridgeWebView',
							display: {
								accessibleName: 'Retry pane',
								label: 'Retry pane',
								helpText: 'Native command display stand-in',
								icon: null,
							},
							requestPaneReload: (): void => {
								reloadRequestCount += 1;
							},
						}}
						codeViewWorkerPoolEnabled={false}
						fileViewerProps={{ autoOpenInitialFile: false }}
						paneRuntime={paneRuntime}
						protocol="review"
					/>,
				);
			});
			expect(requests).toHaveLength(1);
			expect(requests[0]?.reason).toBe('initial');
			await actUpdate(ready.acknowledgeReady);
			const refuseLatestRequest = (): void => {
				const request = requests.at(-1);
				if (request === undefined) throw new Error('Expected current native bootstrap request.');
				document.dispatchEvent(
					new CustomEvent('__bridge_product_session_bootstrap', {
						detail: { requestId: request.requestId, failure: { reason: 'activation_failed' } },
					}),
				);
			};
			await actUpdate(refuseLatestRequest);
			expect(requests).toHaveLength(2);
			expect(requests[1]?.reason).toBe('workerReplacement');
			expect(snapshots.at(-1)).toMatchObject({
				state: 'replacement_requested',
				replacementRequestCount: 1,
			});
			for (let attempt = 0; attempt < 4; attempt += 1) {
				// eslint-disable-next-line no-await-in-loop -- Deliver each admitted native reply, not a timing wait.
				await actUpdate(refuseLatestRequest);
			}
			expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(4);
			expect(snapshots.at(-1)).toMatchObject({
				state: 'failed',
				failureReason: 'bootstrapBudgetExhausted',
				queuedCommandCount: 0,
			});
			expect(
				paneRuntime.surfaceClient('review').renderStore.getViewRecoveryStatus('review.metadata'),
			).toBeNull();
			const presentation = {
				empty: document.querySelector('[data-testid="bridge-review-empty-shell"]') !== null,
				failed:
					document.querySelector('[data-testid="bridge-review-metadata-failed-shell"]') !== null,
				loading:
					document.querySelector('[data-testid="bridge-review-metadata-loading-shell"]') !== null,
				projecting:
					document.querySelector('[data-testid="bridge-review-projection-pending-shell"]') !== null,
				text: document.body.innerText,
			};
			expect(
				document
					.querySelector('[data-bridge-region="pane-failure"]')
					?.getAttribute('data-presentation-state'),
			).toBe('failed');
			expect(presentation.text).toContain("Bridge couldn't start.");
			expect(presentation.text).not.toMatch(
				/Waiting for review metadata|Choose a comparison target/,
			);
			for (const region of ['review-content', 'review-tree'])
				expect(
					document
						.querySelector(`[data-bridge-region="${region}"]`)
						?.getAttribute('data-presentation-state'),
				).toBe('failed');
			expect(document.querySelectorAll('[role="alert"]')).toHaveLength(1);
			await actUpdate(async (): Promise<void> => {
				document.querySelector<HTMLButtonElement>('button[aria-label="Retry pane"]')?.click();
			});
			expect(reloadRequestCount).toBe(1);
			expect(requests.filter((request) => request.reason === 'workerReplacement')).toHaveLength(4);
		} finally {
			document.removeEventListener('__bridge_product_session_bootstrap_request', receiveRequest);
			ready.dispose();
		}
	});
});
