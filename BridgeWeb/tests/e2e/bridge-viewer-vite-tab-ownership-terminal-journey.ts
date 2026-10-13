import type { Browser, Page, Route } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import {
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import {
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import { waitForTabOwnershipReviewReady } from './bridge-viewer-vite-tab-ownership-test-support.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerTabOwnershipTerminalJourney(): void {
	test('reports the first tab terminal pane failure while its committed replacement bootstrap is held and a competing tab is refused', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			let server: BridgeViewerOwnedViteProductServer | null = null;
			let browser: Browser | null = null;
			let firstTab: Page | null = null;
			let primaryFailure: { readonly error: unknown } | null = null;
			const heldCommit = createBridgeProductDeferred<void>();
			const releaseRoutes = createBridgeProductDeferred<void>();
			const routeJobs: Promise<void>[] = [];
			let replacementTransportCount = 0;
			try {
				server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
				browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
				const sharedProfile = await browser.newContext({ viewport: { width: 1728, height: 980 } });
				firstTab = await sharedProfile.newPage();
				await installControlledFirstTabReplacement(firstTab);
				const reviewFile = fixture.oracle.reviewFiles[0];
				if (reviewFile === undefined) throw new Error('Tab ownership proof needs a Review file.');
				const url = bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				);
				await firstTab.goto(url, { waitUntil: 'domcontentloaded' });
				await selectReviewFile({ page: firstTab, path: reviewFile.path });
				await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });
				// Observe the existing owner disposition, rather than infer it from the failure banner.
				await firstTab.evaluate(`(async () => {
					const diagnostics = await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href);
					const unsubscribe = diagnostics.observeBridgePaneCommWorkerSessionDiagnosticSnapshots(snapshot => {
						if (snapshot.state !== 'failed') return;
						document.documentElement.dataset.tq109ExhaustedOwnerState = snapshot.state;
						document.documentElement.dataset.tq109ExhaustedOwnerReason = snapshot.failureReason;
					});
					document.addEventListener('__tq109_stop_owner_observation', unsubscribe, { once: true });
				})()`);

				const holdReplacement = async (route: Route): Promise<void> => {
					const requestBody: unknown = route.request().postDataJSON();
					if (
						typeof requestBody !== 'object' ||
						requestBody === null ||
						!('reason' in requestBody) ||
						requestBody.reason !== 'workerReplacement'
					) {
						await route.continue();
						return;
					}
					replacementTransportCount += 1;
					if (replacementTransportCount === 1) {
						// Native commits the first tab's successor; Main cannot consume its delivery.
						const response = await route.fetch();
						try {
							expect(response.status()).toBe(200);
							heldCommit.resolve();
							await releaseRoutes.promise;
						} finally {
							await response.dispose();
						}
					} else await releaseRoutes.promise;
					try {
						await route.abort();
					} catch (error: unknown) {
						// Typed failure supersedes these requests. A browser-aborted request is already retired.
						if (route.request().failure() === null && !context.signal.aborted) throw error;
					}
				};
				await firstTab.route('**/__bridge-product/bootstrap', (route): Promise<void> => {
					const operation = holdReplacement(route);
					routeJobs.push(operation);
					return operation;
				});
				await firstTab.evaluate((): void => {
					document.dispatchEvent(new Event('__tq109_fail_comm_worker'));
				});
				await server.testLaunch
					.observeStep(
						'TQ109 first-tab replacement native commit held before Main delivery',
						heldCommit.promise,
					)
					.value();

				const competingTab = await sharedProfile.newPage();
				await competingTab.goto(url, { waitUntil: 'domcontentloaded' });
				await competingTab.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'visible' });
				const competingReadiness = handleLaunchPromise(
					waitForTabOwnershipReviewReady({ page: competingTab, itemId: reviewFile.itemId }),
					'TQ109 competing tab readiness after live-owner refusal',
				);
				// Drive the existing native-failure budget, not its elapsed-time deadline.
				for (let failure = 0; failure < 4; failure += 1) {
					// oxlint-disable-next-line no-await-in-loop -- Each delivery consumes the next correlated native bootstrap request.
					await firstTab.evaluate((): void => {
						document.dispatchEvent(new Event('__tq109_refuse_native_bootstrap'));
					});
				}
				await firstTab
					.locator('[data-bridge-region="pane-failure"][data-presentation-state="failed"]')
					.waitFor({ state: 'attached' });
				expect(
					await firstTab.evaluate((): number =>
						Number(document.documentElement.dataset['tq109ReplacementRequests']),
					),
				).toBe(4);
				console.log(
					`TQ109_HELD_BOOTSTRAP competing=inactive first=pane-failed replacementRequests=4 detail=${await firstTab.locator('[data-bridge-region="pane-failure"]').textContent()}`,
				);

				expect(
					await firstTab.evaluate(() => ({
						state: document.documentElement.dataset['tq109ExhaustedOwnerState'],
						reason: document.documentElement.dataset['tq109ExhaustedOwnerReason'],
					})),
				).toEqual({ state: 'failed', reason: 'bootstrapBudgetExhausted' });
				const readiness = handleLaunchPromise(
					waitForTabOwnershipReviewReady({ page: firstTab, itemId: reviewFile.itemId }),
					'TQ35 shared-profile: first tab remains ready after competing tab opens',
				);
				// Owner fact precedes explicit closure. The old positive-only wait also settles on closure,
				// giving a deterministic red without a test timeout or leaked observer.
				await firstTab
					.locator('[data-bridge-region="pane-failure"][data-presentation-state="failed"]')
					.waitFor({ state: 'attached' });
				await firstTab.evaluate((): void => {
					document.dispatchEvent(new Event('__tq109_stop_owner_observation'));
				});
				releaseRoutes.resolve();
				await firstTab.close();
				firstTab = null;
				const readinessOutcome = await readiness.settled;
				if (readinessOutcome.kind === 'failed')
					console.log(`TQ109_TERMINAL_FACT ${readinessOutcome.error.message}`);
				await expect(readiness.value()).rejects.toThrow(
					'Tab ownership Review readiness ended: worker-recovery-exhausted',
				);
				await expect(competingReadiness.value()).rejects.toThrow(
					'Tab ownership Review readiness ended: open-elsewhere',
				);
			} catch (error: unknown) {
				primaryFailure = { error };
				throw error;
			} finally {
				releaseRoutes.resolve();
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'tab readiness page',
							run: async (): Promise<void> => {
								if (firstTab !== null && !firstTab.isClosed()) {
									await firstTab.evaluate((): void => {
										document.dispatchEvent(new Event('__tq109_stop_owner_observation'));
									});
									await firstTab.close();
								}
							},
						},
						{
							name: 'tab readiness browser',
							run: async (): Promise<void> => {
								await browser?.close();
							},
						},
						{
							name: 'tab readiness held routes',
							run: async (): Promise<void> => {
								await Promise.all(routeJobs);
							},
						},
						{
							name: 'tab readiness product server',
							run: async (): Promise<void> => {
								await server?.stop();
							},
						},
						{ name: 'tab readiness fixture', run: fixture.dispose },
					],
					...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
				});
			}
		});
	});
}

