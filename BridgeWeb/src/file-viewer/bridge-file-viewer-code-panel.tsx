import type { CodeViewLineSelection, CodeViewOptions, SelectedLineRange } from '@pierre/diffs';
import { CodeView, type CodeViewHandle } from '@pierre/diffs/react';
import { useCallback, useLayoutEffect, useMemo, useRef, useState, type ReactElement } from 'react';

import type { BridgeRegionPresentationState } from '../app/bridge-region-presentation-state.js';
import {
	BridgeRegionPresentation,
	BridgeRegionUpdatingIndicator,
	type BridgeRegionPresentationRenderSlot,
} from '../app/bridge-region-presentation.js';
import { BridgeViewerContentHeader } from '../app/bridge-viewer-content-header.js';
import { bridgeViewerRegionApplyActionSpec } from '../app/bridge-viewer-region-apply-action-spec.js';
import { BridgeViewerRegionApplyAction } from '../app/bridge-viewer-region-apply-action.js';
import type { BridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { codeViewSelectionScrollRetryFrameBudget } from '../review-viewer/code-view/bridge-code-view-panel-types.js';
import {
	bridgeCodeViewPresentationItemWithExactSource,
	observeBridgeCodeViewRenderFulfillment,
	reconcileBridgeCodeViewRenderFulfillment,
} from '../review-viewer/code-view/bridge-code-view-render-fulfillment.js';
import {
	fileAnnotationOriginForPierreSelection,
	filePierreAnnotationForExistingCodeViewComposer,
	filePierreAnnotationsForExistingCodeView,
	threadForPierreAnnotation,
	worktreeAnnotationMetadataForPierreAnnotation,
	worktreeAnnotationPierreRangesMatch,
	type WorktreeAnnotationLocatedOrigin,
} from '../review-viewer/code-view/worktree-annotation-pierre-adapter.js';
import { BridgePierreWorkerPoolProvider } from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { useWorktreeAnnotationSelectionDismissal } from '../worktree-annotations/use-worktree-annotation-selection-dismissal.js';
import { mergeWorktreeAnnotationCommandConfirmedThreads } from '../worktree-annotations/worktree-annotation-command-confirmed-presentation.js';
import { createWorktreeAnnotationEditToken } from '../worktree-annotations/worktree-annotation-edit-token.js';
import { useWorktreeAnnotationNavigation } from '../worktree-annotations/worktree-annotation-navigation.js';
import { deriveWorktreeAnnotationShareProjection } from '../worktree-annotations/worktree-annotation-share-projection.js';
import {
	useWorktreeAnnotationActiveEditTokens,
	useWorktreeAnnotationActiveNewMessageEditTokens,
	useWorktreeAnnotationEditSurfaceToken,
	useWorktreeAnnotationInteraction,
	useWorktreeAnnotationPrepareActiveEditorsForInstallation,
	useWorktreeAnnotationProjection,
	useWorktreeAnnotationSessionSelection,
	useWorktreeAnnotationSessionDemand,
} from '../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	WorktreeAnnotationNewMessageComposer,
	WorktreeAnnotationThread,
} from '../worktree-annotations/worktree-annotation-thread.js';
import { bridgeFileContentPresentation } from './bridge-file-region-presentation.js';
import {
	bridgeFileViewerCodeViewItemsForPanelState,
	type BridgeFileViewerCodePanelState,
	type BridgeFileViewerSelectedCodeViewItem,
} from './bridge-file-viewer-code-view-items.js';
import { bridgeFileViewerCodeViewOptions } from './bridge-file-viewer-code-view-options.js';

export type { BridgeFileViewerCodePanelState, BridgeFileViewerSelectedCodeViewItem };

