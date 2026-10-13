import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import {
	runAnnotationSaveJourney,
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
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerReviewMountDependencyJourneyTests(): void {
	test('names a terminal Review mount refusal before explicit page retirement', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			try {
				const page = await browser.newPage();
				await page.setContent(
					'<main data-testid="bridge-dev-session-inactive">Open elsewhere</main>',
				);
				const selection = handleLaunchPromise(
					selectReviewFile({ page, path: 'owner-refusal.ts' }),
					'Review mount terminal refusal witness',
				);
				// This command follows selection's observer installation in the page.
				// Explicit closure settles the old locator wait too: no timeout is needed for red proof.
				await page.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'attached' });
				await page.close();
				await expect(selection.value()).rejects.toThrow(
					'Review shell mount refused by bridge-dev-session-inactive',
				);
			} finally {
				await browser.close();
			}
		});
	});

	test('mounts fresh Review before annotation demand and mounts a seeded reload with its acquisition commit held', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			let server: BridgeViewerOwnedViteProductServer | null = null;
			let browser: Browser | null = null;
			let page: Page | null = null;
			let primaryFailure: { readonly error: unknown } | null = null;
			try {
				server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
				browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
				page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
				await installHeldReviewDemandCommit(page, true);
				const reviewFile = fixture.oracle.reviewFiles[0];
				if (reviewFile === undefined)
					throw new Error('Review mount proof requires a changed file.');
				const url = bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				);
				await page.goto(url, { waitUntil: 'domcontentloaded' });
				await server.testLaunch
					.observeStep(
						'Review metadata display delivery to Main held',
						waitForDemandCount(page, 'reviewMetadataHeld'),
					)
					.value();
				await page
					.getByTestId('bridge-review-metadata-loading-shell')
					.waitFor({ state: 'attached' });
				expect(await page.getByTestId('review-viewer-shell').count()).toBe(0);
				expect((await readHeldReviewDemandState(page)).acquisitions).toBe(0);
				console.log('REVIEW_MOUNT_HELD_METADATA shell=absent acquisitions=0');
				await page.evaluate((): void => {
					document.dispatchEvent(new Event('__review_mount_release_demand'));
				});
				await selectReviewFile({ page, path: reviewFile.path, testLaunch: server.testLaunch });
				await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
				expect(await readHeldReviewDemandState(page)).toEqual({
					acquisitions: 0,
					held: 0,
					refreshes: 0,
				});
				await page.close();
				page = null;

				// Seed a real durable session through the ordinary Save journey, then reopen it.
				await runAnnotationSaveJourney({
					oracle: fixture.oracle,
					server,
					surface: 'review',
					testSignal: context.signal,
				});
				page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
				await installHeldReviewDemandCommit(page);
				await page.goto(url, { waitUntil: 'domcontentloaded' });
				await server.testLaunch
					.observeStep(
						'Review acquisition committed by worker; delivery to Main held',
						waitForDemandCount(page, 'reviewDemandHeld'),
					)
					.value();
				await selectReviewFile({ page, path: reviewFile.path, testLaunch: server.testLaunch });
				await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
				const heldState = await readHeldReviewDemandState(page);
				expect(heldState.acquisitions).toBeGreaterThan(0);
				expect(heldState.held).toBeGreaterThan(0);
				console.log(`REVIEW_MOUNT_HELD_ACQUISITION ${JSON.stringify(heldState)}`);
				await page.evaluate((): void => {
					document.dispatchEvent(new Event('__review_mount_release_demand'));
				});
				await server.testLaunch
					.observeStep(
						'Review annotation source refresh after acquisition delivery',
						waitForDemandCount(page, 'reviewDemandRefreshes'),
					)
					.value();
				expect((await readHeldReviewDemandState(page)).held).toBe(0);
				await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });

				expect(
					heldState.refreshes,
					'Acquisition delivery is held before the Main owner; no source refresh may escape',
				).toBe(0);
			} catch (error: unknown) {
				primaryFailure = { error };
				throw error;
			} finally {
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'Review mount page',
							run: async (): Promise<void> => {
								await page?.close();
							},
						},
						{
							name: 'Review mount browser',
							run: async (): Promise<void> => {
								await browser?.close();
							},
						},
						{
							name: 'Review mount product server',
							run: async (): Promise<void> => {
								await server?.stop();
							},
						},
						{ name: 'Review mount fixture', run: fixture.dispose },
					],
					...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
				});
			}
		});
	});
}

