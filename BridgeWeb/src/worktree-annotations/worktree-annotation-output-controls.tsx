import { useCallback, useLayoutEffect, useRef, useState, type ReactElement } from 'react';
import { toast } from 'sonner';

import { Drawer } from '@/components/ui/drawer.js';

import { BridgeRegionUpdatingIndicator } from '../app/bridge-region-presentation.js';
import { BridgeViewerContextPanel } from '../app/bridge-viewer-context-panel.js';
import {
	useWorktreeAnnotationNavigation,
	type WorktreeAnnotationDestination,
} from './worktree-annotation-navigation.js';
import { clearWorktreeAnnotationOutputHandled } from './worktree-annotation-output-handled-clear.js';
import { WorktreeAnnotationOutputHistoryControl } from './worktree-annotation-output-history-control.js';
import {
	type WorktreeAnnotationOutputPendingController,
	useWorktreeAnnotationOutputPendingController,
} from './worktree-annotation-output-pending-controller.js';
import { annotationOutputFeedback } from './worktree-annotation-output-presentation.js';
import { WorktreeAnnotationRecoveryNotice } from './worktree-annotation-recovery-notice.js';
import {
	worktreeAnnotationSurfacePresentationStatus,
	worktreeAnnotationRegionPresentation,
} from './worktree-annotation-region-presentation.js';
import {
	WorktreeAnnotationShareModeRow,
	WorktreeAnnotationShareTrigger,
	type WorktreeAnnotationShareScope,
} from './worktree-annotation-share-mode.js';
import { WorktreeAnnotationSharePreview } from './worktree-annotation-share-preview.js';
import { deriveWorktreeAnnotationShareProjection } from './worktree-annotation-share-projection.js';
import type { WorktreeAnnotationThreadProjection } from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationInteraction,
	useWorktreeAnnotationProjection,
	useWorktreeAnnotationSessionSelection,
	useWorktreeAnnotationSurfaceClient,
	useWorktreeAnnotationViewedController,
	useWorktreeAnnotationPrepareActiveEditorsForInstallation,
} from './worktree-annotation-surface-provider.js';

export function WorktreeAnnotationShareHeaderControl(): ReactElement | null {
	const outputPendingController = useWorktreeAnnotationOutputPendingController();
	return (
		<WorktreeAnnotationSharePanelControl
			finalFocus={({ closeReason, trigger }): false | HTMLElement | null =>
				closeReason === 'outside-press' ? false : trigger
			}
			onOpenRequest={(): boolean => true}
			outputPendingController={outputPendingController}
		/>
	);
}

export interface WorktreeAnnotationSharePanelFinalFocusContext {
	readonly closeReason: string | null;
	readonly trigger: HTMLButtonElement | null;
}