export interface BridgeFileViewerCodePanelProps {
	readonly presentationState?: BridgeRegionPresentationState;
	readonly codeViewOptions?: Readonly<CodeViewOptions<undefined>>;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly openFileState: BridgeFileViewerCodePanelState;
	readonly renderFulfillmentCoordinator: Pick<
		BridgeMainRenderFulfillmentCoordinator,
		'observePostRender' | 'reconcilePublication'
	>;
	readonly selectedCodeViewItem: BridgeFileViewerSelectedCodeViewItem | null;
	readonly totalHeightPixels: number | null;
	readonly renderRegion?: BridgeRegionPresentationRenderSlot | undefined;
}

interface FileAnnotationAdmissionIdentity {
	readonly codeViewItemId: string;
	readonly fileId: string;
	readonly path: string;
	readonly range: SelectedLineRange;
	readonly sourceDescriptorId: string;
}

interface PendingFileAnnotationComposer extends FileAnnotationAdmissionIdentity {
	readonly committed: boolean;
	readonly editToken: string;
	readonly origin: WorktreeAnnotationLocatedOrigin;
}

export function BridgeFileViewerCodePanel(props: BridgeFileViewerCodePanelProps): ReactElement {
	const codeViewHandleRef = useRef<CodeViewHandle<undefined> | null>(null);
	const annotationProjection = useWorktreeAnnotationProjection();
	const annotationSessionSelection = useWorktreeAnnotationSessionSelection();
	const annotationInteraction = useWorktreeAnnotationInteraction();
	const navigation = useWorktreeAnnotationNavigation();
	const navigationRequest =
		navigation?.activeSurface === 'file' &&
		navigation.request?.destination === 'file' &&
		navigation.request.phase === 'ready'
			? navigation.request
			: null;
	const navigationThread =
		navigationRequest === null
			? undefined
			: annotationProjection.threads.find(
					(thread): boolean => thread.context.threadId === navigationRequest.threadId,
				);
	const navigationTarget = useMemo(
		() =>
			navigationRequest !== null && navigationThread !== undefined
				? { request: navigationRequest, thread: navigationThread }
				: null,
		[navigationRequest, navigationThread],
	);
	const [navigationPaintRevision, setNavigationPaintRevision] = useState(0);
	const activeEditTokens = useWorktreeAnnotationActiveEditTokens();
	const activeNewMessageEditTokens = useWorktreeAnnotationActiveNewMessageEditTokens();
	const activeAnnotationSessionId = annotationSessionSelection.activeSessionId;
	useWorktreeAnnotationSessionDemand(activeAnnotationSessionId);
	const serverAnnotationThreads = annotationProjection.threads.filter(
		(thread): boolean =>
			activeAnnotationSessionId !== null &&
			thread.messages.some((message) => message.sessionId === activeAnnotationSessionId) &&
			!thread.messages.every(
				(message): boolean =>
					message.draft?.activeEditToken !== null &&
					message.draft?.activeEditToken !== undefined &&
					activeNewMessageEditTokens.has(message.draft.activeEditToken),
			),
	);
	const commandConfirmedAnnotationThreads = annotationProjection.commandConfirmedThreads.filter(
		(thread): boolean =>
			(activeAnnotationSessionId === null
				? annotationProjection.sessions.length === 0
				: thread.messages.some((message) => message.sessionId === activeAnnotationSessionId)) &&
			!thread.messages.every(
				(message): boolean =>
					message.draft?.activeEditToken !== null &&
					message.draft?.activeEditToken !== undefined &&
					activeNewMessageEditTokens.has(message.draft.activeEditToken),
			),
	);
	const activeAnnotationThreads =
		annotationInteraction.shareMode.kind === 'open'
			? deriveWorktreeAnnotationShareProjection({
					scope: annotationInteraction.shareMode.scope,
					threads: serverAnnotationThreads,
				}).inlineThreads
			: mergeWorktreeAnnotationCommandConfirmedThreads({
					commandConfirmedThreads: commandConfirmedAnnotationThreads,
					serverThreads: serverAnnotationThreads,
				});
	const [pendingAnnotationComposer, setPendingAnnotationComposer] =
		useState<PendingFileAnnotationComposer | null>(null);
	const pendingAnnotationComposerRef = useRef(pendingAnnotationComposer);
	pendingAnnotationComposerRef.current = pendingAnnotationComposer;
	const [composerPresentationRevision, setComposerPresentationRevision] = useState(0);
	const previousRenderedIdentityRef = useRef<{
		readonly fileId: string;
		readonly path: string;
	} | null>(null);
	useWorktreeAnnotationEditSurfaceToken(pendingAnnotationComposer?.editToken ?? null);
	const scrollEffectVersionRef = useRef(0);
	const lastDisplayedItemRef = useRef(props.selectedCodeViewItem);
	const previousItem = lastDisplayedItemRef.current;
	const candidateItem = props.selectedCodeViewItem;
	const previousSourceId = previousItem?.bridgeMetadata.sourceDescriptorId;
	const sourcePinRelease = useBridgeFileViewerSourcePinRelease();
	const retainsAnnotationSource =
		previousSourceId !== sourcePinRelease.releasedSourceDescriptorId &&
		previousItem !== null &&
		candidateItem !== null &&
		previousItem.bridgeMetadata.itemId === candidateItem.bridgeMetadata.itemId &&
		previousItem.bridgeMetadata.displayPath === candidateItem.bridgeMetadata.displayPath &&
		previousSourceId !== undefined &&
		previousSourceId !== candidateItem.bridgeMetadata.sourceDescriptorId &&
		commandConfirmedAnnotationThreads.some(
			(thread): boolean =>
				thread.context.path === previousItem.bridgeMetadata.displayPath &&
				thread.context.sourceIdentity === previousSourceId,
		);
	const displayedCodeViewItem = retainsAnnotationSource ? previousItem : candidateItem;
	useLayoutEffect((): void => {
		// Retain the committed presentation reference, never a second copy of source bytes.
		lastDisplayedItemRef.current = displayedCodeViewItem;
	});
	const codeViewItems = useMemo(() => {
		const items = bridgeFileViewerCodeViewItemsForPanelState({
			openFileState: props.openFileState,
			selectedCodeViewItem: displayedCodeViewItem,
		});
		return items.map((item) => {
			const annotations =
				annotationProjection.revision === null &&
				annotationProjection.commandConfirmedThreads.length === 0
					? []
					: filePierreAnnotationsForExistingCodeView({
							path: item.bridgeMetadata.displayPath,
							sourceDescriptorId: item.bridgeMetadata.sourceDescriptorIdsByRole?.file ?? null,
							threads: activeAnnotationThreads,
						});
			const pendingComposerAnnotation =
				pendingAnnotationComposer === null ||
				!fileAnnotationComposerMatchesItem(pendingAnnotationComposer, item)
					? null
					: filePierreAnnotationForExistingCodeViewComposer({
							editToken: pendingAnnotationComposer.editToken,
							range: pendingAnnotationComposer.range,
						});
			if (
				annotationProjection.revision === null &&
				annotationProjection.commandConfirmedThreads.length === 0 &&
				pendingComposerAnnotation === null
			) {
				return item;
			}
			return bridgeCodeViewPresentationItemWithExactSource({
				presentationItem: Object.assign({}, item, {
					annotations:
						pendingComposerAnnotation === null
							? annotations
							: [...annotations, pendingComposerAnnotation],
					version: annotationPresentationVersion(
						item.version,
						activeEditTokens.size === 0 ? annotationProjection.presentationRevision : null,
						composerPresentationRevision,
					),
				}),
				sourceItem: item,
			});
		});
	}, [
		activeEditTokens.size,
		activeAnnotationThreads,
		annotationProjection.commandConfirmedThreads.length,
		annotationProjection.presentationRevision,
		annotationProjection.revision,
		composerPresentationRevision,
		pendingAnnotationComposer,
		props.openFileState,
		displayedCodeViewItem,
	]);
	const basePresentationState =
		props.presentationState ??
		bridgeFileContentPresentation({
			openFileState: props.openFileState,
			displayedFileId: displayedCodeViewItem?.bridgeMetadata.itemId ?? null,
			surface: { kind: 'current' },
		});
	const presentationState: BridgeRegionPresentationState =
		retainsAnnotationSource && basePresentationState.kind !== 'failed'
			? { kind: 'updating', rest: 'held' }
			: basePresentationState;
	const applyDisplay = bridgeViewerRegionApplyActionSpec(
		'file',
		sourcePinRelease.failedSourceDescriptorId === previousSourceId,
	);
	const held =
		retainsAnnotationSource && previousSourceId !== undefined
			? {
					label: applyDisplay.statusLabel,
					action: (
						<BridgeViewerRegionApplyAction
							display={applyDisplay}
							pending={sourcePinRelease.pendingSourceDescriptorId === previousSourceId}
							onApply={(): void => {
								sourcePinRelease.release(previousSourceId);
							}}
						/>
					),
				}
			: undefined;
	useLayoutEffect((): void => {
		if (displayedCodeViewItem === null) return;
		reconcileBridgeCodeViewRenderFulfillment({
			exactPresentationItem: displayedCodeViewItem,
			getCodeViewHandle: (): CodeViewHandle<undefined> | null => codeViewHandleRef.current,
			renderFulfillmentCoordinator: props.renderFulfillmentCoordinator,
		});
	});
	const handleCodeViewPostRender = useCallback<
		NonNullable<CodeViewOptions<undefined>['onPostRender']>
	>(
		(node, _instance, phase, context): void => {
			if (navigationRequest !== null)
				setNavigationPaintRevision((revision): number => revision + 1);
			observeBridgeCodeViewRenderFulfillment({
				contextItem: context.item,
				getCodeViewHandle: (): CodeViewHandle<undefined> | null => codeViewHandleRef.current,
				itemId: context.item.id,
				phase,
				renderedElement: node,
				renderFulfillmentCoordinator: props.renderFulfillmentCoordinator,
				selectedCodeViewItem: displayedCodeViewItem,
				visibleCodeViewItems: undefined,
			});
		},
		[props.renderFulfillmentCoordinator, displayedCodeViewItem, navigationRequest],
	);
	const admitSelectedRange = useCallback(
		(range: SelectedLineRange | null, itemId: string): void => {
			const selectedItem = displayedCodeViewItem;
			const sourceDescriptorId = selectedItem?.bridgeMetadata.sourceDescriptorId;
			if (
				range === null ||
				selectedItem === null ||
				sourceDescriptorId === undefined ||
				selectedItem.id !== itemId
			) {
				setPendingAnnotationComposer(null);
				annotationInteraction.clearRangePresentation();
				setComposerPresentationRevision((revision): number => revision + 1);
				return;
			}
			const admissionIdentity = fileAnnotationAdmissionIdentity({
				range,
				selectedItem,
				sourceDescriptorId,
			});
			setPendingAnnotationComposer({
				...admissionIdentity,
				committed: false,
				editToken: createWorktreeAnnotationEditToken(),
				origin: fileAnnotationOriginForPierreSelection({
					path: selectedItem.bridgeMetadata.displayPath,
					range,
					sourceDescriptorId,
				}),
			});
			annotationInteraction.setPendingRange(itemId, range);
			setComposerPresentationRevision((revision): number => revision + 1);
		},
		[annotationInteraction, displayedCodeViewItem],
	);
	const retainSelectedRange = useCallback(
		(range: SelectedLineRange | null, itemId: string): void => {
			const currentPresentation = annotationInteraction.pierreRangePresentation;
			if (
				currentPresentation.kind === 'savedThread' &&
				range !== null &&
				currentPresentation.itemId === itemId &&
				worktreeAnnotationPierreRangesMatch(currentPresentation.range, range)
			) {
				return;
			}
			if (pendingAnnotationComposerRef.current?.committed === true) return;
			if (range === null && pendingAnnotationComposerRef.current !== null) return;
			const selectedItem = displayedCodeViewItem;
			const sourceDescriptorId = selectedItem?.bridgeMetadata.sourceDescriptorId;
			if (
				range === null ||
				selectedItem === null ||
				sourceDescriptorId === undefined ||
				selectedItem.id !== itemId
			) {
				setPendingAnnotationComposer(null);
				annotationInteraction.clearRangePresentation();
				setComposerPresentationRevision((revision): number => revision + 1);
				return;
			}
			const selectionIdentity = fileAnnotationAdmissionIdentity({
				range,
				selectedItem,
				sourceDescriptorId,
			});
			setPendingAnnotationComposer((currentComposer) =>
				currentComposer !== null &&
				fileAnnotationIdentityMatchesItem(currentComposer, selectedItem) &&
				worktreeAnnotationPierreRangesMatch(currentComposer.range, range)
					? currentComposer
					: null,
			);
			annotationInteraction.setPendingRange(selectionIdentity.codeViewItemId, range);
			setComposerPresentationRevision((revision): number => revision + 1);
		},
		[annotationInteraction, displayedCodeViewItem],
	);
	const annotationRangePresentation = annotationInteraction.pierreRangePresentation;
	const selectedAnnotationLines: CodeViewLineSelection | null =
		annotationRangePresentation.kind === 'none'
			? null
			: {
					id: annotationRangePresentation.itemId,
					range: annotationRangePresentation.range,
				};
	const handleSelectedAnnotationLinesChange = useCallback(
		(selection: CodeViewLineSelection | null): void => {
			retainSelectedRange(selection?.range ?? null, selection?.id ?? '');
		},
		[retainSelectedRange],
	);
	const clearAnnotationSelection = useCallback(
		(): void => admitSelectedRange(null, ''),
		[admitSelectedRange],
	);
	useWorktreeAnnotationSelectionDismissal({
		active:
			annotationRangePresentation.kind === 'pending' &&
			pendingAnnotationComposer?.committed !== true,
		clearSelection: clearAnnotationSelection,
	});
	const codeViewOptions = useMemo<CodeViewOptions<undefined>>(
		() => ({
			...(props.codeViewOptions ?? bridgeFileViewerCodeViewOptions),
			enableGutterUtility: true,
			enableLineSelection: true,
			onGutterUtilityClick: (range, context): void => {
				if (pendingAnnotationComposerRef.current?.committed === true) return;
				admitSelectedRange(range, context.item.id);
			},
			onLineSelectionEnd: (range, context): void => {
				if (pendingAnnotationComposerRef.current?.committed === true) return;
				if (range === null) admitSelectedRange(null, '');
				else retainSelectedRange(range, context.item.id);
			},
			onPostRender: handleCodeViewPostRender,
		}),
		[admitSelectedRange, handleCodeViewPostRender, props.codeViewOptions, retainSelectedRange],
	);
	useLayoutEffect((): void => {
		const selectedItem = displayedCodeViewItem;
		const composerMatchesDisplayedFile =
			pendingAnnotationComposer !== null &&
			selectedItem !== null &&
			fileAnnotationComposerMatchesItem(pendingAnnotationComposer, selectedItem);
		const selectionMatchesDisplayedFile =
			annotationRangePresentation.kind === 'none' ||
			(selectedItem !== null && annotationRangePresentation.itemId === selectedItem.id);
		if (pendingAnnotationComposer !== null && !composerMatchesDisplayedFile) {
			setPendingAnnotationComposer(null);
			setComposerPresentationRevision((revision): number => revision + 1);
		}
		if (!selectionMatchesDisplayedFile) {
			annotationInteraction.clearRangePresentation();
		}
	}, [
		annotationInteraction,
		annotationRangePresentation,
		pendingAnnotationComposer,
		displayedCodeViewItem,
	]);
	useLayoutEffect((): (() => void) | void => {
		const selectedItem = displayedCodeViewItem;
		if (selectedItem === null) return;
		const currentIdentity = {
			fileId: selectedItem.bridgeMetadata.itemId,
			path: selectedItem.bridgeMetadata.displayPath,
		};
		const previousIdentity = previousRenderedIdentityRef.current;
		previousRenderedIdentityRef.current = currentIdentity;
		const requestedThread = navigationTarget?.thread;
		const revealRequest =
			requestedThread?.context.path === currentIdentity.path ? navigationTarget : null;
		if (
			revealRequest === null &&
			previousIdentity !== null &&
			previousIdentity.fileId === currentIdentity.fileId &&
			previousIdentity.path === currentIdentity.path
		) {
			return;
		}
		const effectVersion = scrollEffectVersionRef.current + 1;
		scrollEffectVersionRef.current = effectVersion;
		let scheduledFrame = 0;
		const reveal = (remainingFrames: number): void => {
			scheduledFrame = requestAnimationFrame((): void => {
				if (scrollEffectVersionRef.current !== effectVersion) return;
				const handle = codeViewHandleRef.current;
				const instance = handle?.getInstance();
				if (revealRequest !== null && revealRequest !== undefined) {
					const owner = instance?.getContainerElement();
					const frame = owner?.querySelector<HTMLElement>(
						`[data-annotation-thread-id="${CSS.escape(revealRequest.request.threadId)}"]`,
					);
					if (
						frame !== null &&
						frame !== undefined &&
						owner !== null &&
						owner !== undefined &&
						instance !== undefined
					) {
						handle?.scrollTo({
							type: 'position',
							position:
								instance.getScrollTop() +
								frame.getBoundingClientRect().top -
								owner.getBoundingClientRect().top -
								8,
							behavior: 'instant',
						});
						navigation?.finish(revealRequest.request.requestId);
						return;
					}
					const endLine = revealRequest.thread.context.endLine;
					if (endLine !== null)
						handle?.scrollTo({
							type: 'line',
							id: selectedItem.id,
							lineNumber: endLine,
							align: 'start',
							behavior: 'instant',
						});
					if (remainingFrames > 0) reveal(remainingFrames - 1);
					return;
				}
				handle?.scrollTo({
					behavior: 'instant',
					position: 0,
					type: 'position',
				});
			});
		};
		reveal(codeViewSelectionScrollRetryFrameBudget);
		const scrollOwner = codeViewHandleRef.current?.getInstance()?.getContainerElement();
		const cancelByUser = (): void => {
			scrollEffectVersionRef.current += 1;
			cancelAnimationFrame(scheduledFrame);
			if (revealRequest != null) navigation?.finish(revealRequest.request.requestId);
		};
		if (revealRequest != null) {
			scrollOwner?.addEventListener('wheel', cancelByUser, { passive: true });
			scrollOwner?.addEventListener('pointerdown', cancelByUser);
		}
		return (): void => {
			cancelAnimationFrame(scheduledFrame);
			scrollOwner?.removeEventListener('wheel', cancelByUser);
			scrollOwner?.removeEventListener('pointerdown', cancelByUser);
		};
	}, [displayedCodeViewItem, navigation, navigationTarget, navigationPaintRevision]);
	const body = (
		<section
			aria-label="Selected file"
			className="relative h-full min-h-0 min-w-0 overflow-hidden bg-background"
			data-bridge-code-view-overflow={codeViewOptions.overflow}
			data-pierre-code-view-owner="CodeView.file"
			data-shiki-rendering="pierre"
			data-testid="bridge-file-viewer-code-canvas"
			data-worktree-open-file-body-preview={displayedCodeViewItem?.file.contents.slice(0, 160)}
			data-worktree-rendered-file-path={displayedCodeViewItem?.bridgeMetadata.displayPath}
			data-worktree-rendered-content-roles={displayedCodeViewItem?.bridgeMetadata.contentRoles.join(
				',',
			)}
			data-worktree-rendered-content-state={displayedCodeViewItem?.bridgeMetadata.contentState}
			data-worktree-rendered-item-id={displayedCodeViewItem?.bridgeMetadata.itemId}
			data-worktree-rendered-line-count={displayedCodeViewItem?.bridgeMetadata.lineCount}
			data-worker-backed-highlighting={
				props.codeViewWorkerPoolEnabled === true ? 'requested' : 'disabled'
			}
			{...(props.openFileState.status === 'idle'
				? {}
				: {
						'data-worktree-open-file-path': props.openFileState.path,
						'data-worktree-open-file-state': props.openFileState.status,
					})}
			{...(props.totalHeightPixels === null
				? {}
				: { 'data-worktree-open-file-total-size': String(props.totalHeightPixels) })}
		>
			<BridgeRegionPresentation
				keepContentMounted
				region="file-content"
				shape="code"
				state={presentationState}
				emptyCopy={{ noSelection: 'Select a file', certified: 'File is empty' }}
			>
				<BridgePierreWorkerPoolProvider
					{...(props.codeViewWorkerPoolEnabled === undefined
						? {}
						: { enabled: props.codeViewWorkerPoolEnabled })}
					{...(props.codeViewWorkerFactory === undefined
						? {}
						: { workerFactory: props.codeViewWorkerFactory })}
				>
					<div
						className={`h-full min-h-0 min-w-0 ${codeViewItems.length > 0 ? '' : 'invisible'}`}
						data-testid="bridge-file-viewer-code-view"
					>
						<CodeView
							className="bridge-code-view-scroll-owner bridge-scrollbar cv-scrollbar relative h-full min-h-0 min-w-0 flex-1 overflow-y-auto overflow-x-hidden overscroll-contain [overflow-anchor:none] [will-change:scroll-position] [&_diffs-container]:overflow-clip [&_diffs-container]:[contain:layout_paint_style]"
							items={codeViewItems}
							options={codeViewOptions}
							onSelectedLinesChange={handleSelectedAnnotationLinesChange}
							renderAnnotation={(annotation, item) => {
								if (item.type !== 'file') return null;
								const metadata = worktreeAnnotationMetadataForPierreAnnotation(annotation);
								if (
									metadata?.kind === 'composer' &&
									pendingAnnotationComposer?.editToken === metadata.editToken
								) {
									return (
										<WorktreeAnnotationNewMessageComposer
											createOperation={(body, editToken, admission) => ({
												admission: admission ?? annotationSessionSelection.rootAdmission,
												body,
												editToken,
												kind: 'root.create',
												origin: pendingAnnotationComposer.origin,
											})}
											editToken={metadata.editToken}
											editSurfaceRegistrationOwner="parent"
											onCancel={() => admitSelectedRange(null, '')}
											onCommitted={() =>
												setPendingAnnotationComposer((currentComposer) =>
													currentComposer?.editToken === metadata.editToken
														? { ...currentComposer, committed: true }
														: currentComposer,
												)
											}
											onSaved={(savedMessage) => {
												const savedThreadIdentity = {
													itemId: item.id,
													range: metadata.range,
													threadId: savedMessage.threadId,
												};
												admitSelectedRange(null, '');
												annotationInteraction.activateSavedThread(savedThreadIdentity);
											}}
											placeholder="Write an annotation in Markdown"
										/>
									);
								}
								if (metadata?.kind !== 'thread') return null;
								const thread = threadForPierreAnnotation({
									annotation,
									threads: activeAnnotationThreads,
								});
								return thread === null ? null : (
									<WorktreeAnnotationThread
										rangeIdentity={{ itemId: item.id, range: metadata.range }}
										thread={thread}
									/>
								);
							}}
							ref={codeViewHandleRef}
							selectedLines={selectedAnnotationLines}
							style={{ height: '100%' }}
						/>
					</div>
				</BridgePierreWorkerPoolProvider>
			</BridgeRegionPresentation>
		</section>
	);
	return (
		props.renderRegion?.({ body, state: presentationState, held }) ?? (
			<section className="grid h-full min-h-0 min-w-0 grid-rows-[auto_minmax(0,1fr)]">
				<BridgeViewerContentHeader
					mode="file"
					statusText={null}
					title={displayedCodeViewItem?.bridgeMetadata.displayPath ?? ''}
					regionIndicator={<BridgeRegionUpdatingIndicator state={presentationState} held={held} />}
				/>
				{body}
			</section>
		)
	);
}

