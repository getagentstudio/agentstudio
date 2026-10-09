import { RefreshCwIcon, type LucideIcon } from 'lucide-react';

export interface BridgeViewerRegionApplyActionSpec {
	readonly accessibleName: string;
	readonly label: string;
	readonly icon: LucideIcon;
	readonly tooltip: string;
	readonly statusLabel: string;
}

export function bridgeViewerRegionApplyActionSpec(
	surface: 'file' | 'markdown' | 'review',
	failed: boolean,
): BridgeViewerRegionApplyActionSpec {
	return {
		accessibleName:
			surface === 'file'
				? 'Update file'
				: surface === 'review'
					? 'Apply now'
					: 'Update Markdown file',
		label: 'Apply now',
		icon: RefreshCwIcon,
		statusLabel: failed
			? "Couldn't apply update"
			: surface === 'review'
				? 'Update ready'
				: 'File changed',
		tooltip: failed
			? 'Save or close the protected annotation editor, then apply again.'
			: 'Keep the draft and load the latest file.',
	};
}