export function WorktreeAnnotationSharePanelControl(props: {
	readonly finalFocus: (
		context: WorktreeAnnotationSharePanelFinalFocusContext,
	) => false | HTMLElement | null;
	readonly onOpenRequest: () => boolean;
	readonly outputPendingController: WorktreeAnnotationOutputPendingController;
}): ReactElement | null {
	const interaction = useWorktreeAnnotationInteraction();
	const triggerRef = useRef<HTMLButtonElement | null>(null);
	const lastCloseReasonRef = useRef<string | null>(null);
	const navigation = useWorktreeAnnotationNavigation();
	const lastClosedNavigationRequest = useRef<number | null>(null);
	useLayoutEffect((): void => {
		const requestId = navigation?.request?.requestId;
		if (requestId === undefined || requestId === lastClosedNavigationRequest.current) return;
		lastClosedNavigationRequest.current = requestId;
		lastCloseReasonRef.current = 'annotation-navigation';
		if (interaction.shareMode.kind !== 'closed') interaction.closeShareMode();
	}, [interaction, navigation?.request]);
	const isOpen = interaction.shareMode.kind === 'open';
	const closeShareMode = useCallback((): void => {
		lastCloseReasonRef.current = 'imperative-action';
		interaction.closeShareMode();
	}, [interaction]);
	const closeForNavigation = useCallback((): void => {
		lastCloseReasonRef.current = 'annotation-navigation';
		interaction.closeShareMode();
	}, [interaction]);
	return (
		<Drawer
			modal={false}
			onOpenChange={(nextOpen, eventDetails): void => {
				if (nextOpen) {
					if (!props.onOpenRequest()) {
						eventDetails.cancel();
						return;
					}
					lastCloseReasonRef.current = null;
					interaction.openShareMode();
					return;
				}
				if (
					props.outputPendingController.isPending &&
					lastCloseReasonRef.current !== 'imperative-action'
				) {
					eventDetails.cancel();
					return;
				}
				lastCloseReasonRef.current = eventDetails.reason;
				interaction.closeShareMode();
			}}
			open={isOpen}
			swipeDirection="right"
		>
			<WorktreeAnnotationShareTrigger buttonRef={triggerRef} disabled={false} open={isOpen} />
			<BridgeViewerContextPanel
				ariaLabel="Annotations"
				finalFocus={(): false | HTMLElement | null =>
					lastCloseReasonRef.current === 'annotation-navigation'
						? false
						: props.finalFocus({
								closeReason: lastCloseReasonRef.current,
								trigger: triggerRef.current,
							})
				}
				height="full"
				width="wide"
				inert={!isOpen}
				testId="worktree-annotation-share-shelf"
			>
				<WorktreeAnnotationRecoveryNotice />
				<WorktreeAnnotationShareSurfaceContent
					onNavigationClose={closeForNavigation}
					outputPendingController={props.outputPendingController}
					onClose={closeShareMode}
				/>
			</BridgeViewerContextPanel>
		</Drawer>
	);
}

