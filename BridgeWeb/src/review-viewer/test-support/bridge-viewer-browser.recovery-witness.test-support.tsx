import { act, type ReactElement } from 'react';
import { render } from 'vitest-browser-react';

import { BridgeTestFactRecorder } from '../../../tests/test-support/bridge-test-fact-recorder.ts';
import { BridgeReviewViewerMode } from '../../app/bridge-app-review-viewer-mode.js';
import {
	buildBridgeWorkerReviewCandidateReadyEvent,
	buildBridgeWorkerReviewCandidateStartedEvent,
	buildBridgeWorkerReviewPublicationInstallAdmissionEvent,
} from '../../core/comm-worker/bridge-comm-worker-protocol.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { createBridgeMainRenderSnapshotStore } from '../../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../../core/comm-worker/bridge-pane-runtime.js';
import { createBridgeProductDeferred } from '../../core/comm-worker/bridge-product-async-queue.js';
import type { BridgeProductNavigationCommand } from '../../core/comm-worker/bridge-product-session-contracts.js';
import type {
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerReviewPublicationIdentity,
	BridgeWorkerServerToMainMessage,
} from '../../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeWorkerRenderSourceCorrelation } from '../../core/comm-worker/bridge-worker-pierre-render-job.js';
import {
	bridgeWorkerReviewPublicationIdentity,
	bridgeWorkerReviewSourceContext,
} from '../../core/comm-worker/bridge-worker-review-display.test-support.js';
import type { BridgeWorkerRpcCommandInput } from '../../core/comm-worker/bridge-worker-rpc-client.js';
import { createBridgeWorkerRpcLifecycleStore } from '../../core/comm-worker/bridge-worker-rpc-lifecycle-store.js';
import { bridgeContentDemandExecutionPolicy } from '../../core/demand/bridge-content-demand-policy.js';
import type {
	BridgeFileChangeKind,
	BridgeFileClass,
} from '../../foundation/review-package/bridge-review-package.js';
import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryRecorder } from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import { BridgeReviewProjectionWitnessRouter } from './bridge-review-projection-witness-router.js';
import { reviewWitnessTreeRows } from './bridge-viewer-browser-recovery-tree-fixture.js';
import { visibleTextIncludingOpenShadowRoots } from './bridge-viewer-browser-visible-text.js';
import {
	completeReviewContentMessages,
	completeReviewFileContentMessages,
} from './bridge-viewer-browser.recovery-witness-content.test-support.js';
import {
	advanceBridgeReviewRecoveryWitnessFrames,
	waitForHydratedReviewCodeViewItem,
} from './bridge-viewer-browser.recovery-witness-scroll.test-support.js';

const bridgeReviewNavigationCommandIsAlwaysEligible = (): boolean => true;

export {
	advanceBridgeReviewRecoveryWitnessFrames,
	scanBridgeReviewRecoveryWitnessDocument,
} from './bridge-viewer-browser.recovery-witness-scroll.test-support.js';
export type {
	BridgeReviewRecoveryMarkerConvergenceSample,
	BridgeReviewRecoveryScrollScan,
} from './bridge-viewer-browser.recovery-witness-scroll.test-support.js';
export interface BridgeReviewRecoveryWitnessFile {
	readonly changeKind?: BridgeFileChangeKind;
	readonly contentMarker: string;
	readonly fileClass?: BridgeFileClass;
	readonly itemId: string;
	readonly lineCount: number;
	readonly path: string;
	readonly sourceDescriptorIdsByRole?: {
		readonly base: string;
		readonly head: string;
	};
	readonly sourceCorrelation?: BridgeWorkerRenderSourceCorrelation;
}

