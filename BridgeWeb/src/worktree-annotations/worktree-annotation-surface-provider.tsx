import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
	useSyncExternalStore,
	type ReactElement,
	type ReactNode,
} from 'react';

import type { BridgeMarkdownRenderWorkerClient } from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	useWorktreeAnnotationInteraction,
	WorktreeAnnotationInteractionProvider,
} from './worktree-annotation-interaction.js';
import { recordWorktreeAnnotationLifecycleTelemetry } from './worktree-annotation-lifecycle-telemetry.js';
import {
	createWorktreeAnnotationSurfaceClient,
	emptyWorktreeAnnotationProjectionSnapshot,
	type WorktreeAnnotationProjectionSnapshot,
	type WorktreeAnnotationSurfaceClient,
} from './worktree-annotation-surface-client.js';
import { WorktreeAnnotationViewedController } from './worktree-annotation-viewed-controller.js';

const worktreeAnnotationSurfaceClientContext =
	createContext<WorktreeAnnotationSurfaceClient | null>(null);
const worktreeAnnotationMarkdownClientContext =
	createContext<BridgeMarkdownRenderWorkerClient | null>(null);
const worktreeAnnotationSessionSelectionContext =
	createContext<WorktreeAnnotationSessionSelection | null>(null);
const worktreeAnnotationEditSurfaceRegistryContext =
	createContext<WorktreeAnnotationEditSurfaceRegistry | null>(null);
const worktreeAnnotationViewedControllerContext =
	createContext<WorktreeAnnotationViewedController | null>(null);
const worktreeAnnotationSurfaceContext = createContext<'file' | 'review' | null>(null);

export function useWorktreeAnnotationSurface(): 'file' | 'review' | null {
	return useContext(worktreeAnnotationSurfaceContext);
}

export interface WorktreeAnnotationSessionCapabilities {
	readonly canCreateAnnotations: boolean;
	readonly canEditMessages: boolean;
	readonly canFinish: boolean;
	readonly canOutput: boolean;
	readonly canReopen: boolean;
	readonly canReply: boolean;
	readonly canSetThreadResolution: boolean;
}

interface WorktreeAnnotationEditSurfaceRegistry {
	readonly activeEditTokens: ReadonlySet<string>;
	readonly activeNewMessageEditTokens: ReadonlySet<string>;
	readonly prepareActiveEditorsForInstallation: () => Promise<boolean>;
	readonly register: (editToken: string, kind: WorktreeAnnotationEditSurfaceKind) => () => void;
	readonly registerInstallationPreparation: (
		editToken: string,
		prepare: WorktreeAnnotationEditorInstallationPreparation,
	) => () => void;
	readonly releaseWhenInactive: (editToken: string, release: () => Promise<void>) => Promise<void>;
}

type WorktreeAnnotationEditSurfaceKind = 'message' | 'newMessage';
type WorktreeAnnotationEditorInstallationPreparation = () => Promise<boolean>;

interface WorktreeAnnotationEditSurfaceCounts {
	readonly message: number;
	readonly newMessage: number;
}

export interface WorktreeAnnotationSessionSelection {
	readonly activeSessionId: string | null;
	readonly capabilities: WorktreeAnnotationSessionCapabilities;
	readonly requiresExplicitSelection: boolean;
	readonly rootAdmission:
		| { readonly kind: 'implicitOrSingle' }
		| { readonly kind: 'selected'; readonly sessionId: string };
	readonly selectSession: (sessionId: string) => void;
	readonly sessions: WorktreeAnnotationProjectionSnapshot['sessions'];
}

export interface WorktreeAnnotationSurfaceProviderProps {
	readonly children: ReactNode;
	readonly markdownWorkerClient?: BridgeMarkdownRenderWorkerClient | null | undefined;
	readonly surfaceClient: BridgePaneSurfaceClient;
	readonly telemetryRecorder?: BridgeTelemetryRecorder | undefined;
}

