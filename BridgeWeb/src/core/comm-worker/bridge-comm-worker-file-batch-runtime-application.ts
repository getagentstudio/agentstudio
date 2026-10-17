import { BridgeCommWorkerFileDisplayEventAuthority } from './bridge-comm-worker-file-display-event-authority.js';
import { BridgeCommWorkerFileQueryProjection } from './bridge-comm-worker-file-query-projection.js';
import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import type { BridgeProductInstalledFileView } from './bridge-product-file-batch-installer.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';

/** Applies one certified File bank to the runtime and publishes its query projection. */
export function applyBridgeCommWorkerFileBatchToRuntime(props: {
	readonly applyRuntimeMutation: (
		mutation: BridgeCommWorkerFileViewRuntimeMutation,
	) => readonly BridgeWorkerServerToMainMessage[];
	readonly displayAuthority: BridgeCommWorkerFileDisplayEventAuthority;
	readonly epoch: number;
	readonly publishMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly queryProjection: BridgeCommWorkerFileQueryProjection;
	readonly view: BridgeProductInstalledFileView;
}): void {
	const display = props.queryProjection.applyDisplayPatches(props.view.displayPatches);
	if (props.view.runtimeMutation !== null) {
		for (const message of props.applyRuntimeMutation(props.view.runtimeMutation)) {
			props.publishMessage(message);
		}
	}
	for (const message of props.displayAuthority.publish({
		epoch: props.epoch,
		patches: display.patches,
	})) {
		props.publishMessage(message);
	}
}
