import type { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import type { BridgeWorkerViewRecoveryView } from './bridge-worker-view-recovery-contracts.js';

/** Retry rejoins the surface dependencies even when its prior E3 no longer exists. */
export async function retryBridgeCommWorkerViewDependencies(
	controller: BridgeCommWorkerProductController | null,
	kind: BridgeWorkerViewRecoveryView['kind'],
): Promise<void> {
	if (controller === null) return;
	const surface = kind === 'file.metadata' || kind === 'file.annotations' ? 'file' : 'review';
	await controller.retryMetadataView(surface);
	if (kind === 'file.annotations' || kind === 'review.annotations')
		controller.retryAnnotationProjection(surface);
}