export interface BridgeReviewRecoveryWitnessHarness {
	readonly codeScrollOwner: () => HTMLElement | null;
	readonly codeText: () => string;
	readonly files: readonly BridgeReviewRecoveryWitnessFile[];
	readonly paintedCodeViewItems: () => readonly BridgeReviewRecoveryPaintedItem[];
	readonly paintedSourceCorrelationElements: () => readonly Element[];
	readonly paintedSourceCorrelationText: (element: Element) => string;
	readonly pierreSearchInput: () => HTMLInputElement | null;
	readonly pierreTreeHost: () => HTMLElement | null;
	readonly pierreTreePath: (path: string) => HTMLElement | null;
	readonly scrollTreePathIntoView: (path: string) => Promise<HTMLElement>;
	readonly publishCompleteContent: () => Promise<void>;
	readonly publishContentForItemIds: (itemIds: readonly string[]) => Promise<readonly string[]>;
	readonly publishDemandedContent: () => Promise<readonly string[]>;
	readonly publishDisplay: () => Promise<void>;
	readonly publishDisplayAppendFrom: (initialItemCount: number) => Promise<void>;
	readonly publishDisplayAtEpoch: (epoch: number) => Promise<void>;
	readonly publishExactActiveDisplayAtWorkerEpoch: (epoch: number) => Promise<void>;
	readonly publishDisplayAtPackageIdentity: (metadataWindowIdentity: string) => Promise<void>;
	readonly publishDisplayInTwoBatches: (initialItemCount: number) => Promise<void>;
	readonly publishFileContentForItemId: (itemId: string) => Promise<void>;
	readonly publishDisplayPrefix: (initialItemCount: number) => Promise<void>;
	readonly publishAuthoritativeDisplayAfterRetainedSelection: () => Promise<void>;
	readonly publishAuthoritativeDisplayWithImmediateLocalSelection: (
		selectedItemIndex: number,
	) => Promise<void>;
	readonly publishRetainedSelectedOnlyDisplay: (selectedItemIndex: number) => Promise<void>;
	readonly publishedContentItemIds: () => readonly string[];
	readonly renderedCodeViewItemIds: () => readonly string[];
	readonly renderResult: Awaited<ReturnType<typeof render>>;
	readonly markFileViewedCommandCount: () => number;
	readonly selectedItemCommandCount: () => number;
	readonly selectionScrollToPathSampleCount: () => number;
	readonly setActive: (isActive: boolean) => Promise<void>;
	readonly expandedTreePaths: () => readonly string[];
	readonly visibleCodeText: (scrollOwner: HTMLElement) => string;
	readonly viewportCommandVisibleItemIds: () => readonly (readonly string[])[];
	readonly workerEventSeam: BridgeReviewRecoveryWitnessWorkerEventSeam;
}

export interface BridgeReviewRecoveryWitnessWorkerEventSeam {
	readonly activeReviewPublicationIdentity: () => BridgeWorkerReviewPublicationIdentity;
	readonly publish: (message: BridgeWorkerServerToMainMessage) => void;
	readonly sentRequests: () => readonly BridgeReviewRecoveryWitnessWorkerRequest[];
	readonly waitForSentRequest: (
		matches: (request: BridgeReviewRecoveryWitnessWorkerRequest) => boolean,
		label: string,
	) => Promise<BridgeReviewRecoveryWitnessWorkerRequest>;
}

export interface BridgeReviewRecoveryWitnessWorkerRequest {
	readonly command: BridgeWorkerRpcCommandInput;
	readonly requestId: string;
}

export interface BridgeReviewRecoveryPaintedItem {
	readonly bottom: number;
	readonly itemId: string;
	readonly paintedLineCount: number;
	readonly text: string;
	readonly top: number;
}

interface ActiveReviewRecoveryWitnessHarness {
	readonly dispose: () => void;
}

const activeHarnesses = new Set<ActiveReviewRecoveryWitnessHarness>();

export function makeBridgeReviewRecoveryWitnessFiles(props: {
	readonly count: number;
	readonly lineCount: number;
	readonly markerPrefix: string;
}): readonly BridgeReviewRecoveryWitnessFile[] {
	return Array.from({ length: props.count }, (_, fileIndex): BridgeReviewRecoveryWitnessFile => {
		const ordinal = String(fileIndex + 1).padStart(3, '0');
		const groupOrdinal = String(Math.floor(fileIndex / 3) + 1).padStart(2, '0');
		return {
			contentMarker: `${props.markerPrefix}_CONTENT_${ordinal}`,
			itemId: `${props.markerPrefix.toLowerCase()}-item-${ordinal}`,
			lineCount: props.lineCount,
			path: `Sources/RecoveryGroup${groupOrdinal}/RecoveryFile${ordinal}.swift`,
		};
	});
}

