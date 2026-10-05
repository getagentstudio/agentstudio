import type { BridgeCommWorkerFileViewContentRequest } from './bridge-comm-worker-file-view-runtime-mutation.js';
import { areFileViewContentRequestsEquivalent } from './bridge-comm-worker-file-view-runtime-source.js';

interface BridgeCommWorkerActiveFileContentPreparation {
	readonly request: BridgeCommWorkerFileViewContentRequest;
	readonly abortController: AbortController;
}

interface BridgeCommWorkerFileContentCancellation {
	readonly abortControllersByItemId: Map<string, AbortController>;
	readonly generationByItemId: Map<string, number>;
	readonly abort: (itemId: string) => void;
	readonly abortAll: () => void;
	readonly retainOrSupersede: (
		itemId: string,
		latestRequest: BridgeCommWorkerFileViewContentRequest | undefined,
	) => boolean;
	readonly trackSettlement: (props: {
		readonly abortController: AbortController;
		readonly completion: Promise<void>;
		readonly itemId: string;
		readonly request: BridgeCommWorkerFileViewContentRequest;
		readonly onSupersessionSettled: () => void;
	}) => Promise<void>;
}

export function createBridgeCommWorkerFileContentCancellation(): BridgeCommWorkerFileContentCancellation {
	const abortControllersByItemId = new Map<string, AbortController>();
	const generationByItemId = new Map<string, number>();
	const activePreparationsByItemId = new Map<
		string,
		BridgeCommWorkerActiveFileContentPreparation
	>();
	const abort = (itemId: string): void =>
		abortBridgeCommWorkerFileContentPreparation({
			abortControllersByItemId,
			generationByItemId,
			itemId,
		});
	return {
		abortControllersByItemId,
		generationByItemId,
		abort,
		abortAll: (): void =>
			abortAllBridgeCommWorkerFileContentPreparations({
				abortControllersByItemId,
				generationByItemId,
			}),
		retainOrSupersede: (itemId, latestRequest): boolean => {
			const active = activePreparationsByItemId.get(itemId);
			if (active === undefined) return false;
			// Keep the read owner until completion, even after an abort has been requested.
			if (
				!active.abortController.signal.aborted &&
				!areFileViewContentRequestsEquivalent(active.request, latestRequest ?? null)
			)
				abort(itemId);
			return true;
		},
		trackSettlement: (props): Promise<void> => {
			activePreparationsByItemId.set(props.itemId, {
				request: props.request,
				abortController: props.abortController,
			});
			return props.completion.finally((): void => {
				if (activePreparationsByItemId.get(props.itemId)?.abortController !== props.abortController)
					return;
				activePreparationsByItemId.delete(props.itemId);
				if (props.abortController.signal.aborted) props.onSupersessionSettled();
			});
		},
	};
}

export function abortBridgeCommWorkerFileContentPreparation(props: {
	readonly abortControllersByItemId: Map<string, AbortController>;
	readonly generationByItemId: Map<string, number>;
	readonly itemId: string;
}): void {
	const abortController = props.abortControllersByItemId.get(props.itemId);
	if (abortController === undefined) return;
	props.generationByItemId.set(props.itemId, (props.generationByItemId.get(props.itemId) ?? 0) + 1);
	props.abortControllersByItemId.delete(props.itemId);
	abortController.abort();
}

export function abortAllBridgeCommWorkerFileContentPreparations(props: {
	readonly abortControllersByItemId: Map<string, AbortController>;
	readonly generationByItemId: Map<string, number>;
}): void {
	for (const itemId of props.abortControllersByItemId.keys()) {
		abortBridgeCommWorkerFileContentPreparation({ ...props, itemId });
	}
}
