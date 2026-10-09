import {
	Check,
	FileQuestionMark,
	FileText,
	Folder,
	History,
	ListChecks,
	ListOrdered,
	MoveRight,
	TriangleAlert,
} from 'lucide-react';
import type { ReactElement } from 'react';

import {
	Card,
	InteractiveCard,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from '@/components/ui/card.js';
import { ItemDescription, ItemMetadata, ItemMetadataIcon } from '@/components/ui/item-content.js';

import {
	type BridgeRegionSurfaceStatus,
	type BridgeRegionPresentationState,
} from '../app/bridge-region-presentation-state.js';
import { BridgeRegionPresentation } from '../app/bridge-region-presentation.js';
import {
	WorktreeAnnotationAuthorLabel,
	WorktreeAnnotationInlineSurface,
} from './worktree-annotation-inline-surface.js';
import {
	worktreeAnnotationDestination,
	worktreeAnnotationOpenLabel,
	type WorktreeAnnotationDestination,
} from './worktree-annotation-navigation.js';
import { worktreeAnnotationRegionPresentation } from './worktree-annotation-region-presentation.js';
import type { FilteredShareThread } from './worktree-annotation-share-projection.js';
import type { WorktreeAnnotationThreadProjection } from './worktree-annotation-surface-client.js';

type SharePreviewThread = FilteredShareThread<WorktreeAnnotationThreadProjection>;

export type WorktreeAnnotationSharePreviewReadiness = 'current' | 'unconfirmed' | 'unknown';

interface AnnotationPreviewNavigationProps {
	readonly activeSurface?: WorktreeAnnotationDestination | undefined;
	readonly onOpenThread?:
		| ((
				thread: WorktreeAnnotationThreadProjection,
				destination: WorktreeAnnotationDestination,
		  ) => void)
		| undefined;
	readonly navigationPending?: boolean | undefined;
}

interface WorktreeAnnotationSharePreviewProps extends AnnotationPreviewNavigationProps {
	readonly presentationState?: BridgeRegionPresentationState;
	readonly surfaceStatus?: BridgeRegionSurfaceStatus;
	readonly retryControl?: ReactElement;
	readonly hasSelection?: boolean;
	readonly scope: 'pending' | 'all';
	readonly inlineThreads: readonly SharePreviewThread[];
	readonly otherThreads: readonly SharePreviewThread[];
	readonly readiness: WorktreeAnnotationSharePreviewReadiness;
}

export function WorktreeAnnotationSharePreview(
	props: WorktreeAnnotationSharePreviewProps,
): ReactElement {
	const participatingThreads = [...props.inlineThreads, ...props.otherThreads];
	const hasContent = participatingThreads.some((thread): boolean => thread.messages.length > 0);
	const state =
		props.presentationState ??
		worktreeAnnotationRegionPresentation({
			readiness: props.readiness,
			hasContent,
			hasSelection: props.hasSelection !== false,
			...(props.surfaceStatus === undefined ? {} : { surface: props.surfaceStatus }),
		});
	return (
		<BridgeRegionPresentation
			region="comments"
			shape="comments"
			state={state}
			emptyCopy={{
				noSelection: 'Choose a review session',
				certified: props.scope === 'pending' ? 'No pending comments.' : 'No annotations yet.',
			}}
		>
			<section aria-label="Annotation list" className="mt-4">
				{props.readiness === 'unconfirmed' ? (
					<p className="mb-2 text-sm text-muted-foreground">Last known comments</p>
				) : null}
				<div className="flex min-w-0 flex-col gap-2">
					{participatingThreads.map(
						(thread): ReactElement => (
							<AnnotationThreadCard
								key={thread.context.threadId}
								thread={thread}
								activeSurface={props.activeSurface}
								onOpenThread={props.onOpenThread}
								navigationPending={props.navigationPending}
							/>
						),
					)}
				</div>
			</section>
		</BridgeRegionPresentation>
	);
}

function AnnotationThreadCard(
	props: AnnotationPreviewNavigationProps & { readonly thread: SharePreviewThread },
): ReactElement {
	const { thread } = props;
	const path = thread.context.path;
	const filename = path === null ? 'Session comments' : path.slice(path.lastIndexOf('/') + 1);
	const directory =
		path === null || !path.includes('/') ? '' : path.slice(0, path.lastIndexOf('/'));
	const destination =
		props.activeSurface === undefined
			? null
			: worktreeAnnotationDestination(thread, props.activeSurface);
	const canNavigate =
		destination !== null && props.onOpenThread !== undefined && props.activeSurface !== undefined;
	const lineRange = threadLineRangeLabel(thread);
	const content = (
		<>
			<CardHeader variant="divided">
				<div className="flex min-w-0 items-center justify-between gap-2">
					<CardTitle data-thread-path title={path ?? 'Session comments'} className="truncate">
						{filename}
					</CardTitle>
					{destination === null ? null : (
						<ItemDescription className="shrink-0">
							<ItemMetadataIcon
								icon={destination === 'file' ? FileText : ListChecks}
								label={destination === 'file' ? 'Opens in Files' : 'Opens in Review'}
							/>
							<ItemMetadata>{destination === 'file' ? 'Files' : 'Review'}</ItemMetadata>
						</ItemDescription>
					)}
				</div>
				<div className="flex min-w-0 items-center justify-between gap-2">
					<CardDescription title={directory} className="flex-1">
						<ItemDescription>
							{directory === '' ? null : <ItemMetadataIcon icon={Folder} label="Directory" />}
							<ItemMetadata data-thread-directory truncateFrom="start">
								{directory}
							</ItemMetadata>
						</ItemDescription>
					</CardDescription>
					<ItemDescription className="shrink-0">
						{thread.context.resolution === 'resolved' ? (
							<ItemMetadataIcon icon={Check} label="Resolved conversation" />
						) : null}
						{thread.context.placement === 'outdated' ? (
							<ItemMetadataIcon
								icon={TriangleAlert}
								tone="warning"
								label="Outdated location in this viewer"
							/>
						) : null}
						{thread.context.placement === 'unavailable' ? (
							<ItemMetadataIcon icon={FileQuestionMark} label="Source unavailable in this viewer" />
						) : null}
						{thread.context.placement === 'relocated' ? (
							<ItemMetadataIcon
								icon={MoveRight}
								label="Location updated to follow source changes"
							/>
						) : null}
						{thread.context.sourceRole === 'review_base' ? (
							<ItemMetadataIcon icon={History} label="Original version of this file" />
						) : null}
						<ItemMetadataIcon
							icon={thread.context.startLine === null ? FileText : ListOrdered}
							label={lineRange}
						/>
						<ItemMetadata data-thread-range data-thread-range-label={lineRange} title={lineRange}>
							{thread.context.startLine === null
								? 'File'
								: thread.context.startLine === thread.context.endLine
									? thread.context.startLine
									: `${thread.context.startLine}–${thread.context.endLine}`}
						</ItemMetadata>
					</ItemDescription>
				</div>
			</CardHeader>
			<CardContent>
				<div className="pt-2 pl-2">
					<AnnotationThreadMessages thread={thread} />
				</div>
			</CardContent>
		</>
	);
	return canNavigate && props.activeSurface !== undefined && destination !== null ? (
		<InteractiveCard
			data-file-path={path ?? ''}
			data-thread-id={thread.context.threadId}
			aria-label={`${worktreeAnnotationOpenLabel(props.activeSurface, destination)}: ${filename}, ${lineRange}`}
			onActivate={(): void => props.onOpenThread?.(thread, destination)}
			disabled={props.navigationPending ?? false}
		>
			{content}
		</InteractiveCard>
	) : (
		<Card data-file-path={path ?? ''} data-thread-id={thread.context.threadId}>
			{content}
		</Card>
	);
}

function AnnotationThreadMessages(props: { readonly thread: SharePreviewThread }): ReactElement {
	return (
		<div className="grid min-w-0 gap-1">
			{props.thread.messages.map(
				(message, index): ReactElement => (
					<div data-message-id={message.messageId} key={message.messageId}>
						<WorktreeAnnotationInlineSurface
							authorKind={message.authorKind}
							continueTimeline={index < props.thread.messages.length - 1}
							messageId={message.messageId}
							metadata={
								<>
									<WorktreeAnnotationAuthorLabel authorKind={message.authorKind} />
									<span aria-hidden="true">·</span>
									<span
										aria-label={`Message ${message.threadPosition} of ${message.threadMessageCount}`}
										data-message-number
									>
										{message.threadPosition} of {message.threadMessageCount}
									</span>
								</>
							}
						>
							<p className="break-words whitespace-pre-wrap text-sm text-foreground">
								{message.savedBody}
							</p>
						</WorktreeAnnotationInlineSurface>
					</div>
				),
			)}
		</div>
	);
}

function threadLineRangeLabel(thread: WorktreeAnnotationThreadProjection): string {
	const { endLine, startLine, sourceRole } = thread.context;
	if (startLine === null || endLine === null) return 'File comment';
	const label = startLine === endLine ? `Line ${startLine}` : `Lines ${startLine}–${endLine}`;
	return sourceRole === 'review_base' ? `Old ${label.toLowerCase()}` : label;
}