// Register before production installs its MessagePort receiver. This holds delivery,
// not merely a later observation of a message the owner already consumed.
async function installHeldReviewDemandCommit(
	page: Page,
	holdMetadataDelivery = false,
): Promise<void> {
	await page.addInitScript((holdReviewMetadata: boolean): void => {
		const NativeMessageChannel = window.MessageChannel;
		// oxlint-disable-next-line typescript/unbound-method -- Call with the owning port via .call.
		const nativePostMessage = MessagePort.prototype.postMessage;
		const acquisitionRequestIds = new WeakMap<MessagePort, Set<string>>();
		let acquisitions = 0;
		let refreshes = 0;
		let metadataHeld = 0;
		const heldDeliveries: (() => void)[] = [];
		let released = false;
		const updateCounts = (): void => {
			document.documentElement.dataset['reviewDemandAcquisitions'] = String(acquisitions);
			document.documentElement.dataset['reviewDemandRefreshes'] = String(refreshes);
			document.documentElement.dataset['reviewDemandHeld'] = String(heldDeliveries.length);
			document.documentElement.dataset['reviewMetadataHeld'] = String(metadataHeld);
		};
		// oxlint-disable-next-line unicorn/consistent-function-scoping -- addInitScript serializes this function into a separate page realm.
		const field = (value: unknown, name: string): unknown =>
			typeof value === 'object' && value !== null
				? Object.getOwnPropertyDescriptor(value, name)?.value
				: undefined;
		const installReceiver = (port: MessagePort): void => {
			acquisitionRequestIds.set(port, new Set());
			port.addEventListener('message', (event: MessageEvent<unknown>): void => {
				const message = event.data;
				const requestId = field(message, 'requestId');
				const holdsMetadata = holdReviewMetadata && field(message, 'kind') === 'reviewDisplayPatch';
				const holdsAcquisition =
					field(message, 'kind') === 'annotationCommandAccepted' &&
					typeof requestId === 'string' &&
					acquisitionRequestIds.get(port)?.has(requestId) === true;
				if (released || (!holdsMetadata && !holdsAcquisition)) return;
				event.stopImmediatePropagation();
				if (holdsMetadata) metadataHeld += 1;
				heldDeliveries.push((): void => {
					port.dispatchEvent(new MessageEvent('message', { data: message }));
				});
				updateCounts();
			});
		};
		window.MessageChannel = class extends NativeMessageChannel {
			constructor() {
				super();
				installReceiver(this.port1);
				installReceiver(this.port2);
			}
		};
		MessagePort.prototype.postMessage = function (
			this: MessagePort,
			message: unknown,
			transferOrOptions?: Transferable[] | StructuredSerializeOptions,
		): void {
			if (
				field(message, 'command') === 'annotationCommand' &&
				field(message, 'surface') === 'review'
			) {
				const operation = field(message, 'operation');
				const requestId = field(message, 'requestId');
				if (field(operation, 'kind') === 'demand.acquire' && typeof requestId === 'string') {
					acquisitionRequestIds.get(this)?.add(requestId);
					acquisitions += 1;
				}
				if (field(operation, 'kind') === 'source.refresh') refreshes += 1;
				updateCounts();
			}
			const options = Array.isArray(transferOrOptions)
				? { transfer: transferOrOptions }
				: transferOrOptions;
			nativePostMessage.call(this, message, options);
		};
		document.addEventListener('__review_mount_release_demand', (): void => {
			released = true;
			for (const deliver of heldDeliveries.splice(0)) deliver();
			updateCounts();
		});
	}, holdMetadataDelivery);
}

async function readHeldReviewDemandState(page: Page): Promise<{
	readonly acquisitions: number;
	readonly held: number;
	readonly refreshes: number;
}> {
	return await page.evaluate(() => ({
		acquisitions: Number(document.documentElement.dataset['reviewDemandAcquisitions'] ?? 0),
		held: Number(document.documentElement.dataset['reviewDemandHeld'] ?? 0),
		refreshes: Number(document.documentElement.dataset['reviewDemandRefreshes'] ?? 0),
	}));
}

async function waitForDemandCount(page: Page, attributeName: string): Promise<void> {
	await page.evaluate(
		(name): Promise<void> =>
			new Promise((resolve): void => {
				const inspect = (): void => {
					if (Number(document.documentElement.dataset[name]) > 0) {
						observer.disconnect();
						resolve();
					}
				};
				const observer = new MutationObserver(inspect);
				observer.observe(document.documentElement, { attributes: true });
				inspect();
			}),
		attributeName,
	);
}
