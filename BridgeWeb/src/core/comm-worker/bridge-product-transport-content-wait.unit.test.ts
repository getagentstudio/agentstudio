import { performance } from 'node:perf_hooks';

import { afterEach, expect, test, vi } from 'vitest';

import {
	createContentTransportHarness,
	fileContentDescriptor,
} from './test-fixtures/bridge-product-transport-content.test-support.js';
import { TestProductServer } from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach((): void => {
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
});

test('content proof returns the exact future request observed by its owner', async () => {
	const harness = createContentTransportHarness();
	const request = harness.server.waitForContentRequestCount(1);
	const stream = harness.transport.openContent(
		fileContentDescriptor('owner-fact'),
		new AbortController().signal,
	);
	expect(await request).toMatchObject({ contentRequestId: stream.contentRequestId });
	await expect(stream.terminal).resolves.toMatchObject({ kind: 'complete' });
});

test('content proof reads a buffered owner fact without consulting elapsed time', async () => {
	const harness = createContentTransportHarness();
	const stream = harness.transport.openContent(
		fileContentDescriptor('buffered-owner-fact'),
		new AbortController().signal,
	);
	await stream.terminal;
	const elapsedTime = vi.spyOn(performance, 'now');
	await harness.server.waitForContentRequestCount(1);
	expect(elapsedTime).not.toHaveBeenCalled();
});

test('metadata proof wait ends with the named owner shutdown instead of a clock deadline', async () => {
	const server = new TestProductServer();
	const stream = server.waitForMetadataStream();
	server.shutdown();
	await expect(stream).rejects.toThrow(/shut down/iu);
});
