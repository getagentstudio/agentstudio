import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';

import type { Browser, Page, Request } from 'playwright';
import { expect, test } from 'vitest';

import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSubscriptionReceiptQuiescence } from './bridge-viewer-vite-frame-acknowledgement-quiescence.ts';

const acknowledgementCommandPath = '/__bridge-product/command';

interface HeldAcknowledgementOrigin {
	readonly close: () => Promise<void>;
	readonly origin: string;
	readonly releaseHeldAcknowledgements: () => void;
	readonly requestAcknowledgementPost: (page: Page) => Promise<void>;
	readonly waitForNextHeldAcknowledgement: () => Promise<void>;
}

/**
 * One local HTTP origin whose page starts a dedicated Web Worker that POSTs a
 * typed `subscription.acknowledge` receipt on demand, and which holds every such POST open until the
 * test releases it. Playwright route interception does not reach dedicated-worker requests, so the
 * hold has to be a real server. Neither the Swift backend nor the Vite dev server takes part.
 */
async function startHeldAcknowledgementOrigin(): Promise<HeldAcknowledgementOrigin> {
	const heldAcknowledgements: ServerResponse[] = [];
	const heldAcknowledgementWaiters: Array<() => void> = [];
	let acknowledgementCommandUrl = '';
	const documentBody = (): string => `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Acknowledgement observer</title></head>
<body>
<script>
const acknowledgementCommandUrl = ${JSON.stringify(acknowledgementCommandUrl)};
const workerSource =
  'self.fetch(' + JSON.stringify(acknowledgementCommandUrl) + ', {' +
  "method: 'POST', headers: {'content-type': 'application/json'}," +
  "body: JSON.stringify({domain: 'default', handle: 'handle-1', incarnation: 'incarnation-1'," +
  "kind: 'subscription.acknowledge', paneSessionId: 'pane-session-1'," +
  "receivedThroughDeliverySequence: 1, subscriptionId: 'subscription-1'," +
  "wireVersion: 2, workerInstanceId: 'worker-instance-1'})})" +
  '.then(function (response) { return response.text(); }).catch(function () {});';
const workerUrl = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
const liveWorkers = [];
window.addEventListener('message', function (event) {
  if (event.data !== 'post-acknowledgement') return;
  liveWorkers.push(new Worker(workerUrl));
});
</script>
</body>
</html>`;
	const server: Server = createServer(
		(request: IncomingMessage, response: ServerResponse): void => {
			if ((request.url ?? '/').startsWith(acknowledgementCommandPath)) {
				// Hold: never respond, so the acknowledgement stays in flight for the observer to count.
				heldAcknowledgements.push(response);
				for (const notify of heldAcknowledgementWaiters.splice(0)) notify();
				return;
			}
			response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
			response.end(documentBody());
		},
	);
	await new Promise<void>((resolve): void => {
		server.listen(0, '127.0.0.1', (): void => resolve());
	});
	const address: AddressInfo | string | null = server.address();
	if (address === null || typeof address === 'string') {
		throw new Error('Held acknowledgement origin did not bind a TCP port.');
	}
	const origin = `http://127.0.0.1:${address.port}`;
	acknowledgementCommandUrl = `${origin}${acknowledgementCommandPath}`;
	return {
		close: async (): Promise<void> => {
			for (const response of heldAcknowledgements.splice(0)) response.destroy();
			await new Promise<void>((resolve): void => {
				server.close((): void => resolve());
			});
		},
		origin,
		releaseHeldAcknowledgements: (): void => {
			for (const response of heldAcknowledgements.splice(0)) {
				response.writeHead(200, { 'content-type': 'application/json' });
				response.end(
					JSON.stringify({
						domain: 'default',
						handle: 'handle-1',
						incarnation: 'incarnation-1',
						kind: 'subscription.acknowledged',
						paneSessionId: 'pane-session-1',
						receivedThroughDeliverySequence: 1,
						subscriptionId: 'subscription-1',
						wireVersion: 2,
						workerInstanceId: 'worker-instance-1',
					}),
				);
			}
		},
		requestAcknowledgementPost: async (page: Page): Promise<void> => {
			await page.evaluate((): void => {
				window.postMessage('post-acknowledgement', '*');
			});
		},
		waitForNextHeldAcknowledgement: async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				heldAcknowledgementWaiters.push(resolve);
			});
		},
	};
}

function isAcknowledgementPost(request: Request): boolean {
	return (
		request.method() === 'POST' && new URL(request.url()).pathname === acknowledgementCommandPath
	);
}

/**
 * Drives one held acknowledgement from the page's current document and returns the observed request
 * once both Playwright and the server agree it is in flight.
 */
async function issueHeldAcknowledgement(props: {
	readonly origin: HeldAcknowledgementOrigin;
	readonly page: Page;
}): Promise<Request> {
	const observedRequest = props.page.waitForRequest(isAcknowledgementPost);
	const heldByServer = props.origin.waitForNextHeldAcknowledgement();
	await props.origin.requestAcknowledgementPost(props.page);
	const [request] = await Promise.all([observedRequest, heldByServer]);
	return request;
}

test('frame acknowledgement quiescence forgets a destroyed document’s acknowledgement', async (): Promise<void> => {
	// Arrange: one held worker acknowledgement owed by the current document.
	const origin = await startHeldAcknowledgementOrigin();
	const browser: Browser = await launchBridgeViewerE2EChromium();
	try {
		const page = await browser.newPage();
		const observer = observeSubscriptionReceiptQuiescence(page);
		await page.goto(`${origin.origin}/`, { waitUntil: 'load' });
		await issueHeldAcknowledgement({ origin, page });
		expect(observer.pendingAcknowledgementCount()).toBe(1);

		// Act: destroy the document that owes the acknowledgement.
		await page.reload({ waitUntil: 'load' });

		// Assert: a destroyed document owes nothing, so the observer is quiescent.
		expect(observer.pendingAcknowledgementCount()).toBe(0);
		await observer.wait();
	} finally {
		await browser.close();
		await origin.close();
	}
});

test('frame acknowledgement quiescence still observes the document created by the reload', async (): Promise<void> => {
	// Arrange: an acknowledgement owed by the pre-reload document, then a fresh document.
	const origin = await startHeldAcknowledgementOrigin();
	const browser: Browser = await launchBridgeViewerE2EChromium();
	try {
		const page = await browser.newPage();
		const observer = observeSubscriptionReceiptQuiescence(page);
		await page.goto(`${origin.origin}/`, { waitUntil: 'load' });
		await issueHeldAcknowledgement({ origin, page });
		await page.reload({ waitUntil: 'load' });

		// Act: the new document's worker owes an acknowledgement of its own.
		const reloadedAcknowledgement = await issueHeldAcknowledgement({ origin, page });

		// Assert: the navigation did not blind the observer, and settling the live request drains it.
		expect(observer.pendingAcknowledgementCount()).toBe(1);
		const acknowledgementFinished = page.waitForEvent(
			'requestfinished',
			(request: Request): boolean => request === reloadedAcknowledgement,
		);
		origin.releaseHeldAcknowledgements();
		await acknowledgementFinished;
		expect(observer.pendingAcknowledgementCount()).toBe(0);
	} finally {
		await browser.close();
		await origin.close();
	}
});
