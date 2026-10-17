import {
	useCallback,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
	type ReactElement,
	type RefObject,
	type PointerEvent as ReactPointerEvent,
} from 'react';
import { createPortal } from 'react-dom';

import { AnnotationGutterRow } from '@/components/ui/annotation-gutter.js';

import type { BridgeFileViewerSelectedCodeViewItem } from '../../file-viewer/bridge-file-viewer-code-view-items.js';
import {
	fileAnnotationOriginForPierreSelection,
	fileAnnotationThreadCanRender,
} from '../../review-viewer/code-view/worktree-annotation-pierre-adapter.js';
import { useWorktreeAnnotationSelectionDismissal } from '../../worktree-annotations/use-worktree-annotation-selection-dismissal.js';
import { mergeWorktreeAnnotationCommandConfirmedThreads } from '../../worktree-annotations/worktree-annotation-command-confirmed-presentation.js';
import { createWorktreeAnnotationEditToken } from '../../worktree-annotations/worktree-annotation-edit-token.js';
import type { WorktreeAnnotationRange } from '../../worktree-annotations/worktree-annotation-interaction.js';
import { useWorktreeAnnotationNavigation } from '../../worktree-annotations/worktree-annotation-navigation.js';
import type { WorktreeAnnotationInlineThreadProjection } from '../../worktree-annotations/worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationActiveNewMessageEditTokens,
	useWorktreeAnnotationEditSurfaceToken,
	useWorktreeAnnotationInteraction,
	useWorktreeAnnotationProjection,
	useWorktreeAnnotationSessionDemand,
	useWorktreeAnnotationSessionSelection,
} from '../../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	WorktreeAnnotationNewMessageComposer,
	WorktreeAnnotationThread,
} from '../../worktree-annotations/worktree-annotation-thread.js';
import { BridgeMarkdownRowBackgrounds } from './bridge-markdown-row-backgrounds.js';
import type { BridgeMarkdownSourceTarget } from './bridge-markdown-source-target.js';
import { useBridgeMarkdownAnnotationGesture } from './use-bridge-markdown-annotation-gesture.js';
import { useBridgeMarkdownAnnotationLayout } from './use-bridge-markdown-annotation-layout.js';
type RootComposer = {
	readonly editToken: string;
	readonly range: WorktreeAnnotationRange;
	readonly source: BridgeFileViewerSelectedCodeViewItem;
	readonly origin: ReturnType<typeof fileAnnotationOriginForPierreSelection>;
};

