import type { ReactElement, ReactNode } from 'react';

import {
	ResizableHandle,
	ResizablePanel,
	ResizablePanelGroup,
	useResizablePanelLayout,
} from '../components/ui/resizable.js';

export interface BridgeViewerResizableRailLayoutProps {
	readonly autosaveId: string;
	readonly content: ReactNode;
	readonly contentTestId: string;
	readonly defaultRailSize?: number;
	readonly handleTestId: string;
	readonly isActive?: boolean | undefined;
	readonly maxRailSize?: number;
	readonly minRailSize?: number;
	readonly rail: ReactNode;
	readonly railTestId: string;
	readonly railVisible?: boolean | undefined;
	readonly failureSummary?: ReactNode;
}

const defaultBridgeViewerRailMinSize = 20;
const defaultBridgeViewerRailSize = 28;
const defaultBridgeViewerRailMaxSize = 45;
const bridgeViewerResizableContentPanelId = 'bridge-viewer-content-panel';
const bridgeViewerResizableRightRailPanelId = 'bridge-viewer-right-rail-panel';

type BridgeViewerPanelLayout = Record<string, number>;

export function BridgeViewerResizableRailLayout(
	props: BridgeViewerResizableRailLayoutProps,
): ReactElement {
	if (props.railVisible === false) {
		return (
			<div
				className="flex h-full min-h-0 min-w-0 flex-1 flex-col"
				data-testid={props.contentTestId}
			>
				{props.failureSummary}
				<div className="min-h-0 flex-1">{props.content}</div>
			</div>
		);
	}
	// Gating boundary: only the lightweight fallback/loading shells pass isActive={false} to
	// drop the resizable-panel-group machinery when hidden. Real loaded shells always render
	// their panel-group (isActive={true}) and rely on hidden-subtree dormancy — a display:none
	// subtree does not paint and its ResizeObserver produces no callbacks, so the machinery is
	// already inert. This keeps loaded content mounted: swapping the panel-group for this grid
	// would remount props.content, destroying the Pierre CodeView instance and forcing a
	// re-hydration reload. If a future perf pass needs more, reach for CSS containment
	// (content-visibility) — never unmount loaded shell content.
	if (props.isActive === false) {
		return (
			<div
				className="grid h-full min-h-0 flex-1 grid-cols-[minmax(0,1fr)_minmax(240px,28%)] overflow-hidden"
				data-bridge-viewer-resizable-layout-active="false"
			>
				<div className="h-full min-h-0 min-w-0" data-testid={props.contentTestId}>
					{props.content}
				</div>
				<div className="h-full min-h-0 min-w-[240px]" data-testid={props.railTestId}>
					{props.rail}
				</div>
			</div>
		);
	}

	return <BridgeViewerResizableRailActiveLayout {...props} />;
}

// Owns the resizable-panel hooks so the inactive branch above stays hook-free.
// Toggling `isActive` therefore mounts/unmounts this whole fiber instead of
// changing the outer component's hook count between renders, which otherwise
// violates the Rules of Hooks and corrupts React's Offscreen static flags.
function BridgeViewerResizableRailActiveLayout(
	props: BridgeViewerResizableRailLayoutProps,
): ReactElement {
	const minRailSize = props.minRailSize ?? defaultBridgeViewerRailMinSize;
	const defaultRailSize = props.defaultRailSize ?? defaultBridgeViewerRailSize;
	const maxRailSize = props.maxRailSize ?? defaultBridgeViewerRailMaxSize;
	const contentDefaultSize = Math.max(0, 100 - defaultRailSize);
	const contentPanelId = props.contentTestId;
	const railPanelId = props.railTestId;
	const groupId = `${props.autosaveId}-${props.railTestId}`;
	const persistedLayout = useResizablePanelLayout({
		id: props.autosaveId,
		onlySaveAfterUserInteractions: true,
		panelIds: [bridgeViewerResizableContentPanelId, bridgeViewerResizableRightRailPanelId],
	});
	const panelLayout = translatePanelLayout(
		persistedLayout.defaultLayout,
		[bridgeViewerResizableContentPanelId, bridgeViewerResizableRightRailPanelId],
		[contentPanelId, railPanelId],
	);

	return (
		<ResizablePanelGroup
			className="min-h-0 flex-1"
			defaultLayout={panelLayout}
			id={groupId}
			onLayoutChanged={(layout, meta): void => {
				const storageLayout = translatePanelLayout(
					layout,
					[contentPanelId, railPanelId],
					[bridgeViewerResizableContentPanelId, bridgeViewerResizableRightRailPanelId],
				);
				if (storageLayout !== undefined) {
					persistedLayout.onLayoutChanged(storageLayout, meta);
				}
			}}
			orientation="horizontal"
		>
			<ResizablePanel
				className="h-full min-h-0 min-w-0"
				defaultSize={`${contentDefaultSize}%`}
				id={contentPanelId}
				minSize={`${100 - maxRailSize}%`}
				data-testid={props.contentTestId}
			>
				{props.content}
			</ResizablePanel>
			<ResizableHandle aria-label="Resize file tree sidebar" id={props.handleTestId} withHandle />
			<ResizablePanel
				className="h-full min-h-0 min-w-[240px]"
				defaultSize={`${defaultRailSize}%`}
				id={railPanelId}
				maxSize={`${maxRailSize}%`}
				minSize={`${minRailSize}%`}
				data-testid={props.railTestId}
			>
				{props.rail}
			</ResizablePanel>
		</ResizablePanelGroup>
	);
}

function translatePanelLayout(
	layout: BridgeViewerPanelLayout | undefined,
	fromPanelIds: readonly [string, string],
	toPanelIds: readonly [string, string],
): BridgeViewerPanelLayout | undefined {
	if (layout === undefined) {
		return undefined;
	}

	const [fromContentPanelId, fromRailPanelId] = fromPanelIds;
	const [toContentPanelId, toRailPanelId] = toPanelIds;
	const contentPanelSize = layout[fromContentPanelId];
	const railPanelSize = layout[fromRailPanelId];
	if (contentPanelSize === undefined || railPanelSize === undefined) {
		return undefined;
	}

	return {
		[toContentPanelId]: contentPanelSize,
		[toRailPanelId]: railPanelSize,
	};
}
