export interface BridgeProductDeadlineClock {
	schedule(delayMilliseconds: number, onDeadline: () => void): () => void;
}

export const defaultBridgeProductDeadlineClock: BridgeProductDeadlineClock = {
	schedule(delayMilliseconds, onDeadline): () => void {
		const timeoutId = globalThis.setTimeout(onDeadline, delayMilliseconds);
		return (): void => globalThis.clearTimeout(timeoutId);
	},
};