// This is the existing native-bootstrap failure DTO seam, not a DOM substitute.
// The real first-tab runtime owns replacement, budget exhaustion and failed-pane publication.
async function installControlledFirstTabReplacement(page: Page): Promise<void> {
	await page.addInitScript((): void => {
		const NativeWorker = window.Worker;
		let commWorker: Worker | null = null;
		let currentReplacementRequestId: string | null = null;
		let replacementRequests = 0;
		window.Worker = class extends NativeWorker {
			constructor(url: string | URL, options?: WorkerOptions) {
				super(url, options);
				if (String(url).includes('bridge-comm-worker-vite-entry')) {
					// oxlint-disable-next-line typescript/no-this-alias -- The held-native test signals this actual page-owned comm Worker.
					commWorker = this;
				}
			}
		};
		document.addEventListener('__bridge_product_session_bootstrap_request', (event): void => {
			if (!('detail' in event)) return;
			const detail: unknown = event.detail;
			if (
				typeof detail !== 'object' ||
				detail === null ||
				!('reason' in detail) ||
				detail.reason !== 'workerReplacement' ||
				!('requestId' in detail) ||
				typeof detail.requestId !== 'string'
			)
				return;
			currentReplacementRequestId = detail.requestId;
			replacementRequests += 1;
			document.documentElement.dataset['tq109ReplacementRequests'] = String(replacementRequests);
		});
		document.addEventListener('__tq109_fail_comm_worker', (): void => {
			if (commWorker === null) throw new Error('TQ109 expected the live comm worker.');
			commWorker.dispatchEvent(
				new ErrorEvent('error', { message: 'TQ109 controlled worker failure' }),
			);
		});
		document.addEventListener('__tq109_refuse_native_bootstrap', (): void => {
			if (currentReplacementRequestId === null)
				throw new Error('TQ109 expected a current replacement request.');
			document.dispatchEvent(
				new CustomEvent('__bridge_product_session_bootstrap', {
					detail: {
						requestId: currentReplacementRequestId,
						failure: { reason: 'activation_failed' },
					},
				}),
			);
		});
	});
}