export function BridgeMarkdownAnnotationLayer(props: {
	readonly articleRef: RefObject<HTMLElement | null>;
	readonly targets: readonly BridgeMarkdownSourceTarget[];
	readonly displayedSource: BridgeFileViewerSelectedCodeViewItem | null;
	readonly canAnnotate: boolean;
}): ReactElement {
	const layout = useBridgeMarkdownAnnotationLayout(props);
	const interaction = useWorktreeAnnotationInteraction();
	const projection = useWorktreeAnnotationProjection();
	const session = useWorktreeAnnotationSessionSelection();
	const newMessageTokens = useWorktreeAnnotationActiveNewMessageEditTokens();
	useWorktreeAnnotationSessionDemand(session.activeSessionId);
	const [composer, setComposer] = useState<RootComposer | null>(null);
	useWorktreeAnnotationEditSurfaceToken(composer?.editToken ?? null);
	const source = props.displayedSource;
	const interactionRef = useRef(interaction);
	interactionRef.current = interaction;
	useLayoutEffect((): (() => void) => {
		const itemId = source?.id;
		return (): void => {
			const current = interactionRef.current;
			if (
				current.pierreRangePresentation.kind === 'pending' &&
				current.pierreRangePresentation.itemId === itemId
			)
				current.clearRangePresentation();
		};
	}, [source?.id]);
	const navigation = useWorktreeAnnotationNavigation();
	useLayoutEffect((): (() => void) | undefined => {
		const request = navigation?.request;
		if (
			request == null ||
			request.phase !== 'ready' ||
			navigation?.activeSurface !== 'file' ||
			request.destination !== 'file' ||
			!props.canAnnotate
		)
			return undefined;
		const requestedThread = projection.threads.find(
			(thread): boolean =>
				thread.context.threadId === request.threadId &&
				thread.messages.some((message): boolean => message.sessionId === request.sessionId),
		);
		if (
			requestedThread === undefined ||
			source === null ||
			requestedThread.context.path !== source.bridgeMetadata.displayPath ||
			requestedThread.context.sourceIdentity !== source.bridgeMetadata.sourceDescriptorId
		)
			return undefined;
		const { startLine, endLine } = requestedThread.context;
		if (startLine === null || endLine === null) return undefined;
		if (
			!props.targets.some(
				(target): boolean => target.startLine <= endLine && target.endLine >= startLine,
			)
		) {
			navigation.finish(
				request.requestId,
				"This comment is attached to Markdown lines that aren't rendered. You can still read it in Annotations.",
			);
			return undefined;
		}
		if (interaction.activeThreadId !== request.threadId) return undefined;
		const frame = requestAnimationFrame((): void => {
			const thread = props.articleRef.current?.querySelector<HTMLElement>(
				`[data-annotation-thread-id="${CSS.escape(request.threadId)}"]`,
			);
			if (thread === null || thread === undefined) return;
			thread.scrollIntoView({ block: 'center', behavior: 'instant' });
			navigation.finish(request.requestId);
		});
		return (): void => cancelAnimationFrame(frame);
	}, [
		interaction.activeThreadId,
		layout,
		navigation,
		projection.threads,
		props.articleRef,
		props.canAnnotate,
		props.targets,
		source,
	]);
	const presentation = interaction.pierreRangePresentation;
	const composeRange = useCallback(
		(range: WorktreeAnnotationRange): void => {
			if (
				!props.canAnnotate ||
				source === null ||
				source.bridgeMetadata.sourceDescriptorId === undefined
			)
				return;
			interaction.setPendingRange(source.id, range);
			setComposer({
				editToken: createWorktreeAnnotationEditToken(),
				range,
				source,
				origin: fileAnnotationOriginForPierreSelection({
					path: source.bridgeMetadata.displayPath,
					range,
					sourceDescriptorId: source.bridgeMetadata.sourceDescriptorId,
				}),
			});
		},
		[interaction, props.canAnnotate, source],
	);
	useLayoutEffect((): void => {
		if (presentation.kind === 'savedThread') setComposer(null);
	}, [presentation]);
	const presentedRange =
		presentation.kind !== 'none' && presentation.itemId === source?.id ? presentation.range : null;
	const completeGesture = useCallback(
		(completion: {
			readonly intent: 'select' | 'annotate';
			readonly range: WorktreeAnnotationRange;
		}): void => {
			if (!props.canAnnotate || source === null) return;
			setComposer((currentComposer) =>
				currentComposer?.range.start === completion.range.start &&
				currentComposer.range.end === completion.range.end
					? currentComposer
					: null,
			);
			interaction.setPendingRange(source.id, completion.range);
			if (completion.intent === 'annotate') composeRange(completion.range);
		},
		[composeRange, interaction, props.canAnnotate, source],
	);
	const {
		begin: beginGesture,
		cancel: cancelGesture,
		range: gestureRange,
	} = useBridgeMarkdownAnnotationGesture({
		articleRef: props.articleRef,
		enabled: props.canAnnotate,
		layout,
		selection: presentedRange,
		onEnd: completeGesture,
	});
	const selectedRange = gestureRange ?? presentedRange;
	const clearSelection = useCallback((): void => {
		cancelGesture();
		setComposer(null);
		interaction.clearRangePresentation();
	}, [cancelGesture, interaction]);
	useWorktreeAnnotationSelectionDismissal({
		active: presentation.kind === 'pending',
		clearSelection,
	});
	useEffect((): void => {
		if (
			!props.canAnnotate &&
			composer === null &&
			(gestureRange !== null || presentation.kind === 'pending')
		)
			clearSelection();
	}, [clearSelection, composer, gestureRange, presentation.kind, props.canAnnotate]);
	useLayoutEffect((): void => {
		for (const row of layout)
			row.element.dataset['annotationActive'] =
				selectedRange !== null &&
				row.target.startLine <= selectedRange.end &&
				row.target.endLine >= selectedRange.start
					? 'true'
					: 'false';
	}, [layout, selectedRange]);
	const compose = (target: BridgeMarkdownSourceTarget): void => {
		if (
			!props.canAnnotate ||
			source === null ||
			source.bridgeMetadata.sourceDescriptorId === undefined
		)
			return;
		const range =
			selectedRange !== null &&
			target.startLine <= selectedRange.end &&
			target.endLine >= selectedRange.start
				? selectedRange
				: { start: target.startLine, end: target.endLine };
		composeRange(range);
	};
	const displayedThreadsRef = useRef<readonly WorktreeAnnotationInlineThreadProjection[]>([]);
	const projectedThreads = mergeWorktreeAnnotationCommandConfirmedThreads({
		serverThreads: projection.threads,
		commandConfirmedThreads: projection.commandConfirmedThreads,
	})
		.filter(
			(thread): boolean =>
				source !== null &&
				fileAnnotationThreadCanRender({
					path: source.bridgeMetadata.displayPath,
					sourceDescriptorId: source.bridgeMetadata.sourceDescriptorId ?? null,
					thread,
				}) &&
				(session.activeSessionId === null ||
					thread.messages.some(
						(message): boolean => message.sessionId === session.activeSessionId,
					)) &&
				!thread.messages.every(
					(message): boolean =>
						message.draft?.activeEditToken !== null &&
						message.draft?.activeEditToken !== undefined &&
						newMessageTokens.has(message.draft.activeEditToken),
				),
		)
		.flatMap((thread): readonly WorktreeAnnotationInlineThreadProjection[] => {
			const displayedIdentity = source?.bridgeMetadata.sourceDescriptorId;
			if (thread.context.sourceIdentity === displayedIdentity) return [thread];
			// A successor projection may arrive while the installed article is held by an editor.
			const predecessor = displayedThreadsRef.current.find(
				(candidate): boolean =>
					candidate.context.threadId === thread.context.threadId &&
					candidate.context.sourceIdentity === displayedIdentity,
			);
			return predecessor === undefined ? [] : [{ ...predecessor, messages: thread.messages }];
		});
	const expansion = interaction.threadExpansion;
	const editingThreadId =
		expansion.kind === 'open' && expansion.editor !== null ? expansion.threadId : null;
	const retainedEditingThread = displayedThreadsRef.current.find(
		(thread): boolean => thread.context.threadId === editingThreadId,
	);
	const threads = projectedThreads.map(
		(thread): WorktreeAnnotationInlineThreadProjection =>
			thread.context.threadId === editingThreadId && retainedEditingThread !== undefined
				? retainedEditingThread
				: thread,
	);
	if (
		retainedEditingThread !== undefined &&
		!threads.some((thread): boolean => thread.context.threadId === editingThreadId)
	)
		threads.push(retainedEditingThread);
	useLayoutEffect((): void => {
		displayedThreadsRef.current = threads;
	}, [threads]);
	useLayoutEffect((): void => {
		if (
			!props.canAnnotate ||
			editingThreadId !== null ||
			presentation.kind !== 'savedThread' ||
			source === null
		)
			return;
		const thread = threads.find(
			(candidate): boolean => candidate.context.threadId === presentation.threadId,
		);
		if (
			thread === undefined ||
			(thread.context.startLine === presentation.range.start &&
				thread.context.endLine === presentation.range.end)
		)
			return;
		interaction.activateSavedThread({
			itemId: source.id,
			threadId: thread.context.threadId,
			range: { start: thread.context.startLine, end: thread.context.endLine },
		});
	}, [editingThreadId, interaction, presentation, props.canAnnotate, source, threads]);
	const endpointFor = useCallback(
		(range: WorktreeAnnotationRange): string | undefined =>
			layout.findLast(
				(row): boolean => row.target.startLine <= range.end && row.target.endLine >= range.start,
			)?.target.id,
		[layout],
	);
	const activeCommentTargets = useMemo((): ReadonlySet<string> => {
		const targets = new Set<string>();
		for (const thread of threads) {
			if (thread.context.threadId !== interaction.activeThreadId) continue;
			const endpoint = endpointFor({
				start: thread.context.startLine,
				end: thread.context.endLine,
			});
			if (endpoint !== undefined) targets.add(endpoint);
		}
		if (composer !== null) {
			const endpoint = endpointFor(composer.range);
			if (endpoint !== undefined) targets.add(endpoint);
		}
		return targets;
	}, [composer, endpointFor, interaction.activeThreadId, threads]);
	useLayoutEffect((): void => {
		for (const row of layout)
			row.host.dataset['annotationActive'] = String(activeCommentTargets.has(row.target.id));
	}, [activeCommentTargets, layout]);
	return (
		<>
			<BridgeMarkdownRowBackgrounds
				layout={layout}
				selection={selectedRange}
				activeCommentTargets={activeCommentTargets}
			/>
			<div
				className="bridge-markdown-gutter absolute inset-y-0 w-[54px] touch-none select-none"
				data-bridge-markdown-gutter
			>
				{layout.map(
					(row): ReactElement => (
						<AnnotationGutterRow
							key={row.target.id}
							{...row}
							startLine={row.target.startLine}
							endLine={row.target.endLine}
							hasComments={threads.some(
								(thread): boolean =>
									thread.context.startLine <= row.target.endLine &&
									thread.context.endLine >= row.target.startLine,
							)}
							active={
								selectedRange !== null &&
								row.target.startLine <= selectedRange.end &&
								row.target.endLine >= selectedRange.start
							}
							endpoint={selectedRange !== null && endpointFor(selectedRange) === row.target.id}
							disabled={!props.canAnnotate}
							onSelect={(event: ReactPointerEvent<HTMLButtonElement>): void => {
								beginGesture(event, row.target, 'select');
							}}
							onAnnotatePointerDown={(event: ReactPointerEvent<HTMLButtonElement>): void =>
								beginGesture(event, row.target, 'annotate')
							}
							onKeyboardSelect={(): void => {
								setComposer((currentComposer) =>
									currentComposer?.range.start === row.target.startLine &&
									currentComposer.range.end === row.target.endLine
										? currentComposer
										: null,
								);
								if (source !== null)
									interaction.setPendingRange(source.id, {
										start: row.target.startLine,
										end: row.target.endLine,
									});
							}}
							onAnnotate={(): void => compose(row.target)}
						/>
					),
				)}
			</div>
			{layout.map((row) =>
				createPortal(
					<>
						{threads
							.filter(
								(thread): boolean =>
									endpointFor({ start: thread.context.startLine, end: thread.context.endLine }) ===
									row.target.id,
							)
							.map(
								(thread): ReactElement => (
									<WorktreeAnnotationThread
										key={thread.context.threadId}
										thread={thread}
										rangeIdentity={{
											itemId: source?.id ?? '',
											range: { start: thread.context.startLine, end: thread.context.endLine },
										}}
									/>
								),
							)}
						{composer !== null && endpointFor(composer.range) === row.target.id ? (
							<WorktreeAnnotationNewMessageComposer
								key={composer.editToken}
								editToken={composer.editToken}
								editSurfaceRegistrationOwner="parent"
								placeholder="Write an annotation in Markdown"
								createOperation={(body, editToken, admission) => ({
									kind: 'root.create',
									body,
									editToken,
									admission: admission ?? session.rootAdmission,
									origin: composer.origin,
								})}
								onCancel={(): void => {
									setComposer(null);
									clearSelection();
								}}
								onSaved={(saved): void => {
									setComposer(null);
									interaction.activateSavedThread({
										itemId: composer.source.id,
										range: composer.range,
										threadId: saved.threadId,
									});
								}}
							/>
						) : null}
					</>,
					row.host,
					row.target.id,
				),
			)}
		</>
	);
}