export function WorktreeAnnotationSurfaceProvider(
	props: WorktreeAnnotationSurfaceProviderProps,
): ReactElement {
	const telemetryRecorderRef = useRef(props.telemetryRecorder);
	telemetryRecorderRef.current = props.telemetryRecorder;
	const telemetryRecorder = useMemo(
		(): BridgeTelemetryRecorder => ({
			isEnabled: (scope) => telemetryRecorderRef.current?.isEnabled(scope) ?? false,
			record: (sample) => telemetryRecorderRef.current?.record(sample),
			measure: (measureProps) => {
				const currentRecorder = telemetryRecorderRef.current;
				return currentRecorder === undefined
					? measureProps.operation()
					: currentRecorder.measure(measureProps);
			},
			flush: (flushProps) => telemetryRecorderRef.current?.flush(flushProps) ?? true,
		}),
		[],
	);
	// Telemetry setup must not retire the surface's already-installed annotation truth.
	const annotationClient = useMemo(
		() => createWorktreeAnnotationSurfaceClient(props.surfaceClient, telemetryRecorder),
		[props.surfaceClient, telemetryRecorder],
	);
	const projection = useSyncExternalStore(
		annotationClient.subscribe,
		annotationClient.getSnapshot,
		annotationClient.getServerSnapshot,
	);
	const viewedController = useMemo(
		() =>
			new WorktreeAnnotationViewedController((operation) => annotationClient.execute(operation)),
		[annotationClient],
	);
	const subscribeToInstalledReviewPublication = useCallback(
		(listener: () => void): (() => void) =>
			props.surfaceClient.surface === 'review'
				? props.surfaceClient.renderStore.subscribeReviewRefreshPresentation(listener)
				: () => {},
		[props.surfaceClient],
	);
	const getInstalledReviewPublicationKey = useCallback(
		(): string | null => installedReviewPublicationKey(props.surfaceClient),
		[props.surfaceClient],
	);
	const installedPublicationKey = useSyncExternalStore(
		subscribeToInstalledReviewPublication,
		getInstalledReviewPublicationKey,
		getInstalledReviewPublicationKey,
	);
	useEffect((): (() => void) | undefined => {
		if (projection.operationCorrelationId === null || projection.revision === null)
			return undefined;
		const operationCorrelationId = projection.operationCorrelationId;
		const sourceGeneration = projection.sourceGeneration;
		recordWorktreeAnnotationLifecycleTelemetry({
			operationCorrelationId,
			phase: 'annotation_paint_started',
			recorder: props.telemetryRecorder,
			result: 'started',
			sourceGeneration,
			transport: 'local',
			viewer: props.surfaceClient.surface === 'fileView' ? 'file' : 'review',
		});
		let terminalRecorded = false;
		const frame = requestAnimationFrame((): void => {
			terminalRecorded = true;
			recordWorktreeAnnotationLifecycleTelemetry({
				operationCorrelationId,
				phase: 'annotation_paint_terminal',
				recorder: props.telemetryRecorder,
				result: 'success',
				sourceGeneration,
				transport: 'local',
				viewer: props.surfaceClient.surface === 'fileView' ? 'file' : 'review',
			});
		});
		return (): void => {
			cancelAnimationFrame(frame);
			if (terminalRecorded) return;
			recordWorktreeAnnotationLifecycleTelemetry({
				operationCorrelationId,
				phase: 'annotation_paint_terminal',
				recorder: props.telemetryRecorder,
				result: 'cancelled',
				sourceGeneration,
				transport: 'local',
				viewer: props.surfaceClient.surface === 'fileView' ? 'file' : 'review',
			});
		};
	}, [
		projection.operationCorrelationId,
		projection.revision,
		projection.sourceGeneration,
		props.surfaceClient.surface,
		props.telemetryRecorder,
	]);
	const applicableLivingSessionIds = useMemo(
		() =>
			projection.sessions
				.filter(
					(session): boolean =>
						session.lifecycle === 'living' && session.sourceRelationship === 'applicable',
				)
				.map((session) => session.sessionId),
		[projection.sessions],
	);
	const [explicitSessionId, setExplicitSessionId] = useState<string | null>(null);
	const [editSurfaceCountsByEditToken, setEditSurfaceCountsByEditToken] = useState<
		ReadonlyMap<string, WorktreeAnnotationEditSurfaceCounts>
	>(() => new Map<string, WorktreeAnnotationEditSurfaceCounts>());
	const editSurfaceCountsByEditTokenRef = useRef<
		ReadonlyMap<string, WorktreeAnnotationEditSurfaceCounts>
	>(new Map());
	const installationPreparationsByEditTokenRef = useRef<
		Map<string, Map<symbol, WorktreeAnnotationEditorInstallationPreparation>>
	>(new Map());
	useEffect((): void => {
		if (explicitSessionId === null && applicableLivingSessionIds.length === 1) {
			setExplicitSessionId(applicableLivingSessionIds[0] ?? null);
		}
	}, [applicableLivingSessionIds, explicitSessionId]);
	const selectSession = useCallback((sessionId: string): void => {
		setExplicitSessionId(sessionId);
	}, []);
	const explicitSessionStillExists =
		explicitSessionId !== null &&
		projection.sessions.some((session): boolean => session.sessionId === explicitSessionId);
	const activeSessionId = explicitSessionStillExists
		? explicitSessionId
		: applicableLivingSessionIds.length === 1
			? (applicableLivingSessionIds[0] ?? null)
			: null;
	useEffect((): (() => void) | undefined => {
		if (activeSessionId === null) return undefined;
		return annotationClient.acquireSession(activeSessionId);
	}, [activeSessionId, annotationClient]);
	const activeSession =
		projection.sessions.find((session): boolean => session.sessionId === activeSessionId) ?? null;
	const recoveryAllowsMutations = projection.recoveryStatus === 'available';
	const canMutateActiveSession =
		recoveryAllowsMutations &&
		activeSession?.lifecycle === 'living' &&
		activeSession.sourceRelationship === 'applicable';
	const requiresExplicitSelection =
		activeSessionId === null && applicableLivingSessionIds.length > 1;
	const capabilities = useMemo<WorktreeAnnotationSessionCapabilities>(
		() => ({
			canCreateAnnotations:
				recoveryAllowsMutations &&
				!requiresExplicitSelection &&
				(activeSession === null ? projection.sessions.length === 0 : canMutateActiveSession),
			canEditMessages: canMutateActiveSession,
			canFinish: recoveryAllowsMutations && activeSession?.lifecycle === 'living',
			canOutput: recoveryAllowsMutations && activeSession !== null,
			canReopen: recoveryAllowsMutations && activeSession?.lifecycle === 'completed',
			canReply: canMutateActiveSession,
			canSetThreadResolution: canMutateActiveSession,
		}),
		[
			activeSession,
			canMutateActiveSession,
			projection.sessions.length,
			recoveryAllowsMutations,
			requiresExplicitSelection,
		],
	);
	const sessionSelection = useMemo<WorktreeAnnotationSessionSelection>(
		() => ({
			activeSessionId,
			capabilities,
			requiresExplicitSelection,
			rootAdmission:
				activeSessionId === null
					? { kind: 'implicitOrSingle' }
					: { kind: 'selected', sessionId: activeSessionId },
			selectSession,
			sessions: projection.sessions,
		}),
		[activeSessionId, capabilities, projection.sessions, requiresExplicitSelection, selectSession],
	);
	const registerEditSurfaceToken = useCallback(
		(editToken: string, kind: WorktreeAnnotationEditSurfaceKind): (() => void) => {
			const registeredCounts = new Map(editSurfaceCountsByEditTokenRef.current);
			const currentCounts = registeredCounts.get(editToken) ?? { message: 0, newMessage: 0 };
			registeredCounts.set(editToken, {
				...currentCounts,
				[kind]: currentCounts[kind] + 1,
			});
			editSurfaceCountsByEditTokenRef.current = registeredCounts;
			setEditSurfaceCountsByEditToken(registeredCounts);
			return (): void => {
				const latestCountsByToken = editSurfaceCountsByEditTokenRef.current;
				const latestCounts = latestCountsByToken.get(editToken);
				if (latestCounts === undefined || latestCounts[kind] === 0) return;
				const unregisteredCounts = new Map(latestCountsByToken);
				const nextCounts = { ...latestCounts, [kind]: latestCounts[kind] - 1 };
				if (nextCounts.message === 0 && nextCounts.newMessage === 0) {
					unregisteredCounts.delete(editToken);
				} else {
					unregisteredCounts.set(editToken, nextCounts);
				}
				editSurfaceCountsByEditTokenRef.current = unregisteredCounts;
				setEditSurfaceCountsByEditToken(unregisteredCounts);
			};
		},
		[],
	);
	const releaseEditWhenInactive = useCallback(
		(editToken: string, release: () => Promise<void>): Promise<void> =>
			new Promise<void>((resolve, reject): void => {
				queueMicrotask((): void => {
					if (editSurfaceCountsByEditTokenRef.current.has(editToken)) {
						resolve();
						return;
					}
					void release().then(resolve, reject);
				});
			}),
		[],
	);
	const registerInstallationPreparation = useCallback(
		(editToken: string, prepare: WorktreeAnnotationEditorInstallationPreparation): (() => void) => {
			const registrationId = Symbol(editToken);
			const tokenPreparations =
				installationPreparationsByEditTokenRef.current.get(editToken) ??
				new Map<symbol, WorktreeAnnotationEditorInstallationPreparation>();
			tokenPreparations.set(registrationId, prepare);
			installationPreparationsByEditTokenRef.current.set(editToken, tokenPreparations);
			return (): void => {
				if (!tokenPreparations.delete(registrationId)) return;
				if (tokenPreparations.size === 0) {
					installationPreparationsByEditTokenRef.current.delete(editToken);
				}
			};
		},
		[],
	);
	const prepareActiveEditorsForInstallation = useCallback(async (): Promise<boolean> => {
		const activePreparations = [...installationPreparationsByEditTokenRef.current.values()]
			.map((registrations) => [...registrations.values()].at(-1))
			.filter(
				(preparation): preparation is WorktreeAnnotationEditorInstallationPreparation =>
					preparation !== undefined,
			);
		const results = await Promise.all(
			activePreparations.map(async (prepare): Promise<boolean> => {
				try {
					return await prepare();
				} catch {
					return false;
				}
			}),
		);
		return results.every((result): boolean => result);
	}, []);
	const activeEditTokens = useMemo<ReadonlySet<string>>(
		() => new Set(editSurfaceCountsByEditToken.keys()),
		[editSurfaceCountsByEditToken],
	);
	const activeNewMessageEditTokens = useMemo<ReadonlySet<string>>(
		() =>
			new Set(
				[...editSurfaceCountsByEditToken]
					.filter(([, counts]): boolean => counts.newMessage > 0)
					.map(([editToken]): string => editToken),
			),
		[editSurfaceCountsByEditToken],
	);
	const editSurfaceRegistry = useMemo<WorktreeAnnotationEditSurfaceRegistry>(
		() => ({
			activeEditTokens,
			activeNewMessageEditTokens,
			prepareActiveEditorsForInstallation,
			register: registerEditSurfaceToken,
			registerInstallationPreparation,
			releaseWhenInactive: releaseEditWhenInactive,
		}),
		[
			activeEditTokens,
			activeNewMessageEditTokens,
			prepareActiveEditorsForInstallation,
			registerEditSurfaceToken,
			registerInstallationPreparation,
			releaseEditWhenInactive,
		],
	);
	useEffect(
		(): (() => void) => (): void => {
			viewedController.dispose();
			annotationClient.dispose();
		},
		[annotationClient, viewedController],
	);
	useEffect((): void => {
		if (installedPublicationKey === null) return;
		void annotationClient.execute({ kind: 'session.discover' }).catch((): void => {});
	}, [annotationClient, installedPublicationKey]);
	return (
		<worktreeAnnotationMarkdownClientContext.Provider value={props.markdownWorkerClient ?? null}>
			<worktreeAnnotationSurfaceContext.Provider
				value={props.surfaceClient.surface === 'fileView' ? 'file' : 'review'}
			>
				<worktreeAnnotationSurfaceClientContext.Provider value={annotationClient}>
					<worktreeAnnotationViewedControllerContext.Provider value={viewedController}>
						<WorktreeAnnotationInteractionProvider>
							<worktreeAnnotationEditSurfaceRegistryContext.Provider value={editSurfaceRegistry}>
								<WorktreeAnnotationPendingRootComposerEditLeaseReconciler />
								<worktreeAnnotationSessionSelectionContext.Provider value={sessionSelection}>
									{props.children}
									<WorktreeAnnotationThreadExpansionReconciler />
									<WorktreeAnnotationViewedProjectionReconciler />
								</worktreeAnnotationSessionSelectionContext.Provider>
							</worktreeAnnotationEditSurfaceRegistryContext.Provider>
						</WorktreeAnnotationInteractionProvider>
					</worktreeAnnotationViewedControllerContext.Provider>
				</worktreeAnnotationSurfaceClientContext.Provider>
			</worktreeAnnotationSurfaceContext.Provider>
		</worktreeAnnotationMarkdownClientContext.Provider>
	);
}

