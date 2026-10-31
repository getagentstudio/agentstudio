import { act } from 'react';
import { expect, test } from 'vitest';

import { createBridgeProductDeferred } from '../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeWorkerServerToMainMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import {
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	waitForBridgeFileViewerWorkerPublicationQueue,
} from './bridge-file-viewer-browser-test-comm-worker.js';

test('File worker publication closes its act before completing an awaiting owner', async ({
	signal,
}): Promise<void> => {
	let publishMessages: ((messages: readonly BridgeWorkerServerToMainMessage[]) => void) | undefined;
	const factory = createBridgeFileViewerBrowserTestPaneSessionFactory({
		activateFileViewerOnInstall: false,
		productSessionRef: {
			current: {
				onWorkerMessagesPublisher: (publisher): void => {
					publishMessages = publisher;
				},
			},
		},
	});
	const publication = createBridgeProductDeferred<void>();
	const witness = document.createElement('div');
	document.body.append(witness);
	const session = factory();
	const dispatcher = session.createDispatcher({
		publishWorkerMessages: (): void => {
			witness.textContent = 'published';
			publication.resolve();
		},
	});
	const abortPublication = (): void =>
		publication.reject(new Error('File publication test owner aborted', { cause: signal.reason }));
	signal.addEventListener('abort', abortPublication, { once: true });
	let observed: Promise<void> | undefined;
	try {
		if (publishMessages === undefined) throw new Error('Expected File worker publisher.');
		// Hold the consumer's act until the publisher emits its exact completion event.
		// An async publication callback used to pop these two scopes in opening order.
		observed = Promise.resolve(
			act(async (): Promise<void> => {
				await publication.promise;
			}),
		);
		publishMessages([]);
		const delivered = waitForBridgeFileViewerWorkerPublicationQueue().then((): void => {
			if (witness.textContent !== 'published')
				publication.reject(
					new Error('File publisher ended without delivering its completion event.'),
				);
		});
		await Promise.all([observed, delivered]);
		expect(witness.textContent).toBe('published');
	} finally {
		publication.reject(new Error('File publication witness retired.'));
		await Promise.allSettled([observed, waitForBridgeFileViewerWorkerPublicationQueue()]);
		signal.removeEventListener('abort', abortPublication);
		dispatcher.dispose();
		session.dispose();
		witness.remove();
	}
});
