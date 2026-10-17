import { z } from 'zod';

export const bridgePageReloadCommandDisplaySchema = z
	.object({
		command: z.literal('reloadBridgeWebView'),
		label: z.string().min(1),
		helpText: z.string().min(1),
		icon: z.literal('arrow.clockwise'),
	})
	.strict()
	.readonly();

const bridgePageCommandSurfaceSchema = z.tuple([bridgePageReloadCommandDisplaySchema]).readonly();
export type BridgePageReloadCommandDisplay = z.infer<typeof bridgePageReloadCommandDisplaySchema>;

export const bridgePageRunCommandRequestSchema = z
	.object({
		command: z.literal('reloadBridgeWebView'),
		requestId: z.uuidv7(),
	})
	.strict()
	.readonly();
export type BridgePageRunCommandRequest = z.infer<typeof bridgePageRunCommandRequestSchema>;

/** This closed command projection is independent of the product session and its policy. */
export function readBridgePageReloadCommandDisplay(
	target: EventTarget,
): BridgePageReloadCommandDisplay | null {
	let command: BridgePageReloadCommandDisplay | null = null;
	const receiveCommands = (event: Event): void => {
		if (
			!('detail' in event) ||
			typeof event.detail !== 'object' ||
			event.detail === null ||
			!('pageCommands' in event.detail)
		)
			return;
		const decoded = bridgePageCommandSurfaceSchema.safeParse(event.detail.pageCommands);
		if (decoded.success) command = decoded.data[0];
	};
	target.addEventListener('__bridge_handshake', receiveCommands);
	try {
		target.dispatchEvent(new CustomEvent('__bridge_handshake_request'));
	} finally {
		target.removeEventListener('__bridge_handshake', receiveCommands);
	}
	return command;
}