function WorktreeAnnotationShareSurfaceContent(props: {
	readonly onClose: () => void;
	readonly onNavigationClose: () => void;
	readonly outputPendingController: WorktreeAnnotationOutputPendingController;
}): ReactElement | null {
	const client = useWorktreeAnnotationSurfaceClient();
	const interaction = useWorktreeAnnotationInteraction();
	const projection = useWorktreeAnnotationProjection();
	const commentsSurface = worktreeAnnotationSurfacePresentationStatus(projection.readStatus);
	const selection = useWorktreeAnnotationSessionSelection();
	const viewedController = useWorktreeAnnotationViewedController();
	const navigation = useWorktreeAnnotationNavigation();
	const prepareEditors = useWorktreeAnnotationPrepareActiveEditorsForInstallation();
	const [navigationPending, setNavigationPending] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [errorCanChooseFolder, setErrorCanChooseFolder] = useState(false);
	const [savedExport, setSavedExport] = useState<{
		readonly attemptId: string;
		readonly filename: string;
	} | null>(null);
	const openThread = async (
		thread: WorktreeAnnotationThreadProjection,
		destination: WorktreeAnnotationDestination,
	): Promise<void> => {
		if (
			navigation === null ||
			navigationPending ||
			props.outputPendingController.isPending ||
			selection.activeSessionId === null
		)
			return;
		setNavigationPending(true);
		setError(null);
		try {
			if (!(await prepareEditors())) {
				setError('Finish or cancel the current draft before opening another annotation.');
				return;
			}
			props.onNavigationClose();
			navigation.open({
				destination,
				threadId: thread.context.threadId,
				sessionId: selection.activeSessionId,
			});
		} finally {
			setNavigationPending(false);
		}
	};
	const displayedScopeRef = useRef<WorktreeAnnotationShareScope>('pending');
	if (interaction.shareMode.kind === 'open') {
		displayedScopeRef.current = interaction.shareMode.scope;
	}
	const displayedScope = displayedScopeRef.current;
	const session = projection.sessions.find(
		({ sessionId }) => sessionId === selection.activeSessionId,
	);
	if (projection.revision === null || session === undefined) {
		const knownEmpty = projection.revision !== null && projection.sessions.length === 0;
		const presentationState = worktreeAnnotationRegionPresentation({
			readiness: knownEmpty ? 'current' : 'unknown',
			hasContent: false,
			hasSelection: !selection.requiresExplicitSelection,
			surface: commentsSurface,
		});
		return (
			<WorktreeAnnotationShareModeRow
				regionIndicator={<BridgeRegionUpdatingIndicator state={presentationState} />}
				error={
					selection.requiresExplicitSelection ? 'Choose a review session to share comments.' : null
				}
				isOutputPending={props.outputPendingController.isPending}
				isOutputReady={false}
				membership={
					knownEmpty ? { kind: 'ready', allCount: 0, pendingCount: 0 } : { kind: 'unknown' }
				}
				history={null}
				onCopy={ignoreUnknownOutput}
				onDone={props.onClose}
				onExport={ignoreUnknownOutput}
				onScopeChange={interaction.setShareScope}
				scope={displayedScope}
			>
				<WorktreeAnnotationSharePreview
					presentationState={presentationState}
					surfaceStatus={commentsSurface}
					hasSelection={!selection.requiresExplicitSelection}
					scope={displayedScope}
					inlineThreads={[]}
					otherThreads={[]}
					readiness={knownEmpty ? 'current' : 'unknown'}
				/>
			</WorktreeAnnotationShareModeRow>
		);
	}
	const shared = deriveWorktreeAnnotationShareProjection({
		scope: displayedScope,
		threads: projection.threads.filter((thread) =>
			thread.messages.some(({ sessionId }) => sessionId === session.sessionId),
		),
	});
	const sessionMessages = projection.threads
		.flatMap((thread) => thread.messages)
		.filter((message) => message.sessionId === session.sessionId);
	const isOutputReady =
		selection.capabilities.canOutput &&
		projection.readStatus.kind === 'ready' &&
		!projection.unreconciledCommandReceiptSessionIds.includes(session.sessionId) &&
		viewedController.isOutputReady(session.sessionId, session.semanticRevision, sessionMessages);
	const commentsPresentation = worktreeAnnotationRegionPresentation({
		readiness: isOutputReady ? 'current' : 'unconfirmed',
		hasSelection: true,
		hasContent: [...shared.inlineThreads, ...shared.otherThreads].some(
			(thread): boolean => thread.messages.length > 0,
		),
		surface: commentsSurface,
	});
	const clearHandled = async (attemptId: string, sessionId: string): Promise<void> => {
		try {
			const outcome = await clearWorktreeAnnotationOutputHandled({
				attemptId,
				client,
				sessionId,
			});
			if (outcome.status.kind === 'failed') toast.error(outcome.status.code);
			else toast.success('Comments marked as not handled.');
		} catch (caught: unknown) {
			toast.error(caught instanceof Error ? caught.message : 'Comments could not be updated.');
		}
	};
	const executeOutput = async (
		outputKind: 'clipboardMarkdown' | 'jsonFile',
		scope: WorktreeAnnotationShareScope,
		destination?: 'remembered' | 'choose',
	): Promise<void> => {
		const pendingLease = props.outputPendingController.tryAcquire();
		if (pendingLease === null) return;
		setError(null);
		setErrorCanChooseFolder(false);
		try {
			const outcome = await client.execute({
				...(destination === undefined ? {} : { destination }),
				displayedProjectionRevision: projection.revision ?? 0,
				expectedSessionRevision: session.semanticRevision,
				kind: 'output.scope.commit',
				outputKind,
				scope,
				sessionId: session.sessionId,
				sourceGeneration: projection.sourceGeneration,
			});
			if (outcome.status.kind === 'failed') throw new Error(outcome.status.code);
			if (outcome.status.kind !== 'output') throw new Error('Output returned no result.');
			if (
				outputKind === 'jsonFile' &&
				outcome.status.outcome.kind === 'succeeded' &&
				outcome.status.outcome.summary.destinationFilename !== null
			) {
				setSavedExport({
					attemptId: outcome.status.outcome.summary.attemptId,
					filename: outcome.status.outcome.summary.destinationFilename,
				});
				void client.execute({ kind: 'output.history', sessionId: session.sessionId });
				return;
			}
			const feedback = annotationOutputFeedback(outcome.status.outcome);
			if (
				outcome.status.outcome.kind === 'effect_failed' ||
				outcome.status.outcome.kind === 'effect_and_cleanup_failed'
			) {
				setErrorCanChooseFolder(
					outcome.status.outcome.effectCode === 'missing_folder' ||
						outcome.status.outcome.effectCode === 'permission_denied',
				);
			}
			if (feedback.toast !== null) {
				const attemptId =
					outcome.status.outcome.kind === 'succeeded'
						? outcome.status.outcome.summary.attemptId
						: null;
				toast.success(
					feedback.toast,
					attemptId === null
						? undefined
						: {
								action: {
									label: 'Mark as not handled',
									onClick: () => void clearHandled(attemptId, session.sessionId),
								},
							},
				);
			}
			if (feedback.toast === null && feedback.closeInteraction && feedback.message !== null) {
				if (feedback.severity === 'warning') toast.warning(feedback.message);
				else if (feedback.severity === 'error') toast.error(feedback.message);
				else toast(feedback.message);
			}
			if (feedback.closeInteraction) props.onClose();
			else setError(feedback.message);
			void client
				.execute({ kind: 'output.history', sessionId: session.sessionId })
				.catch((): void => {});
		} catch (caught: unknown) {
			setError(caught instanceof Error ? caught.message : 'Output failed.');
		} finally {
			pendingLease.release();
		}
	};
	const changeFolder = async (): Promise<void> => {
		const pendingLease = props.outputPendingController.tryAcquire();
		if (pendingLease === null) return;
		setError(null);
		try {
			const outcome = await client.execute({ kind: 'output.preference.changeFolder' });
			if (outcome.status.kind === 'failed') throw new Error(outcome.status.code);
			if (outcome.status.kind === 'output') {
				if (outcome.status.outcome.kind === 'destination_cancelled') return;
				if (outcome.status.outcome.kind === 'destination_selection_failed') {
					throw new Error(outcome.status.outcome.selectionError);
				}
			}
			setErrorCanChooseFolder(false);
		} catch (caught: unknown) {
			setError(
				caught instanceof Error ? caught.message : 'The export folder could not be changed.',
			);
		} finally {
			pendingLease.release();
		}
	};
	const revealExport = async (): Promise<void> => {
		if (savedExport === null) return;
		setError(null);
		try {
			const outcome = await client.execute({
				attemptId: savedExport.attemptId,
				kind: 'output.reveal',
			});
			if (outcome.status.kind === 'failed') {
				throw new Error(
					outcome.status.code === 'output_file_missing'
						? 'The exported file no longer exists.'
						: outcome.status.code === 'not_found'
							? 'This export is no longer available.'
							: outcome.status.code,
				);
			}
		} catch (caught: unknown) {
			setError(
				caught instanceof Error ? caught.message : 'The exported file could not be revealed.',
			);
		}
	};
	return (
		<WorktreeAnnotationShareModeRow
			regionIndicator={<BridgeRegionUpdatingIndicator state={commentsPresentation} />}
			error={error}
			errorCanChooseFolder={errorCanChooseFolder}
			isOutputPending={props.outputPendingController.isPending}
			isOutputReady={isOutputReady}
			membership={{
				allCount: shared.allCount,
				kind: 'ready',
				pendingCount: shared.pendingCount,
			}}
			history={
				<WorktreeAnnotationOutputHistoryControl
					embedded
					outputPendingController={props.outputPendingController}
				/>
			}
			onCopy={(scope) => void executeOutput('clipboardMarkdown', scope)}
			onDone={props.onClose}
			onExport={(scope) => void executeOutput('jsonFile', scope, 'remembered')}
			onExportTo={(scope) => void executeOutput('jsonFile', scope, 'choose')}
			onChangeFolder={() => void changeFolder()}
			onReveal={() => void revealExport()}
			savedFilename={savedExport?.filename}
			onScopeChange={interaction.setShareScope}
			scope={displayedScope}
		>
			<WorktreeAnnotationSharePreview
				presentationState={commentsPresentation}
				surfaceStatus={commentsSurface}
				scope={displayedScope}
				{...(navigation === null
					? {}
					: {
							activeSurface: navigation.activeSurface,
							onOpenThread: (
								thread: WorktreeAnnotationThreadProjection,
								destination: WorktreeAnnotationDestination,
							): void => {
								void openThread(thread, destination);
							},
							navigationPending,
						})}
				inlineThreads={shared.inlineThreads}
				otherThreads={shared.otherThreads}
				readiness={isOutputReady ? 'current' : 'unconfirmed'}
			/>
		</WorktreeAnnotationShareModeRow>
	);
}

function ignoreUnknownOutput(): undefined {
	return undefined;
}