export async function renderBridgeReviewRecoveryWitness(
	files: readonly BridgeReviewRecoveryWitnessFile[],
	props: {
		readonly navigationCommand?: Extract<
			BridgeProductNavigationCommand,
			{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
		>;
	} = {},
): Promise<BridgeReviewRecoveryWitnessHarness> {
	if (files.length === 0) throw new Error('Review recovery witness requires at least one file.');
	const renderStore = createBridgeMainRenderSnapshotStore();
	const lifecycleStore = createBridgeWorkerRpcLifecycleStore();
	const sentCommands: BridgeWorkerRpcCommandInput[] = [];
	const sentRequests: BridgeReviewRecoveryWitnessWorkerRequest[] = [];
	const requestFacts = new BridgeTestFactRecorder<BridgeReviewRecoveryWitnessWorkerRequest>();
	const messageSubscriptionReady = createBridgeProductDeferred<void>();
	const telemetrySamples: BridgeTelemetrySample[] = [];
	const telemetryRecorder: BridgeTelemetryRecorder = {
		flush: (): boolean => true,
		isEnabled: (scope): boolean => scope === 'web',
		measure: (measureProps) => measureProps.operation(),
		record: (sample): void => {
			telemetrySamples.push(sample);
		},
	};
	const publishedContentItemIds = new Set<string>();
	const messageListeners = new Set<(message: BridgeWorkerServerToMainMessage) => void>();
	const publishWorkerMessage = (message: BridgeWorkerServerToMainMessage): void => {
		for (const listener of messageListeners) listener(message);
	};
	let activeReviewPublicationIdentity: BridgeWorkerReviewPublicationIdentity | null = null;
	const reviewProjectionRouter = new BridgeReviewProjectionWitnessRouter();
	let isDisposed = false;
	const publishRawReviewDisplayEvent = (
		event: BridgeWorkerReviewDisplayPatchEvent,
		candidateReady = true,
	): void => {
		const identity = event.reviewPublicationIdentity;
		if (identity !== null && messageListeners.size > 0) {
			const candidateSequence = event.sequence * 3;
			publishWorkerMessage(
				buildBridgeWorkerReviewCandidateStartedEvent({
					disposition: { kind: 'replacement' },
					epoch: event.epoch,
					packageId: identity.packageId,
					publicationId: identity.publicationId,
					reviewGeneration: identity.reviewGeneration,
					revision: identity.revision,
					sequence: candidateSequence,
					sourceIdentity: identity.sourceIdentity,
				}),
			);
			reviewProjectionRouter.publishRaw({ ...event, sequence: candidateSequence + 1 });
		} else {
			reviewProjectionRouter.publishRaw(event);
		}
		if (event.reviewPublicationIdentity !== null) {
			activeReviewPublicationIdentity = event.reviewPublicationIdentity;
		}
		if (!candidateReady || event.reviewPublicationIdentity === null || messageListeners.size === 0)
			return;
		const readyIdentity = event.reviewPublicationIdentity;
		const candidateSequence = event.sequence * 3;
		publishWorkerMessage(
			buildBridgeWorkerReviewCandidateReadyEvent({
				epoch: event.epoch,
				packageId: readyIdentity.packageId,
				publicationId: readyIdentity.publicationId,
				reviewGeneration: readyIdentity.reviewGeneration,
				revision: readyIdentity.revision,
				sequence: candidateSequence + 2,
				sourceIdentity: readyIdentity.sourceIdentity,
			}),
		);
	};
	const renderFulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
		nowMilliseconds: (): number => 0,
		sendDisposition: (_receipt): void => {},
	});
	const reviewClient: BridgePaneSurfaceClient = {
		requestWorkerReplacement: (): void => {},
		lifecycle: lifecycleStore,
		renderFulfillmentCoordinator,
		renderStore,
		send: (command): string => {
			sentCommands.push(command);
			if (command.command === 'reviewProjectionUpdate')
				reviewProjectionRouter.publishQuery(command);
			const requestId = `review-recovery-witness-request-${sentCommands.length}`;
			sentRequests.push({ command, requestId });
			requestFacts.record({ command, requestId });
			lifecycleStore.startRequest({ command: command.command, requestId, surface: 'review' });
			if (command.command === 'reviewPublicationInstallAdmit') {
				queueMicrotask((): void => {
					publishWorkerMessage(
						buildBridgeWorkerReviewPublicationInstallAdmissionEvent({
							candidatePublicationId: command.candidatePublicationId,
							requestId,
							status: 'admitted',
						}),
					);
				});
			} else if (command.command === 'reviewPublicationInstalled') {
				queueMicrotask((): void => {
					lifecycleStore.ackRequest({ acknowledgedAtSequence: sentCommands.length, requestId });
				});
			}
			return requestId;
		},
		subscribeMessages: (listener): (() => void) => {
			messageListeners.add(listener);
			messageSubscriptionReady.resolve();
			reviewProjectionRouter.setListener(publishWorkerMessage);
			return (): void => {
				messageListeners.delete(listener);
				if (messageListeners.size === 0) {
					reviewProjectionRouter.clearListener(publishWorkerMessage);
				}
			};
		},
		surface: 'review',
	};
	const telemetryRecorderRef = { current: telemetryRecorder };
	const renderWitnessRoot = (isActive: boolean): ReactElement => (
		<div data-testid="bridge-review-recovery-witness-root" style={{ height: 860, width: 1_440 }}>
			<BridgeReviewViewerMode
				codeViewWorkerPoolEnabled={false}
				isActive={isActive}
				isNavigationCommandStillEligible={bridgeReviewNavigationCommandIsAlwaysEligible}
				{...(props.navigationCommand === undefined
					? {}
					: { navigationCommand: props.navigationCommand })}
				onActiveSourceChange={(): void => {}}
				onNavigationSourceChange={(): void => {}}
				reviewClient={reviewClient}
				telemetryRecorderRef={telemetryRecorderRef}
				viewerContextSwitcher={<div />}
			/>
		</div>
	);
	const renderResult = await render(renderWitnessRoot(true));
	await act(async (): Promise<void> => {
		await messageSubscriptionReady.promise;
	});
	const requireMessageListener = (): ((message: BridgeWorkerServerToMainMessage) => void) => {
		if (messageListeners.size === 0) {
			throw new Error(
				'Review recovery witness production surface did not subscribe to worker messages.',
			);
		}
		return publishWorkerMessage;
	};
	const activeHarness: ActiveReviewRecoveryWitnessHarness = {
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			requestFacts.close(new Error('Review recovery witness disposed'));
			messageListeners.clear();
			reviewProjectionRouter.clearListener(publishWorkerMessage);
			renderFulfillmentCoordinator.dispose();
			renderStore.dispose();
			lifecycleStore.dispose();
			activeHarnesses.delete(activeHarness);
		},
	};
	activeHarnesses.add(activeHarness);
	return {
		codeScrollOwner: (): HTMLElement | null =>
			bridgeReviewRecoveryWitnessCodeScrollOwner(renderResult.container),
		codeText: (): string => bridgeReviewRecoveryWitnessCodeText(renderResult.container),
		files,
		paintedCodeViewItems: (): readonly BridgeReviewRecoveryPaintedItem[] =>
			bridgeReviewRecoveryWitnessPaintedItems(renderResult.container),
		paintedSourceCorrelationElements: (): readonly Element[] =>
			queryBridgeReviewRecoveryWitnessOpenShadowRoots(
				renderResult.container,
				'[data-bridge-painted-source-correlations]',
			),
		paintedSourceCorrelationText: (element): string => textIncludingOpenShadowRoots(element),
		pierreSearchInput: (): HTMLInputElement | null =>
			bridgeReviewRecoveryWitnessPierreSearchInput(renderResult.container),
		pierreTreeHost: (): HTMLElement | null =>
			bridgeReviewRecoveryWitnessPierreTreeHost(renderResult.container),
		pierreTreePath: (path: string): HTMLElement | null =>
			bridgeReviewRecoveryWitnessPierreTreePath(renderResult.container, path),
		scrollTreePathIntoView: async (path: string): Promise<HTMLElement> =>
			bridgeReviewRecoveryWitnessScrollTreePathIntoView(renderResult.container, path),
		publishCompleteContent: async (): Promise<void> => {
			await act(async (): Promise<void> => {
				const publish = requireMessageListener();
				for (const [fileIndex, file] of files.entries()) {
					for (const message of completeReviewContentMessages(
						file,
						fileIndex + 1,
						requireActiveReviewPublicationIdentity(activeReviewPublicationIdentity),
					)) {
						publish(message);
					}
					publishedContentItemIds.add(file.itemId);
				}
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(
				Math.ceil(files.length / bridgeContentDemandExecutionPolicy.applyPumpMaxUnitsPerFrame) + 4,
			);
		},
		publishContentForItemIds: async (itemIds: readonly string[]): Promise<readonly string[]> => {
			const requestedItemIds = new Set(itemIds);
			const requestedFiles = files.filter(
				(file): boolean =>
					requestedItemIds.has(file.itemId) && !publishedContentItemIds.has(file.itemId),
			);
			if (requestedFiles.length === 0) return [];
			await act(async (): Promise<void> => {
				const publish = requireMessageListener();
				for (const file of requestedFiles) {
					const fileIndex = files.indexOf(file);
					for (const message of completeReviewContentMessages(
						file,
						fileIndex + 1,
						requireActiveReviewPublicationIdentity(activeReviewPublicationIdentity),
					)) {
						publish(message);
					}
					publishedContentItemIds.add(file.itemId);
				}
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(
				Math.ceil(
					requestedFiles.length / bridgeContentDemandExecutionPolicy.applyPumpMaxUnitsPerFrame,
				) + 4,
			);
			return requestedFiles.map((file): string => file.itemId);
		},
		publishDemandedContent: async (): Promise<readonly string[]> => {
			const demandedItemIds = new Set<string>();
			for (const command of sentCommands) {
				if (command.command === 'select' && command.selectedItemId !== null)
					demandedItemIds.add(command.selectedItemId);
				if (command.command === 'viewport') {
					for (const itemId of command.visibleItemIds) demandedItemIds.add(itemId);
				}
			}
			const demandedFiles = files.filter(
				(file): boolean =>
					demandedItemIds.has(file.itemId) && !publishedContentItemIds.has(file.itemId),
			);
			if (demandedFiles.length === 0) return [];
			const appliedContent = demandedFiles.map(
				(file): Promise<void> =>
					waitForHydratedReviewCodeViewItem({ itemId: file.itemId, renderStore }),
			);
			await act(async (): Promise<void> => {
				const publish = requireMessageListener();
				for (const file of demandedFiles) {
					const fileIndex = files.indexOf(file);
					for (const message of completeReviewContentMessages(
						file,
						fileIndex + 1,
						requireActiveReviewPublicationIdentity(activeReviewPublicationIdentity),
					)) {
						publish(message);
					}
					publishedContentItemIds.add(file.itemId);
				}
				await Promise.resolve();
			});
			await act(async (): Promise<void> => {
				await Promise.all(appliedContent);
			});
			await advanceBridgeReviewRecoveryWitnessFrames(1);
			return demandedFiles.map((file): string => file.itemId);
		},
		publishDisplay: async (): Promise<void> => {
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(reviewDisplayEvent(files));
				await import('../shell/review-viewer-shell.js');
				await Promise.resolve();
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
				await Promise.resolve();
			});
		},
		publishDisplayAppendFrom: async (initialItemCount: number): Promise<void> => {
			if (initialItemCount <= 0 || initialItemCount >= files.length) {
				throw new Error('Review display append requires a non-empty proper initial prefix.');
			}
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(reviewDisplayAppendEvent(files, initialItemCount));
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishDisplayAtEpoch: async (epoch: number): Promise<void> => {
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(
					reviewDisplayEvent(files, {
						epoch,
						projectionRevision: epoch,
						sequence: epoch,
					}),
				);
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishExactActiveDisplayAtWorkerEpoch: async (epoch: number): Promise<void> => {
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(
					{
						...reviewDisplayEvent(files),
						epoch,
						projectionRevision: epoch,
						sequence: epoch,
					},
					false,
				);
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishDisplayAtPackageIdentity: async (metadataWindowIdentity: string): Promise<void> => {
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(
					reviewDisplayEvent(files, {
						metadataWindowIdentity,
						projectionRevision: 2,
						sequence: 2,
					}),
				);
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishDisplayInTwoBatches: async (initialItemCount: number): Promise<void> => {
			if (initialItemCount <= 0 || initialItemCount >= files.length) {
				throw new Error('Two-batch Review display requires a non-empty proper initial prefix.');
			}
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(reviewDisplayEvent(files.slice(0, initialItemCount)), false);
				await import('../shell/review-viewer-shell.js');
				await Promise.resolve();
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
				publishRawReviewDisplayEvent(reviewDisplayAppendEvent(files, initialItemCount));
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishFileContentForItemId: async (itemId: string): Promise<void> => {
			const file = files.find((candidate): boolean => candidate.itemId === itemId);
			if (file === undefined) {
				throw new Error(`Review file-content publication requires a fixture item: ${itemId}`);
			}
			await act(async (): Promise<void> => {
				const fileIndex = files.indexOf(file);
				const publish = requireMessageListener();
				for (const message of completeReviewFileContentMessages(
					file,
					fileIndex + 1,
					requireActiveReviewPublicationIdentity(activeReviewPublicationIdentity),
				)) {
					publish(message);
				}
				publishedContentItemIds.add(file.itemId);
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(5);
		},
		publishDisplayPrefix: async (initialItemCount: number): Promise<void> => {
			if (initialItemCount <= 0 || initialItemCount >= files.length) {
				throw new Error('Review display prefix requires a non-empty proper initial prefix.');
			}
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(reviewDisplayEvent(files.slice(0, initialItemCount)));
				await import('../shell/review-viewer-shell.js');
				await Promise.resolve();
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishAuthoritativeDisplayAfterRetainedSelection: async (): Promise<void> => {
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(
					reviewDisplayEvent(files, { projectionRevision: 2, sequence: 2 }),
				);
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishAuthoritativeDisplayWithImmediateLocalSelection: async (
			selectedItemIndex: number,
		): Promise<void> => {
			const selectedFile = files[selectedItemIndex];
			if (selectedFile === undefined) {
				throw new Error(
					`Immediate Review selection index is outside the fixture: ${selectedItemIndex}`,
				);
			}
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(
					reviewDisplayEvent(files, { projectionRevision: 2, sequence: 2 }),
				);
				renderStore.setLocalSelection({ selectedItemId: selectedFile.itemId, source: 'user' });
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(4);
		},
		publishRetainedSelectedOnlyDisplay: async (selectedItemIndex: number): Promise<void> => {
			const selectedFile = files[selectedItemIndex];
			if (selectedFile === undefined) {
				throw new Error(
					`Retained selected-only index is outside the fixture: ${selectedItemIndex}`,
				);
			}
			await act(async (): Promise<void> => {
				publishRawReviewDisplayEvent(reviewDisplayEvent([selectedFile]));
				await import('../shell/review-viewer-shell.js');
				await Promise.resolve();
				await new Promise<void>((resolve): void => {
					requestAnimationFrame((): void => resolve());
				});
				await Promise.resolve();
			});
		},
		publishedContentItemIds: (): readonly string[] => [...publishedContentItemIds],
		renderedCodeViewItemIds: (): readonly string[] =>
			queryBridgeReviewRecoveryWitnessOpenShadowRoots(
				renderResult.container,
				'[data-bridge-code-view-item-id]',
			)
				.map((element): string | null => element.getAttribute('data-bridge-code-view-item-id'))
				.filter((itemId): itemId is string => itemId !== null),
		renderResult,
		markFileViewedCommandCount: (): number =>
			sentCommands.filter((command) => command.command === 'markFileViewed').length,
		selectedItemCommandCount: (): number =>
			sentCommands.filter((command) => command.command === 'select').length,
		selectionScrollToPathSampleCount: (): number =>
			telemetrySamples.filter(
				(sample): boolean =>
					sample.name === 'performance.bridge.trees.scroll_to_path' &&
					sample.stringAttributes['agentstudio.bridge.scroll.reason'] === 'selected_path_effect',
			).length,
		setActive: async (isActive: boolean): Promise<void> => {
			await act(async (): Promise<void> => {
				await renderResult.rerender(renderWitnessRoot(isActive));
				await Promise.resolve();
			});
			await advanceBridgeReviewRecoveryWitnessFrames(2);
		},
		expandedTreePaths: (): readonly string[] =>
			bridgeReviewRecoveryWitnessExpandedTreePaths(renderResult.container),
		visibleCodeText: (scrollOwner: HTMLElement): string =>
			bridgeReviewRecoveryWitnessVisibleCodeText(renderResult.container, scrollOwner),
		viewportCommandVisibleItemIds: (): readonly (readonly string[])[] =>
			sentCommands.flatMap((command): readonly (readonly string[])[] =>
				command.command === 'viewport' ? [[...command.visibleItemIds]] : [],
			),
		workerEventSeam: {
			activeReviewPublicationIdentity: (): BridgeWorkerReviewPublicationIdentity =>
				requireActiveReviewPublicationIdentity(activeReviewPublicationIdentity),
			publish: (message): void => requireMessageListener()(message),
			sentRequests: (): readonly BridgeReviewRecoveryWitnessWorkerRequest[] => sentRequests,
			waitForSentRequest: (matches, label) => requestFacts.waitFor(matches, label),
		},
	};
}

export function disposeBridgeReviewRecoveryWitnessHarnesses(): void {
	for (const harness of activeHarnesses) harness.dispose();
}

function bridgeReviewRecoveryWitnessCodeText(container: HTMLElement): string {
	const codePanel = container.querySelector('[data-testid="bridge-code-view-panel"]');
	return codePanel === null ? '' : textIncludingOpenShadowRoots(codePanel);
}

function bridgeReviewRecoveryWitnessVisibleCodeText(
	container: HTMLElement,
	scrollOwner: HTMLElement,
): string {
	const codePanel = container.querySelector('[data-testid="bridge-code-view-panel"]');
	if (codePanel === null) return '';
	const viewportBounds = scrollOwner.getBoundingClientRect();
	return visibleTextIncludingOpenShadowRoots(codePanel, viewportBounds);
}

function bridgeReviewRecoveryWitnessPaintedItems(
	container: HTMLElement,
): readonly BridgeReviewRecoveryPaintedItem[] {
	const codePanel = container.querySelector('[data-testid="bridge-code-view-panel"]');
	if (codePanel === null) return [];
	return queryBridgeReviewRecoveryWitnessOpenShadowRoots(codePanel, 'diffs-container').flatMap(
		(host): readonly BridgeReviewRecoveryPaintedItem[] => {
			const itemMarker = host.querySelector('[data-bridge-code-view-item-id]');
			const itemId = itemMarker?.getAttribute('data-bridge-code-view-item-id') ?? null;
			if (itemId === null) return [];
			const paintedLines =
				host.shadowRoot === null ? [] : [...host.shadowRoot.querySelectorAll('[data-line-index]')];
			const bounds = host.getBoundingClientRect();
			return [
				{
					bottom: bounds.bottom,
					itemId,
					paintedLineCount: paintedLines.length,
					text: paintedLines.map((line): string => line.textContent ?? '').join('\n'),
					top: bounds.top,
				},
			];
		},
	);
}

function bridgeReviewRecoveryWitnessPierreTreeHost(container: HTMLElement): HTMLElement | null {
	const treeHost = container.querySelector(
		'[data-testid="bridge-review-trees-panel"] file-tree-container',
	);
	return treeHost instanceof HTMLElement ? treeHost : null;
}

function bridgeReviewRecoveryWitnessPierreSearchInput(
	container: HTMLElement,
): HTMLInputElement | null {
	const searchInput = container.querySelector('[data-testid="bridge-review-search-input"]');
	return searchInput instanceof HTMLInputElement ? searchInput : null;
}

function bridgeReviewRecoveryWitnessPierreTreePath(
	container: HTMLElement,
	path: string,
): HTMLElement | null {
	const treeHost = bridgeReviewRecoveryWitnessPierreTreeHost(container);
	const candidatePaths = path.endsWith('/') ? [path] : [path, `${path}/`];
	const matchingRows: Element[] = [];
	for (const candidatePath of candidatePaths) {
		matchingRows.push(
			...(treeHost?.shadowRoot?.querySelectorAll(
				`[data-item-path="${CSS.escape(candidatePath)}"]`,
			) ?? []),
		);
	}
	const matchingRow =
		matchingRows.find((candidate): boolean => candidate.hasAttribute('aria-expanded')) ??
		matchingRows[0];
	return matchingRow instanceof HTMLElement ? matchingRow : null;
}

async function bridgeReviewRecoveryWitnessScrollTreePathIntoView(
	container: HTMLElement,
	path: string,
): Promise<HTMLElement> {
	const mountedRow = bridgeReviewRecoveryWitnessPierreTreePath(container, path);
	if (mountedRow !== null) return mountedRow;
	const treeHost = bridgeReviewRecoveryWitnessPierreTreeHost(container);
	const scrollOwner = treeHost?.shadowRoot?.querySelector(
		'[data-file-tree-virtualized-scroll="true"]',
	);
	if (!(scrollOwner instanceof HTMLElement)) {
		throw new Error(`Review tree scroll owner is missing for path: ${path}`);
	}
	const maximumScrollTop = Math.max(0, scrollOwner.scrollHeight - scrollOwner.clientHeight);
	const scrollStep = Math.max(1, scrollOwner.clientHeight * 0.75);
	const maximumStepCount = Math.ceil(maximumScrollTop / scrollStep) + 1;
	for (let stepIndex = 0; stepIndex <= maximumStepCount; stepIndex += 1) {
		const nextScrollTop = Math.min(maximumScrollTop, stepIndex * scrollStep);
		// oxlint-disable-next-line no-await-in-loop -- Each virtualized tree window is an observable frame boundary.
		await act(async (): Promise<void> => {
			scrollOwner.scrollTop = nextScrollTop;
			scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
			await Promise.resolve();
		});
		// oxlint-disable-next-line no-await-in-loop -- Pierre mounts the requested row after the scroll frame.
		await advanceBridgeReviewRecoveryWitnessFrames(1);
		const row = bridgeReviewRecoveryWitnessPierreTreePath(container, path);
		if (row !== null) return row;
	}
	throw new Error(`Review tree path did not enter the virtualized window: ${path}`);
}

function bridgeReviewRecoveryWitnessExpandedTreePaths(container: HTMLElement): readonly string[] {
	const treeHost = bridgeReviewRecoveryWitnessPierreTreeHost(container);
	return [
		...(treeHost?.shadowRoot?.querySelectorAll('[data-item-path][aria-expanded="true"]') ?? []),
	].flatMap((row): readonly string[] => {
		const path = row.getAttribute('data-item-path');
		return path === null ? [] : [path.replace(/\/$/u, '')];
	});
}

function requireActiveReviewPublicationIdentity(
	identity: BridgeWorkerReviewPublicationIdentity | null,
): BridgeWorkerReviewPublicationIdentity {
	if (identity === null) {
		throw new Error('Review recovery witness content requires an installed publication identity.');
	}
	return identity;
}

function bridgeReviewRecoveryWitnessCodeScrollOwner(container: HTMLElement): HTMLElement | null {
	const scrollOwner = container.querySelector('.bridge-code-view-scroll-owner');
	return scrollOwner instanceof HTMLElement ? scrollOwner : null;
}

function reviewDisplayEvent(
	files: readonly BridgeReviewRecoveryWitnessFile[],
	props: {
		readonly epoch?: number;
		readonly metadataWindowIdentity?: string;
		readonly projectionRevision?: number;
		readonly sequence?: number;
	} = {},
): BridgeWorkerReviewDisplayPatchEvent {
	const treeRows = reviewWitnessTreeRows(files);
	const projectionRevision = props.projectionRevision ?? 1;
	const metadataWindowIdentity =
		props.metadataWindowIdentity ?? `review-recovery-witness-window-r${projectionRevision}`;
	return {
		direction: 'serverWorkerToMain',
		epoch: props.epoch ?? 1,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentity(
			'review-recovery-witness-package',
			projectionRevision,
			'review-recovery-witness-source',
		),
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext('review-recovery-witness-package'),
					metadataSourceId: 'review-recovery-witness-source',
					metadataWindowIdentity,
					packageId: 'review-recovery-witness-package',
					reviewGeneration: 1,
					revision: projectionRevision,
					status: 'ready',
					summary: {
						additions: files.length,
						deletions: files.length,
						filesChanged: files.length,
						hiddenFileCount: 0,
						visibleFileCount: files.length,
					},
					totalItemCount: files.length,
					totalTreeRowCount: treeRows.length,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: files.map(
						(file): BridgeWorkerReviewDisplayItem =>
							reviewDisplayItem(file, metadataWindowIdentity),
					),
					operations: [],
					reset: true,
					startIndex: 0,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset: true,
					windows: [{ rows: treeRows, startIndex: 0 }],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision,
		sequence: props.sequence ?? 1,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function queryBridgeReviewRecoveryWitnessOpenShadowRoots(
	root: Element | ShadowRoot,
	selector: string,
): readonly Element[] {
	const matches = [...root.querySelectorAll(selector)];
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot === null) continue;
		matches.push(
			...queryBridgeReviewRecoveryWitnessOpenShadowRoots(descendant.shadowRoot, selector),
		);
	}
	return matches;
}

function reviewDisplayAppendEvent(
	files: readonly BridgeReviewRecoveryWitnessFile[],
	initialItemCount: number,
): BridgeWorkerReviewDisplayPatchEvent {
	const previousTreeRowCount = reviewWitnessTreeRows(files.slice(0, initialItemCount)).length;
	const treeRows = reviewWitnessTreeRows(files);
	return {
		direction: 'serverWorkerToMain',
		epoch: 1,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: bridgeWorkerReviewPublicationIdentity(
			'review-recovery-witness-package',
			2,
			'review-recovery-witness-source',
		),
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext('review-recovery-witness-package'),
					metadataSourceId: 'review-recovery-witness-source',
					metadataWindowIdentity: 'review-recovery-witness-window-r2',
					packageId: 'review-recovery-witness-package',
					reviewGeneration: 1,
					revision: 2,
					status: 'ready',
					summary: {
						additions: files.length,
						deletions: files.length,
						filesChanged: files.length,
						hiddenFileCount: 0,
						visibleFileCount: files.length,
					},
					totalItemCount: files.length,
					totalTreeRowCount: treeRows.length,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: files
						.slice(initialItemCount)
						.map((file): BridgeWorkerReviewDisplayItem => reviewDisplayItem(file)),
					operations: [],
					reset: false,
					startIndex: initialItemCount,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset: false,
					windows: [
						{
							rows: treeRows.slice(previousTreeRowCount),
							startIndex: previousTreeRowCount,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision: 2,
		sequence: 2,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: 1,
	};
}

function reviewDisplayItem(
	file: BridgeReviewRecoveryWitnessFile,
	metadataWindowIdentity = 'review-recovery-witness-window-r2',
): BridgeWorkerReviewDisplayItem {
	const semanticDocumentRevision = `review-recovery-semantic:${file.itemId}:${file.contentMarker}`;
	return {
		contentFacts: [
			{
				contentDigest: {
					algorithm: 'review-recovery-fixture',
					authority: 'provisional',
					value: `base:${file.itemId}`,
				},
				role: 'base',
				semanticDocumentRevision,
			},
			{
				contentDigest: {
					algorithm: 'review-recovery-fixture',
					authority: 'provisional',
					value: `head:${file.itemId}:${file.contentMarker}`,
				},
				role: 'head',
				semanticDocumentRevision,
			},
		],
		extentFacts: [
			{ contentRole: 'base', itemId: file.itemId, lineCount: file.lineCount },
			{ contentRole: 'head', itemId: file.itemId, lineCount: file.lineCount },
		],
		metadata: {
			additions: file.lineCount,
			deletions: file.lineCount,
			basePath: file.path,
			changeKind: file.changeKind ?? 'modified',
			contentDescriptorIdsByRole: file.sourceDescriptorIdsByRole ?? {},
			contentHashesByRole: {},
			contentRoles: ['base', 'head'],
			extension: 'swift',
			fileClass: file.fileClass ?? 'source',
			headPath: file.path,
			isHiddenByDefault: false,
			itemId: file.itemId,
			language: 'swift',
			mimeTypes: ['text/x-swift'],
			provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
			reviewPriority: 'normal',
			reviewState: 'unreviewed',
		},
		metadataWindowIdentity,
	};
}

function textIncludingOpenShadowRoots(root: Element | ShadowRoot): string {
	const textFragments: string[] = [];
	const textWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	let currentNode = textWalker.nextNode();
	while (currentNode !== null) {
		textFragments.push(currentNode.textContent ?? '');
		currentNode = textWalker.nextNode();
	}
	if (root instanceof Element && root.shadowRoot !== null) {
		textFragments.push(textIncludingOpenShadowRoots(root.shadowRoot));
	}
	for (const descendant of root.querySelectorAll('*')) {
		if (descendant.shadowRoot !== null) {
			textFragments.push(textIncludingOpenShadowRoots(descendant.shadowRoot));
		}
	}
	return textFragments.join('\n');
}
