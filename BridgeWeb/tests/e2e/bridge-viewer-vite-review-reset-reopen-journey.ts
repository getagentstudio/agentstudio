import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import type { BridgeProductMetadataFrame } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
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
import { waitForReviewOwnerOutcome } from './bridge-viewer-vite-review-owner-wait.ts';
import { installSelectedContentOwnerObservation } from './bridge-viewer-vite-selected-content-observation.ts';
import {
	startBridgeStreamFaultProxy,
	type BridgeStreamFaultProxy,
} from './bridge-viewer-vite-stream-fault-proxy.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerReviewResetReopenJourney(
	props: {
		readonly waitForReadiness?: (props: {
			readonly page: Page;
			readonly itemId: string;
		}) => Promise<void>;
	} = {},
): void {
	test('keeps Review selection pending through visible first-open reset failure and mounts after automatic successor delivery', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			let server: BridgeViewerOwnedViteProductServer | null = null;
			let proxy: BridgeStreamFaultProxy | null = null;
			let browser: Browser | null = null;
			let page: Page | null = null;
			let primaryFailure: { readonly error: unknown } | null = null;
			const forwarded: BridgeProductMetadataFrame[] = [];
			try {
				server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
				proxy = await startBridgeStreamFaultProxy(server.origin, {
					resetFirstReviewOpen: true,
					onForwardedMetadataFrame: (frame): void => {
						forwarded.push(frame);
					},
				});
				browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
				page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
				await installSelectedContentOwnerObservation(page);
				await holdReviewSuccessorDelivery(page);
				const reviewFile = fixture.oracle.reviewFiles[0];
				if (reviewFile === undefined) throw new Error('Reset/reopen proof requires a Review file.');
				await page.goto(
					bridgeViewerViteProductReviewUrl(
						proxy.origin,
						requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
					),
					{ waitUntil: 'domcontentloaded' },
				);
				await page.getByTestId('bridge-review-metadata-failed-shell').waitFor({ state: 'visible' });
				await server.testLaunch
					.observeStep('Review automatic reset successor delivery held', waitForHeldSuccessor(page))
					.value();
				const reset = forwarded.find(
					(frame) =>
						frame.kind === 'subscription.reset' && frame.subscriptionKind === 'review.metadata',
				);
				if (reset?.kind !== 'subscription.reset')
					throw new Error('Expected the actual decoded reset seam.');
				expect(
					forwarded.some(
						(frame) =>
							frame.kind === 'subscription.batchComplete' &&
							frame.subscriptionId === reset.subscriptionId,
					),
				).toBe(false);
				expect(await page.getByTestId('review-viewer-shell').count()).toBe(0);
				expect(
					await page.evaluate(
						() => window['__bridgeReviewSelectionDiagnostic']?.sessionState ?? null,
					),
				).toBe('ready');
				console.log(
					'REVIEW_RESET_REOPEN failedRetryable=visible successor=recovering-held firstBank=uncertified',
				);

				const selection = handleLaunchPromise(
					selectReviewFile({ page, path: reviewFile.path, testLaunch: server.testLaunch }),
					'Review select through retryable reset',
				);
				const readiness = handleLaunchPromise(
					props.waitForReadiness === undefined
						? waitForReviewOwnerOutcome({
								page,
								itemId: reviewFile.itemId,
								goal: 'selected-painted',
							}).then((outcome): void => {
								expect(outcome.kind).toBe('ready');
							})
						: props.waitForReadiness({ page, itemId: reviewFile.itemId }),
					'Review readiness through retryable reset',
				);
				// This owner fact remains visible while both waits open; no clock decides rejection.
				await page.getByTestId('bridge-review-metadata-failed-shell').waitFor({ state: 'visible' });
				await page.evaluate((): void => {
					document.dispatchEvent(new Event('__review_reset_release_successor'));
				});
				await selection.value();
				await readiness.value();
				await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
				expect(await page.getByTestId('bridge-review-metadata-failed-shell').count()).toBe(0);
				expect(
					await page.evaluate((): number =>
						Number(document.documentElement.dataset['reviewResetHeld']),
					),
				).toBe(0);
				expect(proxy.snapshot().metadataRequestCount).toBe(1);
				expect(
					await page.evaluate(
						() => window['__bridgeReviewSelectionDiagnostic']?.replacementRequestCount ?? null,
					),
				).toBe(0);
				expect(
					forwarded.filter(
						(frame) =>
							frame.kind === 'subscription.accepted' &&
							frame.subscriptionKind === 'review.metadata',
					),
				).toHaveLength(2);
				console.log(
					'REVIEW_RESET_REOPEN successor=ready selected=painted metadataStreams=1 ReviewSubscriptions=2',
				);
			} catch (error: unknown) {
				primaryFailure = { error };
				throw error;
			} finally {
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'reset/reopen page',
							run: async (): Promise<void> => {
								await page?.close();
							},
						},
						{
							name: 'reset/reopen browser',
							run: async (): Promise<void> => {
								await browser?.close();
							},
						},
						{
							name: 'reset/reopen proxy',
							run: async (): Promise<void> => {
								await proxy?.stop();
							},
						},
						{
							name: 'reset/reopen product server',
							run: async (): Promise<void> => {
								await server?.stop();
							},
						},
						{ name: 'reset/reopen fixture', run: fixture.dispose },
					],
					...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
				});
			}
		});
	});
}

