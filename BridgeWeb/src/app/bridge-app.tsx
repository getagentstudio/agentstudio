import type { ReactElement } from 'react';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

import {
	type BridgePageHandshakeSession,
	installBridgePageHandshakeSession,
} from '../bridge/bridge-page-handshake.js';
import { encodeBridgeWorkerActiveViewerModeUpdateCommand } from '../core/comm-worker/bridge-comm-worker-protocol.js';
import {
	type BridgePaneRuntime,
	type BridgePaneSurfaceClient,
} from '../core/comm-worker/bridge-pane-runtime.js';
import {
	type BridgeActiveViewerModeUpdate,
	type BridgeActiveViewerSource,
} from '../core/comm-worker/bridge-product-control-contracts.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';
import type { BridgeWorkerServerToMainMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import { createBridgePaneTelemetryWorkerFactory } from '../core/telemetry-worker/bridge-pane-telemetry-worker-factory.js';
import {
	createBridgePaneTelemetryWorkerSession,
	type BridgePaneTelemetryWorkerSession,
	type BridgeTelemetryWorkerLike,
} from '../core/telemetry-worker/bridge-pane-telemetry-worker-session.js';
import { bridgeTelemetryWorkerBootstrapSchema } from '../core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import { bridgeTelemetryCompactSampleForEvent } from '../core/telemetry-worker/bridge-telemetry-worker-event-adapter.js';
import type {
	BridgeFileViewerAppProps,
	BridgeFileViewerOpenPathCommand,
} from '../file-viewer/bridge-file-viewer-app.js';
import type { BridgeContentFetch } from '../foundation/content/content-resource-loader.js';
import {
	recordBridgeFileModeSendAttempt,
	recordBridgeFileModeSendSynchronousFailure,
	recordBridgePageReadyState,
} from '../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import {
	createBridgeTelemetryRecorder,
	createBridgeTelemetryRecorderFromClient,
	type BridgeTelemetryRecorder,
} from '../foundation/telemetry/bridge-telemetry-recorder.js';
import { recordBridgeViewerActivationRequestedTelemetrySample } from '../foundation/telemetry/bridge-viewer-activation-telemetry.js';
import { setBridgeViewerNativeOpenAnchor } from '../foundation/telemetry/bridge-viewer-first-interaction.js';
import { WorktreeAnnotationNavigationProvider } from '../worktree-annotations/worktree-annotation-navigation.js';
import type { BridgeAppControlProbe } from './bridge-app-control.js';
import { BridgeFileViewerMode } from './bridge-app-file-viewer-mode.js';
import {
	applyBridgeAppNavigationCommand,
	bridgeAppRememberedNavigationTargetIsEligible,
	clearBridgeAppAcceptedNavigationSource,
	createBridgeAppNavigationAdmissionState,
	reportBridgeAppAcceptedNavigationSource,
	type BridgeAppNavigationAdmissionState,
	type BridgeAppNavigationSource,
	type BridgeAppNavigationTargetCommand,
} from './bridge-app-navigation-admission.js';
import { BridgeReviewViewerMode } from './bridge-app-review-viewer-mode.js';
import { type BridgeMarkdownRenderRuntime } from './markdown/bridge-markdown-render-runtime.js';
import {
	createBridgeMarkdownRuntimeHost,
	disposeBridgeMarkdownRuntimeHost,
	type BridgeMarkdownRuntimeHost,
} from './markdown/bridge-markdown-runtime-host.js';
import { useBridgeAnnotationNavigation } from './use-bridge-annotation-navigation.js';
export type { BridgeReviewFrameAuthority } from './bridge-app-review-frame-authority.js';
import { BridgeAppInitialComposition } from './bridge-app-initial-composition.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import {
	bridgeViewerActivationPrewarm,
	type BridgeViewerActivationPrewarmState,
} from './bridge-viewer-activation-prewarm.js';
import {
	activeViewerModeRetryAttemptAvailable,
	bridgeActiveViewerSourcesEqual,
	createBridgeActiveViewerModeSessionId,
	resolveBridgeWorkerActiveViewerModeRequestResolvers,
	resolvePendingBridgeWorkerActiveViewerModeRequests,
} from './bridge-viewer-active-mode-signal.js';
import { BridgeViewerAppShell } from './bridge-viewer-app-shell.js';
import { BridgeViewerContextSwitcher } from './bridge-viewer-content-header.js';
import { useBridgeViewerContextFocusHandoff } from './bridge-viewer-context-focus-handoff.js';
import { useBridgeCommWorkerSessionTelemetry } from './use-bridge-comm-worker-session-telemetry.js';
import { useBridgePaneFailedStart } from './use-bridge-pane-failed-start.js';

export interface BridgeAppProps {
	readonly paneReloadPort?: BridgePaneReloadPort;
	readonly target?: EventTarget;
	readonly fetchContent?: BridgeContentFetch;
	readonly markdownRuntime?: BridgeMarkdownRenderRuntime | null;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly paneRuntime?: BridgePaneRuntime;
	readonly paneRuntimeFactory?: () => BridgePaneRuntime;
	readonly telemetryWorkerFactory?: () => Promise<BridgeTelemetryWorkerLike>;
	readonly viewerMode?: 'file' | 'review';
	readonly fileViewerProps?: BridgeFileViewerAppProps;
}

declare global {
	interface Window {
		bridgeReviewControlProbe?: BridgeAppControlProbe;
	}
}

