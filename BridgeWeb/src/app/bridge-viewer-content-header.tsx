import { FileTextIcon, ListChecksIcon } from 'lucide-react';
import type { ReactElement, ReactNode } from 'react';

import { ToggleGroup, ToggleGroupItem } from '../components/ui/toggle-group.js';
import { bridgeViewerChromeHeaderClassName } from './bridge-viewer-chrome.js';
import { cn } from './class-name.js';

export function BridgeViewerContentHeader(props: {
	readonly controls?: ReactNode;
	readonly mode: 'file' | 'review';
	readonly statusText: string | null;
	readonly regionIndicator?: ReactNode;
	readonly title: string;
}): ReactElement {
	return (
		<header
			className={cn(
				'flex min-w-0 items-center justify-between gap-3 px-3',
				bridgeViewerChromeHeaderClassName,
			)}
			data-bridge-viewer-content-topbar="true"
			data-testid="bridge-viewer-content-topbar"
		>
			<div className="flex min-w-0 items-center gap-2">
				<span
					aria-label={viewerModeLabel(props.mode)}
					className="shrink-0 text-foreground"
					data-testid="bridge-viewer-content-mode-icon"
					title={viewerModeLabel(props.mode)}
				>
					{viewerModeIcon(props.mode)}
				</span>
				<span
					className="min-w-0 truncate text-xs text-muted-foreground"
					data-testid="bridge-viewer-content-title"
				>
					{props.title}
				</span>
				{props.statusText === null ? null : (
					<span
						aria-atomic="true"
						aria-live="polite"
						className="shrink-0 text-xs text-muted-foreground"
						data-testid="bridge-viewer-content-status"
						role="status"
					>
						{props.statusText}
					</span>
				)}
				{props.regionIndicator}
			</div>
			{props.controls === undefined ? null : (
				<div
					className="flex shrink-0 items-center gap-1"
					data-testid="bridge-viewer-content-topbar-controls"
				>
					{props.controls}
				</div>
			)}
		</header>
	);
}

function viewerModeIcon(mode: 'file' | 'review'): ReactElement {
	switch (mode) {
		case 'file':
			return <FileTextIcon aria-hidden="true" className="size-3" />;
		case 'review':
			return <ListChecksIcon aria-hidden="true" className="size-3" />;
		default:
			return assertNeverViewerMode(mode);
	}
}

function viewerModeLabel(mode: 'file' | 'review'): string {
	switch (mode) {
		case 'file':
			return 'Files';
		case 'review':
			return 'Review';
		default:
			return assertNeverViewerMode(mode);
	}
}

function assertNeverViewerMode(mode: never): never {
	throw new Error(`Unhandled Bridge viewer mode: ${JSON.stringify(mode)}`);
}

export function BridgeViewerContextSwitcher(props: {
	readonly mode: 'file' | 'review';
	readonly onModeChange: (mode: 'file' | 'review') => void;
}): ReactElement {
	return (
		<ToggleGroup
			aria-label="Bridge viewer context"
			className="grid grid-cols-2"
			data-bridge-segmented-control="viewer-context"
			data-testid="bridge-viewer-context-switcher"
			onValueChange={(modes): void => {
				const nextMode = modes[0];
				switch (nextMode) {
					case 'file':
					case 'review':
						if (nextMode !== props.mode) props.onModeChange(nextMode);
						return;
					case undefined:
						return;
					default:
						return;
				}
			}}
			role="group"
			size="xs"
			variant="segmented"
			value={[props.mode]}
		>
			<BridgeViewerContextButton isSelected={props.mode === 'file'} label="Files" mode="file" />
			<BridgeViewerContextButton
				isSelected={props.mode === 'review'}
				label="Review"
				mode="review"
			/>
		</ToggleGroup>
	);
}

function BridgeViewerContextButton(props: {
	readonly isSelected: boolean;
	readonly label: string;
	readonly mode: 'file' | 'review';
}): ReactElement {
	return (
		<ToggleGroupItem
			aria-label={props.label}
			className="w-full"
			data-bridge-viewer-context-selected={props.isSelected ? 'true' : 'false'}
			data-bridge-viewer-context-target={props.mode}
			data-testid={`bridge-viewer-context-${props.mode}`}
			title={props.label}
			value={props.mode}
		>
			{props.mode === 'file' ? (
				<FileTextIcon aria-hidden="true" />
			) : (
				<ListChecksIcon aria-hidden="true" />
			)}
			<span>{props.label}</span>
		</ToggleGroupItem>
	);
}
