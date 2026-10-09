import type { BridgeCommWorkerRow } from './bridge-comm-worker-store.js';
import type { BridgeProductFileContentDescriptor } from './bridge-product-content-contracts.js';
import type { BridgeWorkerFileViewContentMetadata } from './bridge-worker-contracts.js';

export interface BridgeCommWorkerFileViewContentRequest {
	readonly contentDescriptor: BridgeProductFileContentDescriptor;
	readonly itemId: string;
	readonly language: string | null;
	readonly path: string;
	readonly sizeBytes: number;
}

export interface BridgeCommWorkerFileViewRuntimePathUpsert {
	readonly itemId: string;
	readonly path: string;
}

export type BridgeCommWorkerFileViewRuntimeMutation =
	| {
			readonly contentRequestUpserts: readonly BridgeCommWorkerFileViewContentRequest[];
			readonly contentUpserts: readonly BridgeWorkerFileViewContentMetadata[];
			readonly filePathUpserts: readonly BridgeCommWorkerFileViewRuntimePathUpsert[];
			readonly kind: 'reset';
			readonly rowUpserts: readonly BridgeCommWorkerRow[];
	  }
	| {
			readonly contentRemovals: readonly string[];
			readonly contentRequestRemovals: readonly string[];
			readonly contentRequestUpserts: readonly BridgeCommWorkerFileViewContentRequest[];
			readonly contentUpserts: readonly BridgeWorkerFileViewContentMetadata[];
			readonly filePathRemovals: readonly string[];
			readonly filePathUpserts: readonly BridgeCommWorkerFileViewRuntimePathUpsert[];
			readonly kind: 'delta';
			readonly resetContent?: true;
			readonly rowRemovals: readonly string[];
			readonly rowUpserts: readonly BridgeCommWorkerRow[];
	  };