interface BridgeFileViewerSourcePinRelease {
	readonly failedSourceDescriptorId: string | null;
	readonly pendingSourceDescriptorId: string | null;
	/** Leave the pinned source once open annotation editors are prepared, as Markdown does. */
	readonly release: (pinnedSourceDescriptorId: string) => void;
	readonly releasedSourceDescriptorId: string | null;
}

// The code view keeps an older source visible while a command-confirmed comment
// still references it. This is the user's explicit exit when that never reconciles.
function useBridgeFileViewerSourcePinRelease(): BridgeFileViewerSourcePinRelease {
	const prepareEditors = useWorktreeAnnotationPrepareActiveEditorsForInstallation();
	const [releasedSourceDescriptorId, setReleasedSourceDescriptorId] = useState<string | null>(null);
	const [pendingSourceDescriptorId, setPendingSourceDescriptorId] = useState<string | null>(null);
	const [failedSourceDescriptorId, setFailedSourceDescriptorId] = useState<string | null>(null);
	const releaseRequestRef = useRef(0);
	useLayoutEffect(
		(): (() => void) => (): void => {
			releaseRequestRef.current += 1;
		},
		[],
	);
	const release = useCallback(
		(pinnedSourceDescriptorId: string): void => {
			releaseRequestRef.current += 1;
			const releaseRequest = releaseRequestRef.current;
			setPendingSourceDescriptorId(pinnedSourceDescriptorId);
			setFailedSourceDescriptorId(null);
			const settle = (prepared: boolean): void => {
				if (releaseRequestRef.current !== releaseRequest) return;
				setPendingSourceDescriptorId(null);
				if (prepared) setReleasedSourceDescriptorId(pinnedSourceDescriptorId);
				else setFailedSourceDescriptorId(pinnedSourceDescriptorId);
			};
			void prepareEditors().then(settle, (): void => settle(false));
		},
		[prepareEditors],
	);
	return {
		failedSourceDescriptorId,
		pendingSourceDescriptorId,
		release,
		releasedSourceDescriptorId,
	};
}

