import type { ReactElement, ReactNode } from 'react';

import { Tooltip, TooltipContent, TooltipTrigger } from '../components/ui/tooltip.js';
import { BridgeViewerButton } from './bridge-viewer-button.js';

/** The native command host must supply this projection, even when the product session failed. */
export interface BridgePaneReloadPort {
	readonly command: 'reloadBridgeWebView';
	readonly display: {
		readonly accessibleName: string;
		readonly label: string;
		readonly helpText: string;
		readonly icon: ReactNode;
	};
	readonly requestPaneReload: () => void;
}

export function BridgePaneReloadControl(props: {
	readonly port: BridgePaneReloadPort;
}): ReactElement {
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<BridgeViewerButton
						ariaLabel={props.port.display.accessibleName}
						onClick={props.port.requestPaneReload}
						size="xs"
						variant="outline"
					/>
				}
			>
				{props.port.display.icon}
				{props.port.display.label}
			</TooltipTrigger>
			<TooltipContent side="bottom">{props.port.display.helpText}</TooltipContent>
		</Tooltip>
	);
}
