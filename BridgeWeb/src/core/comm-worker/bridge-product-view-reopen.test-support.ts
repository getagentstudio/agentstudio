import type { BridgeProductTransportSession } from './bridge-product-transport.js';

/** One automatic reopen keeps failure fixtures small; production uses native policy. */
export function createTestMetadataReopenPort(
	onExhausted: BridgeProductTransportSession['reportMetadataReopenExhausted'] = (): void => {},
): Pick<BridgeProductTransportSession, 'metadataReopenPolicy' | 'reportMetadataReopenExhausted'> {
	return {
		metadataReopenPolicy: { viewMaximumConsecutiveResnapshots: 1 },
		reportMetadataReopenExhausted: onExhausted,
	};
}
