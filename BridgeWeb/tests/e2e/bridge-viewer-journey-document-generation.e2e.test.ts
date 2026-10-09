import type { Browser, Page, Response } from 'playwright';
import { uuidv7 } from 'uuidv7';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';

import { installBridgeViewerDocumentGenerations } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-document-generations.ts';
import { BridgeViewerRealRouterObserver } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-page.ts';
import type { BridgeViewerReloadJoinResponses } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-reload-join-diagnostics.ts';
import {
	type BridgeViewerJourneyDocumentGenerationServer,
	startBridgeViewerJourneyDocumentGenerationServer,
} from './bridge-viewer-journey-document-generation-fixture.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';

// A reload waiter is armed for the next page document. It must settle only on a
// response to a request issued by that document's worker, never on a request
// from the document (or worker) that was current when it was armed.
describe('Bridge product journey document generations in a real browser', () => {
	let browser: Browser | null = null;
	let server: BridgeViewerJourneyDocumentGenerationServer | null = null;

	beforeAll(async (): Promise<void> => {
		server = await startBridgeViewerJourneyDocumentGenerationServer();
		browser = await launchBridgeViewerE2EChromium();
	});

	afterAll(async (): Promise<void> => {
		await browser?.close();
		await server?.close();
	});

	test('a same-document pushState does not start a new generation for the worker', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange
			const reloadJoin = journey.armReloadJoinWaiters();
			await journey.page.evaluate((): void => {
				history.pushState({}, '', '/journey.html?pushed');
			});

			// Act
			const sameDocumentRequestId = await journey.sendSubscriptionReceipt();
			const generationAfterSameDocumentNavigation = journey.currentGeneration();
			const nextDocumentRequestId = await journey.reloadAndSendSubscriptionReceipt();

			// Assert: only the next document's acknowledgement settles the reload waiter.
			expect(await acknowledgedRequestId(reloadJoin)).toBe(nextDocumentRequestId);
			expect(nextDocumentRequestId).not.toBe(sameDocumentRequestId);
			expect(generationAfterSameDocumentNavigation).toBe(1);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	test('a hash navigation does not start a new generation for the worker', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange
			const reloadJoin = journey.armReloadJoinWaiters();
			await journey.page.evaluate((): void => {
				location.hash = 'moved';
			});

			// Act
			await journey.sendSubscriptionReceipt();
			const generationBeforeReload = journey.currentGeneration();
			const nextDocumentRequestId = await journey.reloadAndSendSubscriptionReceipt();

			// Assert
			expect(await acknowledgedRequestId(reloadJoin)).toBe(nextDocumentRequestId);
			expect(generationBeforeReload).toBe(1);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	test('a reload starts the next generation, whose worker settles the reload waiter', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange
			const reloadJoin = journey.armReloadJoinWaiters();

			// Act
			const nextDocumentRequestId = await journey.reloadAndSendSubscriptionReceipt();

			// Assert
			expect(await acknowledgedRequestId(reloadJoin)).toBe(nextDocumentRequestId);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	test('a redirected navigation commits one new generation', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange
			const reloadJoin = journey.armReloadJoinWaiters();

			// Act
			await journey.page.goto(`${journey.origin}/redirect-to-journey`, { waitUntil: 'load' });
			await journey.waitForWorkerReady();
			const redirectedDocumentRequestId = await journey.sendSubscriptionReceipt();

			// Assert
			expect(await acknowledgedRequestId(reloadJoin)).toBe(redirectedDocumentRequestId);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	test('an aborted navigation keeps the old generation for the old worker', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange
			const reloadJoin = journey.armReloadJoinWaiters();
			await journey.page.route('**/aborted-navigation', async (route): Promise<void> => {
				await route.abort('aborted');
			});
			await expect(journey.page.goto(`${journey.origin}/aborted-navigation`)).rejects.toThrow(
				/ERR_ABORTED/u,
			);

			// Act
			await journey.sendSubscriptionReceipt();
			const generationBeforeReload = journey.currentGeneration();
			const nextDocumentRequestId = await journey.reloadAndSendSubscriptionReceipt();

			// Assert
			expect(await acknowledgedRequestId(reloadJoin)).toBe(nextDocumentRequestId);
			expect(generationBeforeReload).toBe(1);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	test('a request the old document sends while a navigation is pending keeps the old generation', async () => {
		await withJourneyPage(async (journey): Promise<void> => {
			// Arrange: the next document's response is held, so the navigation is issued but
			// has not committed and the old document and its worker are still live. The old
			// worker sends its request once the server has seen the navigation request.
			const reloadJoin = journey.armReloadJoinWaiters();
			const heldDocument = journey.holdNextDocument();
			const pendingWindowRequestId = uuidv7();
			const pendingWindowResponse = journey.page.waitForResponse(
				(response: Response): boolean =>
					new URL(response.url()).searchParams.get('requestId') === pendingWindowRequestId,
			);
			await journey.page.evaluate((requestId: string): void => {
				(
					window as unknown as {
						readonly bridgeJourneyWorkerSendDuringHeldNavigation: (
							kind: string,
							requestId: string,
						) => void;
					}
				).bridgeJourneyWorkerSendDuringHeldNavigation('subscription.acknowledge', requestId);
			}, pendingWindowRequestId);

			// Act
			await journey.page.evaluate((): void => {
				location.href = '/held-journey.html';
			});
			await heldDocument.requested;
			await pendingWindowResponse;
			const generationWhilePending = journey.currentGeneration();
			heldDocument.release();
			await journey.page.waitForURL('**/held-journey.html', { waitUntil: 'load' });
			await journey.waitForWorkerReady();
			const nextDocumentRequestId = await journey.sendSubscriptionReceipt();

			// Assert
			expect(await acknowledgedRequestId(reloadJoin)).toBe(nextDocumentRequestId);
			expect(nextDocumentRequestId).not.toBe(pendingWindowRequestId);
			expect(generationWhilePending).toBe(1);
			expect(journey.currentGeneration()).toBe(2);
		});
	});

	interface JourneyPage {
		readonly armReloadJoinWaiters: () => BridgeViewerReloadJoinResponses;
		readonly currentGeneration: () => number;
		readonly holdNextDocument: BridgeViewerJourneyDocumentGenerationServer['holdNextDocument'];
		readonly origin: string;
		readonly page: Page;
		readonly reloadAndSendSubscriptionReceipt: () => Promise<string>;
		readonly sendSubscriptionReceipt: () => Promise<string>;
		readonly waitForWorkerReady: () => Promise<void>;
	}

	async function withJourneyPage(run: (journey: JourneyPage) => Promise<void>): Promise<void> {
		if (browser === null || server === null) throw new Error('Journey fixture is not running.');
		const origin = server.origin;
		const page = await browser.newPage();
		try {
			const documentGenerations = await installBridgeViewerDocumentGenerations(page);
			const observer = new BridgeViewerRealRouterObserver(page, documentGenerations);
			const waitForWorkerReady = async (): Promise<void> => {
				await page.locator('body[data-worker-ready="true"]').waitFor({ state: 'attached' });
			};
			await page.goto(`${origin}/journey.html`, { waitUntil: 'load' });
			await waitForWorkerReady();
			await run({
				armReloadJoinWaiters: (): BridgeViewerReloadJoinResponses => {
					const reloadJoin = observer.armReloadJoinWaiters();
					// The waiters this test does not settle reject when the page closes.
					void reloadJoin.fileMetadataOpen.catch((): void => {});
					void reloadJoin.reviewMetadataOpen.catch((): void => {});
					void reloadJoin.subscriptionReceipt.catch((): void => {});
					return reloadJoin;
				},
				currentGeneration: documentGenerations.currentGeneration,
				holdNextDocument: server.holdNextDocument,
				origin,
				page,
				reloadAndSendSubscriptionReceipt: async (): Promise<string> => {
					await page.reload({ waitUntil: 'load' });
					await waitForWorkerReady();
					return await sendSubscriptionReceipt(page);
				},
				sendSubscriptionReceipt: async (): Promise<string> => await sendSubscriptionReceipt(page),
				waitForWorkerReady,
			});
		} finally {
			await page.close();
		}
	}
});

// Sends one typed subscription receipt from the page's current worker and returns its
// request id once the harness has observed the response, so every response
// waiter armed before it has already judged that response.
async function sendSubscriptionReceipt(page: Page): Promise<string> {
	const requestId = uuidv7();
	const observedResponse = page.waitForResponse(
		(response: Response): boolean =>
			new URL(response.url()).searchParams.get('requestId') === requestId,
	);
	const status = await page.evaluate(
		async (sentRequestId: string): Promise<number> =>
			await (
				window as unknown as {
					readonly bridgeJourneyWorkerSend: (kind: string, requestId: string) => Promise<number>;
				}
			).bridgeJourneyWorkerSend('subscription.acknowledge', sentRequestId),
		requestId,
	);
	expect(status).toBe(204);
	await observedResponse;
	return requestId;
}

async function acknowledgedRequestId(reloadJoin: BridgeViewerReloadJoinResponses): Promise<string> {
	const acknowledgement = await reloadJoin.subscriptionReceipt;
	return new URL(acknowledgement.url()).searchParams.get('requestId') ?? 'missing';
}