type BridgeViewerMode = 'file' | 'review';

interface BridgeViewerActivation {
	readonly cause: 'context_switcher' | 'native_request' | 'review_file_corner';
	readonly sequence: number;
	readonly startedAtPerfNow: number;
	readonly viewer: BridgeViewerMode;
}

type BridgeNativeSurfaceSelectionRequest = Extract<
	BridgeWorkerServerToMainMessage,
	{ readonly kind: 'nativeSurfaceSelectionRequest' }
>;

interface BridgePendingNativeSurfaceSelection {
	readonly arrivalRevision: number;
	readonly request: BridgeNativeSurfaceSelectionRequest;
}

type BridgeActiveViewerSources = Record<BridgeViewerMode, BridgeActiveViewerSource | null>;

interface BridgePaneRuntimeHost {
	readonly fileViewClient: BridgePaneSurfaceClient;
	readonly reviewClient: BridgePaneSurfaceClient;
	readonly runtime: BridgePaneRuntime;
}

export function BridgeApp(props: BridgeAppProps = {}): ReactElement {
	return <BridgeAppInitialComposition {...props} readyContent={BridgeAppRuntimeContent} />;
}

function BridgeAppRuntimeContent(
	props: BridgeAppProps & { readonly paneRuntime: BridgePaneRuntime },
): ReactElement {
	const paneRuntimeHostRef = useRef<BridgePaneRuntimeHost | null>(null);
	paneRuntimeHostRef.current ??= createBridgePaneRuntimeHost(props.paneRuntime);
	const paneRuntimeHost = paneRuntimeHostRef.current;
	const markdownRuntimeHostRef = useRef<BridgeMarkdownRuntimeHost | null>(null);
	markdownRuntimeHostRef.current ??= createBridgeMarkdownRuntimeHost({
		externallyOwnedRuntime: props.markdownRuntime ?? null,
	});
	const markdownRuntimeHost = markdownRuntimeHostRef.current;
	const incomingViewerMode = props.viewerMode;
	const [navigationAdmissionState, setNavigationAdmissionState] =
		useState<BridgeAppNavigationAdmissionState>(() =>
			createBridgeAppNavigationAdmissionState(incomingViewerMode ?? 'review'),
		);
	const navigationAdmissionStateRef = useRef(navigationAdmissionState);
	navigationAdmissionStateRef.current = navigationAdmissionState;
	const activeViewerMode = navigationAdmissionState.activeSurface;
	const [mountedViewerModes, setMountedViewerModes] = useState<ReadonlySet<BridgeViewerMode>>(
		() => new Set<BridgeViewerMode>(['file', 'review']),
	);
	const activationPrewarmStateRef = useRef<BridgeViewerActivationPrewarmState>({
		prewarmedModes: new Set(),
	});
	const activeViewerModeSessionIdRef = useRef<string>(createBridgeActiveViewerModeSessionId());
	const activeViewerModeSequenceRef = useRef(0);
	const activeViewerModeRef = useRef<BridgeViewerMode>(activeViewerMode);
	const previousActiveViewerModeRef = useRef<BridgeViewerMode | null>(null);
	const activeViewerModeActivationRevisionRef = useRef(0);
	const lastSentActiveViewerModeSignalKeyRef = useRef<string | null>(null);
	const activeViewerModeSourceSentActivationRevisionsRef = useRef<Set<number>>(new Set());
	const [activeViewerSources, setActiveViewerSources] = useState<BridgeActiveViewerSources>({
		file: null,
		review: null,
	});
	const activeViewerSourcesRef = useRef<BridgeActiveViewerSources>(activeViewerSources);
	const [activeViewerSourceSignalRevision, setActiveViewerSourceSignalRevision] = useState(0);
	const activeViewerModeRetryAttemptsBySignalKeyRef = useRef<Map<string, number>>(new Map());
	const [activeViewerModeRetryRevision, setActiveViewerModeRetryRevision] = useState(0);
	const viewerActivationSequenceRef = useRef(0);
	const [viewerActivation, setViewerActivation] = useState<BridgeViewerActivation | null>(null);
	const openFileFromReviewCommandSequenceRef = useRef(0);
	const [openFileFromReviewCommand, setOpenFileFromReviewCommand] =
		useState<BridgeFileViewerOpenPathCommand | null>(null);
	const nativeSurfaceSelectionArrivalRevisionRef = useRef(0);
	const [nativeSurfaceSelectionSignalRevision, setNativeSurfaceSelectionSignalRevision] =
		useState(0);
	const pendingNativeSurfaceSelectionRef = useRef<BridgePendingNativeSurfaceSelection | null>(null);
	const telemetryRecorderRef = useRef<BridgeTelemetryRecorder>(createBridgeTelemetryRecorder(null));
	const telemetryWorkerSessionRef = useRef<BridgePaneTelemetryWorkerSession | null>(null);
	const telemetryWorkerFactoryRef = useRef(
		props.telemetryWorkerFactory ?? createBridgePaneTelemetryWorkerFactory(),
	);
	const telemetryRecorder = useMemo(
		(): BridgeTelemetryRecorder => ({
			isEnabled: (scope) => telemetryRecorderRef.current.isEnabled(scope),
			record: (sample) => telemetryRecorderRef.current.record(sample),
			measure: (measureProps) => telemetryRecorderRef.current.measure(measureProps),
			flush: (flushProps) => telemetryRecorderRef.current.flush(flushProps),
		}),
		[],
	);
	const target = props.target ?? document;
	const handshakeSessionRef = useRef<BridgePageHandshakeSession | null>(null);
	const isBridgeReadyGateOpenRef = useRef(false);
	const isBridgeReadyRef = useRef(false);
	const handlePaneFailedStart = useCallback((): void => {
		recordBridgePageReadyState('failed');
		isBridgeReadyRef.current = false;
		isBridgeReadyGateOpenRef.current = false;
	}, []);
	const {
		failedStart: paneFailedStart,
		getFailedStart,
		reportReadyError,
	} = useBridgePaneFailedStart(paneRuntimeHost.runtime, handlePaneFailedStart);
	const bridgeReadyCallbacksRef = useRef<Set<() => void>>(new Set());
	const activeViewerModeWorkerEpochRef = useRef(0);
	const activeViewerModeRequestResolversRef = useRef<Map<string, (didSend: boolean) => void>>(
		new Map(),
	);
	const activeViewerModeSettledResultsRef = useRef<Map<string, boolean>>(new Map());
	const requestContextSwitcherFocusHandoff = useBridgeViewerContextFocusHandoff(activeViewerMode);
	const registerBridgeReadyCallback = useCallback((callback: () => void): (() => void) => {
		bridgeReadyCallbacksRef.current.add(callback);
		if (isBridgeReadyGateOpenRef.current) {
			queueMicrotask(callback);
		}
		return (): void => {
			bridgeReadyCallbacksRef.current.delete(callback);
		};
	}, []);
	useBridgeCommWorkerSessionTelemetry(telemetryRecorder, paneRuntimeHost.runtime);
	const beginViewerActivation = useCallback(
		(
			viewerMode: BridgeViewerMode,
			cause: BridgeViewerActivation['cause'] = 'context_switcher',
			currentState: BridgeAppNavigationAdmissionState,
		): BridgeViewerActivation | null => {
			setMountedViewerModes((currentMountedViewerModes): ReadonlySet<BridgeViewerMode> => {
				if (currentMountedViewerModes.has(viewerMode)) {
					return currentMountedViewerModes;
				}
				return new Set<BridgeViewerMode>([...currentMountedViewerModes, viewerMode]);
			});
			if (currentState.activeSurface === viewerMode) return null;
			viewerActivationSequenceRef.current += 1;
			const activation = {
				cause,
				sequence: viewerActivationSequenceRef.current,
				startedAtPerfNow: performance.now(),
				viewer: viewerMode,
			} satisfies BridgeViewerActivation;
			recordBridgeViewerActivationRequestedTelemetrySample({
				activationSequence: activation.sequence,
				cause,
				fromViewer: currentState.activeSurface,
				sourceAvailable: activeViewerSourcesRef.current[viewerMode] !== null,
				telemetryRecorder,
				traceContext: null,
				viewer: viewerMode,
			});
			setViewerActivation(activation);
			return activation;
		},
		[telemetryRecorder],
	);
	const activateViewerMode = useCallback(
		(
			viewerMode: BridgeViewerMode,
			cause: BridgeViewerActivation['cause'] = 'context_switcher',
		): BridgeViewerActivation | null => {
			const currentState = navigationAdmissionStateRef.current;
			const activation = beginViewerActivation(viewerMode, cause, currentState);
			if (activation === null) return null;
			const nextState = { ...currentState, activeSurface: viewerMode };
			navigationAdmissionStateRef.current = nextState;
			setNavigationAdmissionState(nextState);
			return activation;
		},
		[beginViewerActivation],
	);
	const activateViewerModeFromContextSwitcher = useCallback(
		(viewerMode: BridgeViewerMode): void => {
			requestContextSwitcherFocusHandoff(viewerMode);
			activateViewerMode(viewerMode, 'context_switcher');
		},
		[activateViewerMode, requestContextSwitcherFocusHandoff],
	);
	const openReviewFileInFileViewer = useCallback(
		(path: string): void => {
			openFileFromReviewCommandSequenceRef.current += 1;
			const activation = activateViewerMode('file', 'review_file_corner');
			if (activation === null) return;
			setOpenFileFromReviewCommand({
				activationStartedAtPerfNow: activation.startedAtPerfNow,
				commandId: openFileFromReviewCommandSequenceRef.current,
				path,
				traceContext: null,
			});
		},
		[activateViewerMode],
	);
	const activateAnnotationDestination = useCallback(
		(destination: BridgeViewerMode): boolean =>
			activateViewerMode(destination, 'context_switcher') !== null,
		[activateViewerMode],
	);
	const annotationNavigation = useBridgeAnnotationNavigation({
		activeSurface: activeViewerMode,
		activateDestination: activateAnnotationDestination,
	});
	const applyNativeSurfaceSelectionRequest = useCallback(
		(request: BridgeNativeSurfaceSelectionRequest): void => {
			const currentState = navigationAdmissionStateRef.current;
			const nextState = applyBridgeAppNavigationCommand(currentState, request.navigationCommand);
			if (nextState === currentState) return;
			beginViewerActivation(nextState.activeSurface, 'native_request', currentState);
			nativeSurfaceSelectionArrivalRevisionRef.current += 1;
			const arrivalRevision = nativeSurfaceSelectionArrivalRevisionRef.current;
			pendingNativeSurfaceSelectionRef.current = { arrivalRevision, request };
			navigationAdmissionStateRef.current = nextState;
			setNavigationAdmissionState(nextState);
		},
		[beginViewerActivation],
	);
	useEffect((): (() => void) => {
		recordBridgePageReadyState('awaiting');
		let telemetryConfigurationSequence = 0;
		let isEffectInstalled = true;
		const requestReplacementNativeBootstrap = (): void => {
			const telemetryWorkerSession = telemetryWorkerSessionRef.current;
			if (telemetryWorkerSession?.status() === 'active') {
				try {
					paneRuntimeHost.runtime.installTelemetryProducer({
						enabledScopes: [
							...(handshakeSessionRef.current?.getTelemetryConfig()?.enabledScopes ?? []),
						],
						preReadyRequiredSampleCapacity: telemetryWorkerSession.producerPreReadyBufferMaxSamples,
						preReadyRequiredSampleMaxEncodedBytes:
							telemetryWorkerSession.producerPreReadyBufferMaxBytes,
						producerPort: telemetryWorkerSession.replaceCommProducerPort(),
					});
				} catch {
					handshakeSessionRef.current?.requestTelemetrySessionReplacement();
				}
			}
			handshakeSessionRef.current?.requestProductSessionReplacement();
		};
		const drainTelemetrySession = async (
			session: BridgePaneTelemetryWorkerSession,
		): Promise<void> => {
			try {
				await session.drainAndClose();
			} catch {
				session.dispose();
			}
		};
		const telemetryControlGlobal = globalThis as typeof globalThis & {
			__bridgeTelemetrySidecarControl?: {
				readonly snapshot: () => Promise<unknown>;
				readonly drain: () => Promise<unknown>;
				readonly drainAndClose: () => Promise<unknown>;
			};
		};
		const unavailableTelemetryReport = (): Readonly<Record<string, string>> => ({
			kind: 'unavailable',
			reason: telemetryWorkerSessionRef.current === null ? 'disabled' : 'failed',
		});
		telemetryControlGlobal.__bridgeTelemetrySidecarControl = {
			snapshot: async (): Promise<unknown> => {
				const session = telemetryWorkerSessionRef.current;
				if (session === null || session.status() === 'failed') {
					return unavailableTelemetryReport();
				}
				return {
					kind: 'report',
					telemetrySessionId: session.telemetrySessionId,
					sidecar: await session.snapshot(),
				};
			},
			drain: async (): Promise<unknown> => {
				const session = telemetryWorkerSessionRef.current;
				if (session === null || session.status() === 'failed') {
					return unavailableTelemetryReport();
				}
				const sidecar = await session.drain();
				return {
					kind: 'report',
					telemetrySessionId: session.telemetrySessionId,
					sidecar,
				};
			},
			drainAndClose: async (): Promise<unknown> => {
				const session = telemetryWorkerSessionRef.current;
				if (session === null || session.status() === 'failed') {
					return unavailableTelemetryReport();
				}
				const sidecar = await session.drainAndClose();
				return {
					kind: 'report',
					telemetrySessionId: session.telemetrySessionId,
					sidecar,
				};
			},
		};
		const configureTelemetryRecorder = (
			nextTelemetryConfig = handshakeSessionRef.current?.getTelemetryConfig() ?? null,
		): void => {
			telemetryConfigurationSequence += 1;
			const configurationSequence = telemetryConfigurationSequence;
			const retiringSession = telemetryWorkerSessionRef.current;
			telemetryWorkerSessionRef.current = null;
			telemetryRecorderRef.current = createBridgeTelemetryRecorder(null);
			if (retiringSession !== null) {
				void drainTelemetrySession(retiringSession);
			}
			setBridgeViewerNativeOpenAnchor({
				openEpochUnixMillis: nextTelemetryConfig?.viewerOpenEpochUnixMillis ?? null,
				traceparent: nextTelemetryConfig?.viewerOpenTraceparent ?? null,
			});
			const decodedWorkerBootstrap = bridgeTelemetryWorkerBootstrapSchema.safeParse(
				nextTelemetryConfig?.workerBootstrap,
			);
			if (!decodedWorkerBootstrap.success || nextTelemetryConfig === null) {
				return;
			}
			void telemetryWorkerFactoryRef
				.current()
				.then((worker): void => {
					if (!isEffectInstalled || configurationSequence !== telemetryConfigurationSequence) {
						worker.terminate();
						return;
					}
					const telemetryWorkerSession = createBridgePaneTelemetryWorkerSession({
						bootstrap: decodedWorkerBootstrap.data,
						createWorker: () => worker,
					});
					if (telemetryWorkerSession === null) {
						worker.terminate();
						return;
					}
					telemetryWorkerSessionRef.current = telemetryWorkerSession;
					paneRuntimeHost.runtime.installTelemetryProducer({
						enabledScopes: [...nextTelemetryConfig.enabledScopes],
						preReadyRequiredSampleCapacity:
							decodedWorkerBootstrap.data.policy.producerPreReadyBufferMaxSamples,
						preReadyRequiredSampleMaxEncodedBytes:
							decodedWorkerBootstrap.data.policy.producerPreReadyBufferMaxBytes,
						producerPort: telemetryWorkerSession.commProducerPort,
					});
					telemetryRecorderRef.current = createBridgeTelemetryRecorderFromClient(
						nextTelemetryConfig,
						{
							record: (sample): void => {
								telemetryWorkerSession.mainProducer.record(
									bridgeTelemetryCompactSampleForEvent(
										sample,
										performance.timeOrigin + performance.now(),
									),
								);
							},
							flush: (): boolean => telemetryWorkerSession.mainProducer.flushLossSummary(),
						},
					);
				})
				.catch((): void => {
					telemetryRecorderRef.current = createBridgeTelemetryRecorder(null);
				});
		};
		paneRuntimeHost.runtime.setNativeBootstrapRequester(requestReplacementNativeBootstrap);
		handshakeSessionRef.current = installBridgePageHandshakeSession(target, {
			onProductSessionBootstrap: (productSessionBootstrap): void => {
				paneRuntimeHost.runtime.installNativeBootstrap(productSessionBootstrap);
			},
			onProductSessionBootstrapFailure: (): void => {
				paneRuntimeHost.runtime.handleNativeBootstrapFailure();
			},
			onReady: (): void => {
				if (getFailedStart() !== null) return;
				recordBridgePageReadyState('ready');
				isBridgeReadyRef.current = true;
				isBridgeReadyGateOpenRef.current = true;
				queueMicrotask((): void => {
					if (!isBridgeReadyRef.current) {
						return;
					}
					for (const callback of bridgeReadyCallbacksRef.current) {
						callback();
					}
				});
			},
			onReadyError: reportReadyError,
			onTelemetryConfig: configureTelemetryRecorder,
			onTelemetrySessionBootstrap: (result): void => {
				const currentConfig = handshakeSessionRef.current?.getTelemetryConfig() ?? null;
				if (currentConfig === null) {
					return;
				}
				if (result.kind === 'available') {
					configureTelemetryRecorder({
						...currentConfig,
						workerBootstrap: result.workerBootstrap,
					});
					return;
				}
				const { workerBootstrap: _discardedWorkerBootstrap, ...configWithoutAuthority } =
					currentConfig;
				configureTelemetryRecorder(configWithoutAuthority);
			},
		});
		configureTelemetryRecorder();
		return (): void => {
			delete telemetryControlGlobal.__bridgeTelemetrySidecarControl;
			isEffectInstalled = false;
			telemetryConfigurationSequence += 1;
			handshakeSessionRef.current?.uninstall();
			handshakeSessionRef.current = null;
			isBridgeReadyRef.current = false;
			isBridgeReadyGateOpenRef.current = false;
			recordBridgePageReadyState('awaiting');
			telemetryRecorderRef.current = createBridgeTelemetryRecorder(null);
			const telemetryWorkerSession = telemetryWorkerSessionRef.current;
			telemetryWorkerSessionRef.current = null;
			if (telemetryWorkerSession !== null) {
				void drainTelemetrySession(telemetryWorkerSession);
			}
		};
	}, [paneRuntimeHost, target, getFailedStart, reportReadyError]);
	const publishActiveViewerModeWorkerMessages = useCallback(
		(messages: readonly BridgeWorkerServerToMainMessage[]): void => {
			for (const message of messages) {
				if (message.kind === 'nativeSurfaceSelectionRequest') {
					applyNativeSurfaceSelectionRequest(message);
				}
			}
			resolveBridgeWorkerActiveViewerModeRequestResolvers({
				messages,
				resolversByRequestId: activeViewerModeRequestResolversRef.current,
				settledResultsByRequestId: activeViewerModeSettledResultsRef.current,
			});
		},
		[applyNativeSurfaceSelectionRequest],
	);
	useEffect((): (() => void) => {
		const requestResolvers = activeViewerModeRequestResolversRef.current;
		const settledResults = activeViewerModeSettledResultsRef.current;
		const unsubscribePaneMessages = paneRuntimeHost.runtime.paneClient.subscribeMessages(
			(message): void => {
				publishActiveViewerModeWorkerMessages([message]);
			},
		);
		return (): void => {
			unsubscribePaneMessages();
			resolvePendingBridgeWorkerActiveViewerModeRequests({
				didSend: false,
				resolversByRequestId: requestResolvers,
			});
			settledResults.clear();
			disposeBridgeMarkdownRuntimeHost(markdownRuntimeHost);
		};
	}, [markdownRuntimeHost, paneRuntimeHost, publishActiveViewerModeWorkerMessages]);
	const sendActiveViewerModeWorkerUpdate = useCallback(
		(update: BridgeActiveViewerModeUpdate): Promise<boolean> => {
			let requestId: string;
			if (update.mode === 'file') recordBridgeFileModeSendAttempt();
			try {
				requestId = paneRuntimeHost.runtime.paneClient.send(
					encodeBridgeWorkerActiveViewerModeUpdateCommand({
						requestId: 'pane-runtime-owned',
						epoch: ++activeViewerModeWorkerEpochRef.current,
						update,
					}),
				);
			} catch {
				if (update.mode === 'file') recordBridgeFileModeSendSynchronousFailure();
				return Promise.resolve(false);
			}
			return new Promise<boolean>((resolve): void => {
				const settledResult = activeViewerModeSettledResultsRef.current.get(requestId);
				if (settledResult !== undefined) {
					activeViewerModeSettledResultsRef.current.delete(requestId);
					resolve(settledResult);
					return;
				}
				activeViewerModeRequestResolversRef.current.set(requestId, resolve);
			});
		},
		[paneRuntimeHost],
	);
	activeViewerModeRef.current = activeViewerMode;
	activeViewerSourcesRef.current = activeViewerSources;
	useLayoutEffect((): void => {
		const pendingSelection = pendingNativeSurfaceSelectionRef.current;
		if (
			pendingSelection === null ||
			!bridgeAppNavigationCommandIsAdmitted(
				navigationAdmissionState,
				pendingSelection.request.navigationCommand,
			)
		) {
			return;
		}
		setNativeSurfaceSelectionSignalRevision(pendingSelection.arrivalRevision);
	}, [navigationAdmissionState]);
	const sendActiveViewerModeUpdate = useCallback((): void => {
		const currentActiveViewerMode = activeViewerModeRef.current;
		const activeSource = activeViewerSourcesRef.current[currentActiveViewerMode];
		const pendingNativeSurfaceSelection = pendingNativeSurfaceSelectionRef.current;
		const currentNavigationAdmissionState = navigationAdmissionStateRef.current;
		const pendingNativeSurfaceSelectionIsAdmitted =
			pendingNativeSurfaceSelection !== null &&
			bridgeAppNavigationCommandIsAdmitted(
				currentNavigationAdmissionState,
				pendingNativeSurfaceSelection.request.navigationCommand,
			);
		if (
			pendingNativeSurfaceSelectionIsAdmitted &&
			pendingNativeSurfaceSelection !== null &&
			pendingNativeSurfaceSelection.request.navigationCommand.surface === currentActiveViewerMode
		) {
			const nativeSignalKey = `native:${pendingNativeSurfaceSelection.arrivalRevision}:${pendingNativeSurfaceSelection.request.navigationCommand.commandId}:${activeSource?.streamId ?? 'pending-source'}:${activeSource?.generation ?? -1}`;
			if (lastSentActiveViewerModeSignalKeyRef.current === nativeSignalKey) {
				return;
			}
			lastSentActiveViewerModeSignalKeyRef.current = nativeSignalKey;
			activeViewerModeSequenceRef.current += 1;
			void sendActiveViewerModeWorkerUpdate({
				activeSource,
				mode: currentActiveViewerMode,
				nativeSelectionRequestId: pendingNativeSurfaceSelection.request.navigationCommand.commandId,
				sequence: activeViewerModeSequenceRef.current,
				sessionId: activeViewerModeSessionIdRef.current,
			}).then((didSend): void => {
				if (didSend) {
					activeViewerModeRetryAttemptsBySignalKeyRef.current.delete(nativeSignalKey);
					if (
						pendingNativeSurfaceSelectionRef.current?.arrivalRevision ===
						pendingNativeSurfaceSelection.arrivalRevision
					) {
						pendingNativeSurfaceSelectionRef.current = null;
					}
					return;
				}
				if (lastSentActiveViewerModeSignalKeyRef.current !== nativeSignalKey) {
					return;
				}
				lastSentActiveViewerModeSignalKeyRef.current = null;
				if (
					activeViewerModeRetryAttemptAvailable({
						retryAttemptsBySignalKey: activeViewerModeRetryAttemptsBySignalKeyRef.current,
						signalKey: nativeSignalKey,
					})
				) {
					setActiveViewerModeRetryRevision(
						(currentRetryRevision): number => currentRetryRevision + 1,
					);
				}
			});
			return;
		}
		if (
			pendingNativeSurfaceSelection !== null &&
			pendingNativeSurfaceSelection.request.navigationCommand.surface === currentActiveViewerMode &&
			currentNavigationAdmissionState.pendingCommand?.commandId !==
				pendingNativeSurfaceSelection.request.navigationCommand.commandId
		) {
			pendingNativeSurfaceSelectionRef.current = null;
		}
		const activationRevision = activeViewerModeActivationRevisionRef.current;
		if (activeSource === null) {
			if (
				activationRevision === 0 ||
				activeViewerModeSourceSentActivationRevisionsRef.current.has(activationRevision)
			) {
				return;
			}
			const pendingSignalKey = `${activationRevision}:${currentActiveViewerMode}:pending-source`;
			if (lastSentActiveViewerModeSignalKeyRef.current === pendingSignalKey) {
				return;
			}
			lastSentActiveViewerModeSignalKeyRef.current = pendingSignalKey;
			activeViewerModeSequenceRef.current += 1;
			void sendActiveViewerModeWorkerUpdate({
				sessionId: activeViewerModeSessionIdRef.current,
				sequence: activeViewerModeSequenceRef.current,
				mode: currentActiveViewerMode,
				activeSource: null,
				nativeSelectionRequestId: null,
			}).then((didSend): void => {
				if (!didSend && lastSentActiveViewerModeSignalKeyRef.current === pendingSignalKey) {
					lastSentActiveViewerModeSignalKeyRef.current = null;
					if (
						activeViewerModeRetryAttemptAvailable({
							retryAttemptsBySignalKey: activeViewerModeRetryAttemptsBySignalKeyRef.current,
							signalKey: pendingSignalKey,
						})
					) {
						setActiveViewerModeRetryRevision(
							(currentRetryRevision): number => currentRetryRevision + 1,
						);
					}
				}
			});
			return;
		}
		const signalKey = `${activationRevision}:${currentActiveViewerMode}:${activeSource.protocol}:${activeSource.streamId}:${activeSource.generation}`;
		if (lastSentActiveViewerModeSignalKeyRef.current === signalKey) {
			return;
		}
		lastSentActiveViewerModeSignalKeyRef.current = signalKey;
		activeViewerModeSourceSentActivationRevisionsRef.current.add(activationRevision);
		activeViewerModeSequenceRef.current += 1;
		void sendActiveViewerModeWorkerUpdate({
			sessionId: activeViewerModeSessionIdRef.current,
			sequence: activeViewerModeSequenceRef.current,
			mode: currentActiveViewerMode,
			activeSource,
			nativeSelectionRequestId: null,
		}).then((didSend): void => {
			if (didSend) {
				activeViewerModeRetryAttemptsBySignalKeyRef.current.delete(signalKey);
				return;
			}
			if (lastSentActiveViewerModeSignalKeyRef.current !== signalKey) {
				return;
			}
			lastSentActiveViewerModeSignalKeyRef.current = null;
			activeViewerModeSourceSentActivationRevisionsRef.current.delete(activationRevision);
			if (
				activeViewerModeRetryAttemptAvailable({
					retryAttemptsBySignalKey: activeViewerModeRetryAttemptsBySignalKeyRef.current,
					signalKey,
				})
			) {
				setActiveViewerModeRetryRevision(
					(currentRetryRevision): number => currentRetryRevision + 1,
				);
			}
		});
	}, [sendActiveViewerModeWorkerUpdate]);
	useLayoutEffect((): void => {
		if (previousActiveViewerModeRef.current === activeViewerMode) {
			return;
		}
		activeViewerModeActivationRevisionRef.current += 1;
		previousActiveViewerModeRef.current = activeViewerMode;
	}, [activeViewerMode]);
	const reportFileActiveSource = useCallback(
		(activeSource: BridgeActiveViewerSource | null): void => {
			setActiveViewerSources((currentSources): BridgeActiveViewerSources => {
				if (bridgeActiveViewerSourcesEqual(currentSources.file, activeSource)) {
					return currentSources;
				}
				return { ...currentSources, file: activeSource };
			});
			if (activeSource !== null) {
				setActiveViewerSourceSignalRevision((revision) => revision + 1);
			}
		},
		[],
	);
	const reportReviewActiveSource = useCallback(
		(activeSource: BridgeActiveViewerSource | null): void => {
			setActiveViewerSources((currentSources): BridgeActiveViewerSources => {
				if (bridgeActiveViewerSourcesEqual(currentSources.review, activeSource)) {
					return currentSources;
				}
				return { ...currentSources, review: activeSource };
			});
			if (activeSource !== null) {
				setActiveViewerSourceSignalRevision((revision) => revision + 1);
			}
		},
		[],
	);
	const reportAcceptedNavigationSource = useCallback(
		(surface: BridgeViewerMode, source: BridgeAppNavigationSource | null): void => {
			const currentState = navigationAdmissionStateRef.current;
			const nextState =
				source === null
					? clearBridgeAppAcceptedNavigationSource(currentState, surface)
					: reportBridgeAppAcceptedNavigationSource(currentState, source);
			if (nextState === currentState) return;
			navigationAdmissionStateRef.current = nextState;
			setNavigationAdmissionState(nextState);
		},
		[],
	);
	const reportFileNavigationSource = useCallback(
		(source: Extract<BridgeAppNavigationSource, { readonly sourceKind: 'file' }> | null): void => {
			reportAcceptedNavigationSource('file', source);
		},
		[reportAcceptedNavigationSource],
	);
	const reportReviewNavigationSource = useCallback(
		(
			source: Extract<BridgeAppNavigationSource, { readonly sourceKind: 'review' }> | null,
		): void => {
			reportAcceptedNavigationSource('review', source);
		},
		[reportAcceptedNavigationSource],
	);
	const isNavigationCommandStillEligible = useCallback(
		(command: BridgeAppNavigationTargetCommand): boolean =>
			bridgeAppRememberedNavigationTargetIsEligible(navigationAdmissionStateRef.current, command),
		[],
	);
	useLayoutEffect((): (() => void) => {
		if (isBridgeReadyGateOpenRef.current) {
			sendActiveViewerModeUpdate();
			return (): void => {};
		}
		return registerBridgeReadyCallback(sendActiveViewerModeUpdate);
	}, [
		activeViewerSources,
		activeViewerSourceSignalRevision,
		activeViewerMode,
		activeViewerModeRetryRevision,
		nativeSurfaceSelectionSignalRevision,
		registerBridgeReadyCallback,
		sendActiveViewerModeUpdate,
	]);
	useEffect((): void => {
		if (incomingViewerMode === undefined) return;
		activateViewerMode(incomingViewerMode, 'native_request');
	}, [activateViewerMode, incomingViewerMode]);
	useEffect((): void => {
		bridgeViewerActivationPrewarm({
			activeViewerMode,
			state: activationPrewarmStateRef.current,
			...(props.codeViewWorkerFactory === undefined
				? {}
				: { workerFactory: props.codeViewWorkerFactory }),
		});
	}, [activeViewerMode, props.codeViewWorkerFactory]);
	const rememberedFileNavigationCommand = navigationAdmissionState.targetCommands.file;
	const rememberedReviewNavigationCommand = navigationAdmissionState.targetCommands.review;
	const requiresFileNavigationSourceDiscovery =
		navigationAdmissionState.pendingCommand?.surface === 'file';

	return (
		<BridgeViewerAppShell
			appOwner="BridgeApp"
			mode={activeViewerMode}
			paneFailedStart={paneFailedStart}
			retainsContent={
				paneRuntimeHost.fileViewClient.renderStore.getSnapshot().fileDisplayFreshness !== null ||
				paneRuntimeHost.reviewClient.renderStore.getSnapshot().reviewSourceSlice !== null
			}
			{...(props.paneReloadPort === undefined ? {} : { paneReloadPort: props.paneReloadPort })}
		>
			<WorktreeAnnotationNavigationProvider controller={annotationNavigation}>
				{mountedViewerModes.has('file') ? (
					<div
						aria-hidden={activeViewerMode !== 'file'}
						className={
							activeViewerMode === 'file'
								? 'absolute inset-0 h-full min-h-0'
								: 'invisible pointer-events-none absolute inset-0 h-full min-h-0'
						}
						data-bridge-viewer-mode-active={activeViewerMode === 'file' ? 'true' : 'false'}
						data-bridge-viewer-mode-host="file"
						data-testid="bridge-viewer-mode-host-file"
						inert={activeViewerMode !== 'file' || undefined}
					>
						<BridgeFileViewerMode
							{...props}
							paneFailedStart={paneFailedStart}
							fileViewerProps={{
								...props.fileViewerProps,
								...(viewerActivation?.viewer === 'file'
									? {
											activationCause: viewerActivation.cause,
											activationSequence: viewerActivation.sequence,
											activationStartedAtPerfNow: viewerActivation.startedAtPerfNow,
										}
									: {}),
								...(openFileFromReviewCommand === null
									? {}
									: { openPathCommand: openFileFromReviewCommand }),
							}}
							fileViewClient={paneRuntimeHost.fileViewClient}
							isNavigationCommandStillEligible={isNavigationCommandStillEligible}
							isActive={activeViewerMode === 'file'}
							markdownWorkerClient={markdownRuntimeHost.runtime.workerClient}
							mermaidRenderer={markdownRuntimeHost.runtime.mermaidRenderer}
							controlTarget={target}
							onActiveSourceChange={reportFileActiveSource}
							onNavigationSourceChange={reportFileNavigationSource}
							requiresNavigationSourceDiscovery={requiresFileNavigationSourceDiscovery}
							telemetryRecorder={telemetryRecorder}
							viewerContextSwitcher={
								<BridgeViewerContextSwitcher
									mode={activeViewerMode}
									onModeChange={activateViewerModeFromContextSwitcher}
								/>
							}
							{...(rememberedFileNavigationCommand === undefined
								? {}
								: { navigationCommand: rememberedFileNavigationCommand })}
						/>
					</div>
				) : null}
				{mountedViewerModes.has('review') ? (
					<div
						aria-hidden={activeViewerMode !== 'review'}
						className={
							activeViewerMode === 'review'
								? 'absolute inset-0 h-full min-h-0'
								: 'invisible pointer-events-none absolute inset-0 h-full min-h-0'
						}
						data-bridge-viewer-mode-active={activeViewerMode === 'review' ? 'true' : 'false'}
						data-bridge-viewer-mode-host="review"
						data-testid="bridge-viewer-mode-host-review"
						inert={activeViewerMode !== 'review' || undefined}
					>
						<BridgeReviewViewerMode
							{...props}
							paneFailedStart={paneFailedStart}
							{...(viewerActivation?.viewer === 'review'
								? {
										activationCause: viewerActivation.cause,
										activationSequence: viewerActivation.sequence,
										activationStartedAtPerfNow: viewerActivation.startedAtPerfNow,
									}
								: {})}
							isActive={activeViewerMode === 'review'}
							isNavigationCommandStillEligible={isNavigationCommandStillEligible}
							target={target}
							onActiveSourceChange={reportReviewActiveSource}
							onNavigationSourceChange={reportReviewNavigationSource}
							onOpenFile={openReviewFileInFileViewer}
							reviewClient={paneRuntimeHost.reviewClient}
							telemetryRecorderRef={telemetryRecorderRef}
							viewerContextSwitcher={
								<BridgeViewerContextSwitcher
									mode={activeViewerMode}
									onModeChange={activateViewerModeFromContextSwitcher}
								/>
							}
							{...(rememberedReviewNavigationCommand === undefined
								? {}
								: { navigationCommand: rememberedReviewNavigationCommand })}
						/>
					</div>
				) : null}
			</WorktreeAnnotationNavigationProvider>
		</BridgeViewerAppShell>
	);
}

function createBridgePaneRuntimeHost(runtime: BridgePaneRuntime): BridgePaneRuntimeHost {
	return {
		fileViewClient: runtime.surfaceClient('fileView'),
		reviewClient: runtime.surfaceClient('review'),
		runtime,
	};
}

function bridgeAppNavigationCommandIsAdmitted(
	state: BridgeAppNavigationAdmissionState,
	command: BridgeProductNavigationCommand,
): boolean {
	if (
		state.latestBindingRevision !== command.bindingRevision ||
		state.latestCommandId !== command.commandId ||
		state.activeSurface !== command.surface
	) {
		return false;
	}
	if (command.commandKind === 'activateContext') return true;
	const admittedTarget = state.targetCommands[command.surface];
	return (
		admittedTarget?.commandId === command.commandId &&
		admittedTarget.bindingRevision === command.bindingRevision
	);
}
