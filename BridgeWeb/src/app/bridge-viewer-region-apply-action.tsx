import type { ReactElement } from 'react';

import { Button } from '@/components/ui/button.js';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip.js';

import type { BridgeViewerRegionApplyActionSpec } from './bridge-viewer-region-apply-action-spec.js';

/** Preparing editors is a local Apply outcome; it does not fail the region. */
export function BridgeViewerRegionApplyAction(props: {
	readonly display: BridgeViewerRegionApplyActionSpec;
	readonly pending: boolean;
	readonly onApply: () => void;
}): ReactElement {
	const ActionIcon = props.display.icon;
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<Button
						aria-label={props.display.accessibleName}
						disabled={props.pending}
						size="xs"
						type="button"
						variant="outline"
					/>
				}
				onClick={props.onApply}
			>
				<ActionIcon aria-hidden="true" data-icon="inline-start" />
				{props.display.label}
			</TooltipTrigger>
			<TooltipContent side="bottom">{props.display.tooltip}</TooltipContent>
		</Tooltip>
	);
}