function WorktreeAnnotationPendingRootComposerEditLeaseReconciler(): null {
	const interaction = useWorktreeAnnotationInteraction();
	useWorktreeAnnotationEditSurfaceToken(
		interaction.pendingRootComposer?.editToken ?? null,
		'newMessage',
	);
	return null;
}

function installedReviewPublicationKey(surfaceClient: BridgePaneSurfaceClient): string | null {
	if (surfaceClient.surface === 'fileView') return 'fileView';
	const identity = surfaceClient.renderStore.getReviewRefreshPresentation().activeIdentity;
	if (identity === null) return null;
	return JSON.stringify([
		identity.packageId,
		identity.publicationId,
		identity.generation,
		identity.revision,
		identity.sourceIdentity,
	]);
}

function WorktreeAnnotationThreadExpansionReconciler(): null {
	const interaction = useWorktreeAnnotationInteraction();
	const projection = useWorktreeAnnotationProjection();
	useEffect((): void => {
		const expansion = interaction.threadExpansion;
		if (expansion.kind !== 'open') return;
		if (
			projection.threads.some(
				(thread): boolean => thread.context.threadId === expansion.threadId,
			) ||
			projection.commandConfirmedThreads.some(
				(thread): boolean => thread.context.threadId === expansion.threadId,
			)
		)
			return;
		const focusTarget = interaction.resolveThreadFocus();
		void interaction.collapseThread().then((): void => focusTarget?.focus());
	}, [interaction, projection.commandConfirmedThreads, projection.threads]);
	return null;
}

