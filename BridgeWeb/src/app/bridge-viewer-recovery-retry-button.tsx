import { RefreshCwIcon } from 'lucide-react';
import type { ReactElement } from 'react';

import { Tooltip, TooltipContent, TooltipTrigger } from '../components/ui/tooltip.js';
import { BridgeViewerButton } from './bridge-viewer-button.js';
import {
	bridgeViewerRecoveryActionDisplaySpec,
	type BridgeViewerRecoverySurface,
} from './bridge-viewer-recovery-action-spec.js';

export function BridgeViewerRecoveryRetryButton(props: {
	readonly onClick: () => void;
	readonly surface: BridgeViewerRecoverySurface;
}): ReactElement {
	const displaySpec = bridgeViewerRecoveryActionDisplaySpec(props.surface);
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<BridgeViewerButton
						ariaLabel={displaySpec.accessibleName}
						onClick={props.onClick}
						size="xs"
						variant="outline"
					/>
				}
			>
				<RefreshCwIcon aria-hidden="true" data-icon="inline-start" />
				{displaySpec.label}
			</TooltipTrigger>
			<TooltipContent side="bottom">{displaySpec.tooltip}</TooltipContent>
		</Tooltip>
	);
}
