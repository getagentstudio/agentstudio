import { RotateCwIcon } from 'lucide-react';
import { uuidv7 } from 'uuidv7';

import {
	readBridgePageReloadCommandDisplay,
	type BridgePageRunCommandRequest,
} from '../bridge/bridge-page-command-surface.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';

/** Bind only the native catalog's pane reload command, before creating a product runtime. */
export function readNativeBridgePaneReloadPort(
	target?: EventTarget,
): BridgePaneReloadPort | undefined {
	const nativeTarget = target ?? (typeof document === 'undefined' ? null : document);
	if (nativeTarget === null) return undefined;
	const command = readBridgePageReloadCommandDisplay(nativeTarget);
	if (command === null) return undefined;
	return {
		command: command.command,
		display: {
			accessibleName: command.label,
			label: command.label,
			helpText: command.helpText,
			icon: (
				<RotateCwIcon
					aria-hidden="true"
					data-icon="inline-start"
					data-command-icon={command.icon}
				/>
			),
		},
		requestPaneReload: (): void => {
			const request = {
				command: command.command,
				requestId: uuidv7(),
			} satisfies BridgePageRunCommandRequest;
			nativeTarget.dispatchEvent(
				new CustomEvent('__bridge_page_command_request', { detail: request }),
			);
		},
	};
}
