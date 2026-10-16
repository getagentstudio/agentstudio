import type { BridgeMainCodeViewItem } from './bridge-main-render-snapshot-store.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerReviewDisplayPatchEvent,
} from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';

export function makeReviewDisplayPatchEvent(): BridgeWorkerReviewDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: 2,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: {
			packageId: 'package-1',
			publicationId: '00000000-0000-7000-8000-000000000001',
			reviewGeneration: 1,
			revision: 11,
			sourceIdentity: 'review-source-package-1',
		},
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext('package-1'),
					metadataSourceId: 'review-source-package-1',
					metadataWindowIdentity: 'metadata-window-package-1-r11',
					packageId: 'package-1',
					reviewGeneration: 1,
					revision: 11,
					status: 'loading',
					summary: null,
					totalItemCount: 1,
					totalTreeRowCount: 1,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: [
						{
							contentFacts: [],
							extentFacts: [],
							metadata: {
								additions: 1,
								deletions: 1,
								basePath: 'Sources/App.swift',
								changeKind: 'modified',
								contentDescriptorIdsByRole: {},
								contentHashesByRole: {},
								contentRoles: [],
								extension: 'swift',
								fileClass: 'source',
								headPath: 'Sources/App.swift',
								isHiddenByDefault: false,
								itemId: 'item-1',
								language: 'swift',
								mimeTypes: ['text/plain'],
								provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
								reviewPriority: 'normal',
								reviewState: 'unreviewed',
							},
							metadataWindowIdentity: 'metadata-window-item-1-r11',
						},
					],
					operations: [],
					reset: true,
					startIndex: 0,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset: true,
					windows: [
						{
							rows: [
								{
									depth: 1,
									isDirectory: false,
									itemId: 'item-1',
									path: 'Sources/App.swift',
									rowId: 'row-item-1',
								},
							],
							startIndex: 0,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision: 3,
		sequence: 5,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

export function makeBridgeMainCodeViewItem(itemId: string): BridgeMainCodeViewItem {
	return {
		id: itemId,
		type: 'file',
		file: {
			name: 'src/stale.ts',
			contents: 'export const stale = true;\n',
			lang: 'typescript',
			cacheKey: `pierre-content:${itemId}`,
		},
		version: 1,
		bridgeMetadata: {
			itemId,
			displayPath: 'src/stale.ts',
			contentState: 'hydrated',
			contentRoles: ['file'],
			cacheKey: `pierre-content:${itemId}`,
			lineCount: 1,
		},
	};
}
