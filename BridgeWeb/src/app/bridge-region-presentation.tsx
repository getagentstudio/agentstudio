import type { ReactElement, ReactNode } from 'react';

import { Alert, AlertAction, AlertDescription, AlertTitle } from '../components/ui/alert.js';
import { Skeleton } from '../components/ui/skeleton.js';
import {
	bridgePaneFailureDisplaySpec,
	projectBridgePaneFailureSummary,
	type BridgePaneFailureEntry,
} from './bridge-pane-failure-summary.js';
import { BridgePaneReloadControl, type BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import type { BridgeRegionPresentationState } from './bridge-region-presentation-state.js';

export interface BridgeRegionPresentationProps {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly keepContentMounted?: boolean;
	readonly children?: ReactNode;
	readonly emptyCopy?: {
		readonly noSelection: string;
		readonly certified: string;
		readonly noSource?: string;
	};
	readonly region: string;
	readonly testId?: string | undefined;
	readonly retry?: ReactNode;
	readonly failureSummary?: boolean;
	readonly summaryCorrectiveAction?: string | undefined;
	readonly shape: 'tree' | 'code' | 'diff' | 'comments' | 'markdown';
	readonly state: BridgeRegionPresentationState;
}

export function BridgePaneFailureMessage(props: {
	readonly entries: readonly BridgePaneFailureEntry[];
	readonly retryControl: (retry: () => void) => ReactNode;
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
}): ReactElement | null {
	const summary = projectBridgePaneFailureSummary(props.entries);
	if (summary === null) return null;
	return (
		<BridgeRegionPresentation
			region="pane-failure"
			testId="bridge-pane-failure-summary"
			shape="code"
			state={summary.state}
			failureSummary
			summaryCorrectiveAction={summary.correctiveAction}
			paneReloadPort={props.paneReloadPort}
			retry={summary.retry === undefined ? undefined : props.retryControl(summary.retry)}
		/>
	);
}

/** One non-content renderer; callers supply admitted content and command-backed actions. */
export function BridgeRegionPresentation(props: BridgeRegionPresentationProps): ReactElement {
	const { state } = props;
	const retryControl =
		state.kind === 'failed' && state.failure.scope === 'pane' ? (
			props.paneReloadPort === undefined ? undefined : (
				<BridgePaneReloadControl port={props.paneReloadPort} />
			)
		) : (
			props.retry
		);
	const showsContent =
		state.kind === 'content' ||
		state.kind === 'updating' ||
		(state.kind === 'failed' && state.retainsContent);
	const showsFailureControl = props.failureSummary === true;
	return (
		<div
			className={
				props.failureSummary
					? 'relative flex min-w-0 flex-col'
					: 'relative flex h-full min-h-0 min-w-0 flex-col'
			}
			data-bridge-region={props.region}
			data-testid={props.testId}
			data-presentation-state={state.kind}
			data-empty-reason={state.kind === 'empty' ? state.reason : undefined}
			data-content-current={state.kind === 'content' ? 'true' : 'false'}
		>
			{state.kind === 'failed' && showsFailureControl ? (
				<Alert layout="banner" variant="warning">
					<AlertTitle>{state.failure.message}</AlertTitle>
					<AlertDescription>
						{props.summaryCorrectiveAction ??
							(state.failure.kind === 'permanent' ? state.failure.correctiveAction : null)}
					</AlertDescription>
					{state.failure.kind === 'retryable' && retryControl !== undefined ? (
						<AlertAction>{retryControl}</AlertAction>
					) : null}
				</Alert>
			) : state.kind === 'failed' ? (
				<p className="px-3 py-2 text-sm text-muted-foreground">
					{state.retainsContent
						? bridgePaneFailureDisplaySpec.stale
						: state.failure.scope === 'read'
							? props.shape === 'markdown'
								? bridgePaneFailureDisplaySpec.noDocument
								: bridgePaneFailureDisplaySpec.noContent
							: props.shape === 'diff'
								? bridgePaneFailureDisplaySpec.noReview
								: props.shape === 'tree'
									? bridgePaneFailureDisplaySpec.noFiles
									: props.shape === 'comments'
										? bridgePaneFailureDisplaySpec.noComments
										: props.shape === 'markdown'
											? bridgePaneFailureDisplaySpec.noDocument
											: bridgePaneFailureDisplaySpec.noContent}
				</p>
			) : null}
			{state.kind === 'loading' ? (
				<div
					className={
						props.keepContentMounted
							? 'absolute inset-0 flex min-h-0 flex-col gap-2 overflow-hidden p-3'
							: 'flex min-h-0 flex-1 flex-col gap-2 overflow-hidden p-3'
					}
					aria-label="Loading"
					role="status"
					data-skeleton-shape={props.shape}
				>
					{[0, 1, 2, 3, 4, 5].map((rowIndex) => (
						<Skeleton
							key={rowIndex}
							className={
								props.shape === 'comments'
									? 'h-16 w-full'
									: rowIndex % 3 === 1
										? 'h-3 w-2/3'
										: 'h-3 w-full'
							}
						/>
					))}
				</div>
			) : state.kind === 'empty' ? (
				<p
					className={
						props.keepContentMounted
							? 'absolute top-0 left-0 px-3 py-2 text-sm text-muted-foreground'
							: 'px-3 py-2 text-sm text-muted-foreground'
					}
				>
					{state.reason === 'noSource'
						? (props.emptyCopy?.noSource ?? 'This pane has no worktree files.')
						: state.reason === 'noSelection'
							? (props.emptyCopy?.noSelection ?? 'Nothing selected')
							: (props.emptyCopy?.certified ?? 'Nothing to show')}
				</p>
			) : null}
			{showsContent || props.keepContentMounted ? (
				<div
					className={
						showsContent
							? 'h-full min-h-0 min-w-0 flex-1'
							: 'pointer-events-none invisible h-full min-h-0 min-w-0 flex-1'
					}
					aria-hidden={!showsContent}
					inert={!showsContent}
				>
					{props.children}
				</div>
			) : null}
		</div>
	);
}

export interface BridgeRegionPresentationComposition {
	readonly body: ReactElement;
	readonly state: BridgeRegionPresentationState;
	readonly held?: { readonly label: string; readonly action: ReactNode } | undefined;
}

/** The read owner supplies values; the header owner supplies placement. */
export type BridgeRegionPresentationRenderSlot = (
	presentation: BridgeRegionPresentationComposition,
) => ReactElement;

/** Shared quiet status, composed in existing chrome without changing the body geometry. */
export function BridgeRegionUpdatingIndicator(props: {
	readonly updatingLabel?: string;
	readonly state: BridgeRegionPresentationState;
	readonly held?: BridgeRegionPresentationComposition['held'];
	readonly placement?: 'header' | 'floating';
}): ReactElement | null {
	if (props.state.kind !== 'updating') return null;
	const held = props.state.rest === 'held' ? props.held : undefined;
	const label = held?.label ?? props.updatingLabel ?? 'Updating';
	const content = (
		<>
			<span>{label}</span>
			{held === undefined ? null : <span className="sr-only">Updating</span>}
			{held?.action}
		</>
	);
	return props.placement === 'floating' ? (
		<Alert
			aria-label={label}
			className="pointer-events-auto items-center"
			layout="floating"
			role="status"
			variant="floating"
		>
			<AlertTitle>{label}</AlertTitle>
			{held === undefined ? null : <span className="sr-only">Updating</span>}
			{held === undefined ? null : <AlertAction className="self-center">{held.action}</AlertAction>}
		</Alert>
	) : (
		<span
			aria-label={label}
			className="flex shrink-0 items-center gap-2 text-xs text-muted-foreground"
			role="status"
		>
			{content}
		</span>
	);
}