async function holdReviewSuccessorDelivery(page: Page): Promise<void> {
	await page.addInitScript((): void => {
		const NativeMessageChannel = window.MessageChannel;
		let failedObserved = false;
		let released = false;
		const held: (() => void)[] = [];
		// oxlint-disable-next-line unicorn/consistent-function-scoping -- Serialized into the page realm.
		const field = (value: unknown, name: string): unknown =>
			typeof value === 'object' && value !== null
				? Object.getOwnPropertyDescriptor(value, name)?.value
				: undefined;
		const attachReceiver = (port: MessagePort): void => {
			port.addEventListener('message', (event: MessageEvent<unknown>): void => {
				const message = event.data;
				const kind = field(message, 'kind');
				const recovery =
					kind === 'viewRecoveryStatus' &&
					field(field(message, 'view'), 'kind') === 'review.metadata';
				if (recovery && field(message, 'status') === 'failedRetryable') {
					failedObserved = true;
					return;
				}
				const patches = field(message, 'patches');
				const failedDisplay =
					kind === 'reviewDisplayPatch' &&
					Array.isArray(patches) &&
					patches.some(
						(patch: unknown): boolean =>
							field(patch, 'slice') === 'reviewSource' &&
							field(field(patch, 'payload'), 'status') === 'failed',
					);
				if (!failedObserved || released || failedDisplay) return;
				if (!recovery && field(message, 'surface') !== 'review') return;
				event.stopImmediatePropagation();
				held.push((): void => {
					port.dispatchEvent(new MessageEvent('message', { data: message }));
				});
				document.documentElement.dataset['reviewResetHeld'] = String(held.length);
				if (recovery && field(message, 'status') === 'recovering')
					document.documentElement.dataset['reviewResetSuccessorHeld'] = 'true';
			});
		};
		window.MessageChannel = class extends NativeMessageChannel {
			constructor() {
				super();
				attachReceiver(this.port1);
				attachReceiver(this.port2);
			}
		};
		document.addEventListener('__review_reset_release_successor', (): void => {
			released = true;
			for (const deliver of held.splice(0)) deliver();
			document.documentElement.dataset['reviewResetHeld'] = '0';
		});
	});
}

async function waitForHeldSuccessor(page: Page): Promise<void> {
	await page.evaluate(
		(): Promise<void> =>
			new Promise((resolve): void => {
				const inspect = (): void => {
					if (document.documentElement.dataset['reviewResetSuccessorHeld'] === 'true') {
						observer.disconnect();
						resolve();
					}
				};
				const observer = new MutationObserver(inspect);
				observer.observe(document.documentElement, { attributes: true });
				inspect();
			}),
	);
}