function WorktreeAnnotationViewedProjectionReconciler(): null {
	const projection = useWorktreeAnnotationProjection();
	const viewedController = useWorktreeAnnotationViewedController();
	useLayoutEffect((): void => {
		for (const session of projection.sessions) {
			viewedController.reconcileProjection(
				session.sessionId,
				session.semanticRevision,
				projection.threads.flatMap((thread) => thread.messages),
			);
		}
	}, [projection.sessions, projection.threads, viewedController]);
	return null;
}

export function useWorktreeAnnotationMarkdownClient(): BridgeMarkdownRenderWorkerClient | null {
	return useContext(worktreeAnnotationMarkdownClientContext);
}

export function useWorktreeAnnotationSurfaceClient(): WorktreeAnnotationSurfaceClient {
	const annotationClient = useContext(worktreeAnnotationSurfaceClientContext);
	if (annotationClient === null) {
		throw new Error('Worktree annotations require a pane-owned surface provider.');
	}
	return annotationClient;
}

export function useOptionalWorktreeAnnotationSurfaceClient(): WorktreeAnnotationSurfaceClient | null {
	return useContext(worktreeAnnotationSurfaceClientContext);
}

export function useWorktreeAnnotationSessionSelection(): WorktreeAnnotationSessionSelection {
	const selection = useContext(worktreeAnnotationSessionSelectionContext);
	if (selection === null) {
		throw new Error('Worktree annotation session selection requires a surface provider.');
	}
	return selection;
}

