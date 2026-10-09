import { z } from 'zod';

export const bridgePageConfigurationSchema = z
	.object({
		workerBootstrapDeadlineMilliseconds: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
		readyAcknowledgementDeadlineMilliseconds: z
			.number()
			.int()
			.positive()
			.max(Number.MAX_SAFE_INTEGER),
	})
	.strict()
	.readonly();

export type BridgePageConfiguration = z.infer<typeof bridgePageConfigurationSchema>;

export class BridgePageConfigurationReadError extends Error {
	constructor() {
		super('Bridge page configuration is unavailable before bootstrap.');
		this.name = 'BridgePageConfigurationReadError';
	}
}

export function decodeBridgePageConfigurationHandshake(
	event: Event,
): BridgePageConfiguration | null {
	if (
		!('detail' in event) ||
		typeof event.detail !== 'object' ||
		event.detail === null ||
		!('pageConfiguration' in event.detail)
	)
		return null;
	const decoded = bridgePageConfigurationSchema.safeParse(event.detail.pageConfiguration);
	return decoded.success ? decoded.data : null;
}

/** Read document-start configuration independently of the product bootstrap it bounds. */
export function readBridgePageConfiguration(
	target: EventTarget = document,
): BridgePageConfiguration {
	let configuration: BridgePageConfiguration | null = null;
	const receiveConfiguration = (event: Event): void => {
		configuration = decodeBridgePageConfigurationHandshake(event) ?? configuration;
	};
	target.addEventListener('__bridge_handshake', receiveConfiguration);
	try {
		target.dispatchEvent(new CustomEvent('__bridge_handshake_request'));
	} finally {
		target.removeEventListener('__bridge_handshake', receiveConfiguration);
	}
	if (configuration === null) throw new BridgePageConfigurationReadError();
	return configuration;
}