function fileAnnotationAdmissionIdentity(props: {
	readonly range: SelectedLineRange;
	readonly selectedItem: BridgeFileViewerSelectedCodeViewItem;
	readonly sourceDescriptorId: string;
}): FileAnnotationAdmissionIdentity {
	return {
		codeViewItemId: props.selectedItem.id,
		fileId: props.selectedItem.bridgeMetadata.itemId,
		path: props.selectedItem.bridgeMetadata.displayPath,
		range: props.range,
		sourceDescriptorId: props.sourceDescriptorId,
	};
}

function fileAnnotationIdentityMatchesItem(
	identity: FileAnnotationAdmissionIdentity,
	item: BridgeFileViewerSelectedCodeViewItem,
): boolean {
	return (
		identity.codeViewItemId === item.id &&
		identity.fileId === item.bridgeMetadata.itemId &&
		identity.path === item.bridgeMetadata.displayPath &&
		identity.sourceDescriptorId === item.bridgeMetadata.sourceDescriptorId
	);
}

function fileAnnotationComposerMatchesItem(
	composer: PendingFileAnnotationComposer,
	item: BridgeFileViewerSelectedCodeViewItem,
): boolean {
	return (
		composer.codeViewItemId === item.id &&
		composer.fileId === item.bridgeMetadata.itemId &&
		composer.path === item.bridgeMetadata.displayPath &&
		(composer.committed || composer.sourceDescriptorId === item.bridgeMetadata.sourceDescriptorId)
	);
}

function annotationPresentationVersion(
	contentVersion: number | undefined,
	projectionRevision: number | null,
	composerRevision: number,
): number {
	const baseContentVersion =
		contentVersion !== undefined && contentVersion >= 1_000_000
			? Math.floor(contentVersion / 1_000_000)
			: (contentVersion ?? 0);
	return baseContentVersion * 1_000_000 + (projectionRevision ?? 0) + composerRevision;
}