export { useWorktreeAnnotationInteraction };

export function useWorktreeAnnotationViewedController(): WorktreeAnnotationViewedController {
	const controller = useContext(worktreeAnnotationViewedControllerContext);
	useSyncExternalStore(
		controller?.subscribe ?? noAnnotationProjectionSubscription,
		controller?.getSnapshot ?? zeroViewedRevision,
		controller?.getSnapshot ?? zeroViewedRevision,
	);
	if (controller === null) {
		throw new Error('Worktree annotation viewed state requires a surface provider.');
	}
	return controller;
}

export function useWorktreeAnnotationActiveEditTokens(): ReadonlySet<string> {
	return (
		useContext(worktreeAnnotationEditSurfaceRegistryContext)?.activeEditTokens ?? emptyEditTokens
	);
}

export function useWorktreeAnnotationActiveNewMessageEditTokens(): ReadonlySet<string> {
	return (
		useContext(worktreeAnnotationEditSurfaceRegistryContext)?.activeNewMessageEditTokens ??
		emptyEditTokens
	);
}

export function useWorktreeAnnotationEditSurfaceToken(
	editToken: string | null,
	kind: WorktreeAnnotationEditSurfaceKind = 'newMessage',
): void {
	const editSurfaceRegistry = useContext(worktreeAnnotationEditSurfaceRegistryContext);
	const register = editSurfaceRegistry?.register;
	useLayoutEffect((): (() => void) | undefined => {
		if (register === undefined || editToken === null) return undefined;
		return register(editToken, kind);
	}, [editToken, kind, register]);
}

