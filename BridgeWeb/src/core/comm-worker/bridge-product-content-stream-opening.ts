import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
	type BridgeProductDeferred,
} from './bridge-product-async-queue.js';
import type {
	BridgeProductContentFrameFor,
	BridgeProductContentKind,
	BridgeProductContentRequestFor,
	BridgeProductContentTerminal,
} from './bridge-product-content-contracts.js';
import { BridgeProductContentResponseStartAdmission } from './bridge-product-content-response-admission.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';

export interface BridgeProductContentStreamOpening<TContentKind extends BridgeProductContentKind> {
	readonly abortSignal: AbortSignal;
	readonly frames: BridgeProductBoundedAsyncQueue<BridgeProductContentFrameFor<TContentKind>>;
	readonly request: BridgeProductContentRequestFor<TContentKind>;
	readonly responseStartAdmission: BridgeProductContentResponseStartAdmission;
	readonly terminal: BridgeProductDeferred<BridgeProductContentTerminal<TContentKind>>;
}

/** One bounded response queue and terminal are created before network work begins. */
export function openBridgeProductContentStream<
	TContentKind extends BridgeProductContentKind,
>(props: {
	readonly abortSignal: AbortSignal;
	readonly readResponse: (
		opening: BridgeProductContentStreamOpening<TContentKind>,
	) => Promise<void>;
	readonly request: BridgeProductContentRequestFor<TContentKind>;
}): BridgeProductContentStream<TContentKind> {
	const frames = new BridgeProductBoundedAsyncQueue<BridgeProductContentFrameFor<TContentKind>>(32);
	const terminal = createBridgeProductDeferred<BridgeProductContentTerminal<TContentKind>>();
	const responseStartAdmission = new BridgeProductContentResponseStartAdmission();
	void props.readResponse({
		abortSignal: props.abortSignal,
		frames,
		request: props.request,
		responseStartAdmission,
		terminal,
	});
	return {
		contentKind: props.request.contentKind,
		contentRequestId: props.request.contentRequestId,
		frames,
		responseStartControl: responseStartAdmission.control,
		terminal: terminal.promise,
	};
}
