import { describe, expect, test } from 'vitest';

import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	fetchBridgeWorkerFileViewContentResource,
	type BridgeWorkerFileViewContentOpen,
} from './bridge-worker-file-view-content-fetch.js';

describe('Bridge worker File View content fetch', () => {
	test('opens typed File content through the shared product transport', async () => {
		// Arrange
		const openedDescriptorIds: string[] = [];
		const request = makeContentRequest();

		// Act
		const result = await fetchBridgeWorkerFileViewContentResource({
			contentRequest: request,
			openContent: completedContentOpen('hello file worker', openedDescriptorIds),
			operationCorrelationId: 'a'.repeat(64),
		});

		// Assert
		expect(openedDescriptorIds).toEqual(['descriptor-file-1']);
		expect(result).toMatchObject({
			byteLength: 17,
			contentHash: 'b'.repeat(64),
			contentHashAlgorithm: 'sha256',
			descriptorId: 'descriptor-file-1',
			itemId: 'file-1',
			language: 'swift',
			path: 'Sources/App/FileView.swift',
			requestId: 'content-request-1',
			resourceKind: 'file.content',
			sourceGeneration: 3,
			sourceIdentity: 'file-source-1',
			sourcePosition: 'whole',
		});
		expect(new TextDecoder().decode(result.textBytes)).toBe('hello file worker');
	});

	test('returns the product-owned bytes without re-encoding decoded text', async () => {
		// Arrange
		const originalBytes = new Uint8Array([0xef, 0xbb, 0xbf, 0x61]);

		// Act
		const result = await fetchBridgeWorkerFileViewContentResource({
			contentRequest: makeContentRequest(originalBytes.byteLength),
			openContent: completedByteContentOpen(originalBytes),
			operationCorrelationId: 'a'.repeat(64),
		});

		// Assert
		expect(result.byteLength).toBe(4);
		expect([...new Uint8Array(result.textBytes)]).toEqual([...originalBytes]);
		expect(result.text).toBe('a');
	});

	test('rejects binary or unavailable content before opening a product stream', async () => {
		// Arrange
		let openCount = 0;
		const openContent: BridgeWorkerFileViewContentOpen = () => {
			openCount += 1;
			throw new Error('must not open');
		};

		// Act / Assert
		await expect(
			fetchBridgeWorkerFileViewContentResource({
				contentRequest: {
					...makeContentRequest(),
					contentDescriptor: {
						...makeContentRequest().contentDescriptor,
						encoding: 'utf-8',
					},
				},
				isBinary: true,
				openContent,
				operationCorrelationId: 'a'.repeat(64),
			}),
		).rejects.toThrow(/binary/i);
		expect(openCount).toBe(0);
	});

	test('surfaces typed product errors and reset terminals', async () => {
		// Arrange
		const request = makeContentRequest();

		// Act / Assert
		await expect(
			fetchBridgeWorkerFileViewContentResource({
				contentRequest: request,
				openContent: () => ({
					contentKind: 'file.content',
					contentRequestId: 'content-request-1',
					frames: emptyFrames(),
					terminal: Promise.resolve({
						code: 'stale_worker',
						contentKind: 'file.content',
						descriptorId: request.contentDescriptor.descriptorId,
						kind: 'error',
						retryable: true,
						safeMessage: 'File source changed.',
					}),
				}),
				operationCorrelationId: 'a'.repeat(64),
			}),
		).rejects.toThrow('File source changed.');
	});
});

function makeContentRequest(byteLength = 17): BridgeCommWorkerFileViewContentRequest {
	return {
		contentDescriptor: {
			contentKind: 'file.content',
			declaredByteLength: byteLength,
			descriptorId: 'descriptor-file-1',
			encoding: 'utf-8',
			expectedSha256: 'a'.repeat(64),
			fileId: 'file-1',
			maximumBytes: byteLength,
			source: {
				repoId: '00000000-0000-4000-8000-000000000001',
				rootRevisionToken: 'root-revision-1',
				sourceCursor: 'source-cursor-1',
				sourceId: 'file-source-1',
				subscriptionGeneration: 3,
				worktreeId: '00000000-0000-4000-8000-000000000002',
			},
			window: {
				kind: 'prefix',
				maximumBytes: byteLength,
				maximumLines: 10_000,
				startByte: 0,
			},
		},
		itemId: 'file-1',
		language: 'swift',
		path: 'Sources/App/FileView.swift',
		sizeBytes: byteLength,
	};
}

function completedContentOpen(
	text: string,
	openedDescriptorIds: string[] = [],
): BridgeWorkerFileViewContentOpen {
	return completedByteContentOpen(new TextEncoder().encode(text), openedDescriptorIds);
}

function completedByteContentOpen(
	bytes: Uint8Array,
	openedDescriptorIds: string[] = [],
): BridgeWorkerFileViewContentOpen {
	return (descriptor) => {
		openedDescriptorIds.push(descriptor.descriptorId);
		const ownedBytes = bytes.slice().buffer;
		return {
			contentKind: 'file.content',
			contentRequestId: 'content-request-1',
			frames: emptyFrames(),
			terminal: Promise.resolve({
				bytes: ownedBytes,
				contentKind: 'file.content',
				descriptorId: descriptor.descriptorId,
				endOfSource: true,
				kind: 'complete',
				observedByteLength: ownedBytes.byteLength,
				observedSha256: 'b'.repeat(64),
			}),
		};
	};
}

async function* emptyFrames(): AsyncIterable<never> {}