export function useWorktreeAnnotationEditorInstallationPreparation(
	editToken: string | null,
	prepare: WorktreeAnnotationEditorInstallationPreparation,
): void {
	const registerInstallationPreparation = useContext(
		worktreeAnnotationEditSurfaceRegistryContext,
	)?.registerInstallationPreparation;
	const prepareRef = useRef(prepare);
	prepareRef.current = prepare;
	useLayoutEffect((): (() => void) | undefined => {
		if (registerInstallationPreparation === undefined || editToken === null) return undefined;
		return registerInstallationPreparation(editToken, (): Promise<boolean> => prepareRef.current());
	}, [editToken, registerInstallationPreparation]);
}

export function useWorktreeAnnotationPrepareActiveEditorsForInstallation(): () => Promise<boolean> {
	return (
		useContext(worktreeAnnotationEditSurfaceRegistryContext)?.prepareActiveEditorsForInstallation ??
		prepareNoActiveEditorsForInstallation
	);
}

export function useWorktreeAnnotationDeferredEditRelease(): WorktreeAnnotationEditSurfaceRegistry['releaseWhenInactive'] {
	return (
		useContext(worktreeAnnotationEditSurfaceRegistryContext)?.releaseWhenInactive ??
		releaseComposerImmediately
	);
}

export function useWorktreeAnnotationProjection(): WorktreeAnnotationProjectionSnapshot {
	const annotationClient = useContext(worktreeAnnotationSurfaceClientContext);
	return useSyncExternalStore(
		annotationClient?.subscribe ?? noAnnotationProjectionSubscription,
		annotationClient?.getSnapshot ?? emptyAnnotationProjectionSnapshot,
		annotationClient?.getServerSnapshot ?? emptyAnnotationProjectionSnapshot,
	);
}

export function useWorktreeAnnotationSessionDemand(sessionId: string | null): void {
	const annotationClient = useContext(worktreeAnnotationSurfaceClientContext);
	useEffect((): (() => void) | undefined => {
		if (annotationClient === null || sessionId === null) return undefined;
		return annotationClient.acquireSession(sessionId);
	}, [annotationClient, sessionId]);
}

function noAnnotationProjectionSubscription(): () => void {
	return (): void => {};
}

function emptyAnnotationProjectionSnapshot(): WorktreeAnnotationProjectionSnapshot {
	return emptyWorktreeAnnotationProjectionSnapshot;
}

function zeroViewedRevision(): number {
	return 0;
}

const emptyEditTokens: ReadonlySet<string> = new Set<string>();

function releaseComposerImmediately(
	_editToken: string,
	release: () => Promise<void>,
): Promise<void> {
	return release();
}

function prepareNoActiveEditorsForInstallation(): Promise<boolean> {
	return Promise.resolve(true);
}
