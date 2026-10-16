import { afterEach, describe, expect, test, vi } from 'vitest';

import corpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-batch-record-corpus.json' with { type: 'json' };
import sessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { BridgeCommWorkerProductBatchApplication } from './bridge-comm-worker-product-batch-application.js';
import { bridgeCommWorkerReviewDisplayPatchesFromBatch } from './bridge-comm-worker-review-batch-display.js';
import { createBridgeMainRenderSnapshotStore } from './bridge-main-render-snapshot-store.js';
import {
	createBridgeMainReviewPresentationInstallationGate,
	type BridgeMainReviewInstallAdmissionRequest,
	type BridgeMainReviewInstallAdmissionResult,
} from './bridge-main-review-presentation-installation-gate.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import { bridgeProductReviewBatchRecordSchema } from './bridge-product-review-batch-record-contracts.js';
import {
	bridgeWorkerReviewDisplayPatchEventSchema,
	type BridgeWorkerReviewDisplayPatch,
	type BridgeWorkerReviewPublicationIdentity,
} from './bridge-worker-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('C15 post-W4 source failure before native installation admission returns', () => {
	test.each([
		{ retainedDisplay: false, recoveryExhausted: false },
		{ retainedDisplay: true, recoveryExhausted: false },
		{ retainedDisplay: false, recoveryExhausted: true },
		{ retainedDisplay: true, recoveryExhausted: true },
	])(
		'terminal metadata failure ends the candidate-source hold: $retainedDisplay retained, $recoveryExhausted exhausted',
		async ({ retainedDisplay, recoveryExhausted }) => {
			const store = createBridgeMainRenderSnapshotStore();
			const admissionEntered = createBridgeProductDeferred<void>();
			const admission = createBridgeProductDeferred<BridgeMainReviewInstallAdmissionResult>();
			let sourceListeners = 0;
			const receipts: string[] = [];
			const requests: BridgeMainReviewInstallAdmissionRequest[] = [];
			const lifecyclePhases: string[] = [];
			let holdAdmission = false;
			let sequence = 0;
			let installTask: Promise<void> = Promise.resolve();
			const gate = createBridgeMainReviewPresentationInstallationGate({
				installationPort: {
					requestInstallAdmission: (request): Promise<BridgeMainReviewInstallAdmissionResult> => {
						requests.push(request);
						if (!holdAdmission)
							return Promise.resolve({
								candidatePublicationId: request.candidatePublicationId,
								status: 'admitted',
							});
						admissionEntered.resolve();
						return admission.promise;
					},
					sendInstalledReceipt: (identity): Promise<void> => {
						receipts.push(identity.publicationId);
						return Promise.resolve();
					},
					requestWorkerReplacement: (): void => {
						throw new Error('Unexpected worker replacement.');
					},
				},
				onLifecycleEvent: (event): void => {
					lifecyclePhases.push(event.phase);
				},
				prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(true),
				store: {
					...store,
					subscribeReviewCandidateSource: (listener): (() => void) => {
						sourceListeners += 1;
						const unsubscribe = store.subscribeReviewCandidateSource(listener);
						return (): void => {
							sourceListeners -= 1;
							unsubscribe();
						};
					},
				},
			});
			const publishDisplay = (
				patches: readonly BridgeWorkerReviewDisplayPatch[],
				source: BridgeWorkerReviewPublicationIdentity | null,
			): void => {
				if (source === null) throw new Error('Publication identity is required.');
				expect(
					store.stageReviewCandidateDisplayEvent({
						identity: {
							generation: source.reviewGeneration,
							packageId: source.packageId,
							publicationId: source.publicationId,
							revision: source.revision,
							sourceIdentity: source.sourceIdentity,
						},
						event: bridgeWorkerReviewDisplayPatchEventSchema.parse({
							direction: 'serverWorkerToMain',
							epoch: 1,
							kind: 'reviewDisplayPatch',
							patches,
							projectionRevision: ++sequence,
							reviewPublicationIdentity: source,
							sequence,
							surface: 'review',
							transferDescriptors: [],
							wireVersion: 1,
						}),
					}),
				).toBe(true);
			};
			const application = new BridgeCommWorkerProductBatchApplication({
				applyComment: (): void => {
					throw new Error('Unexpected Comment bank.');
				},
				applyFile: (): void => {
					throw new Error('Unexpected File bank.');
				},
				applyReview: (presentation): void =>
					publishDisplay(
						bridgeCommWorkerReviewDisplayPatchesFromBatch(presentation),
						presentation.runtimeSource.reviewPublicationIdentity,
					),
				createSequence: (): number => ++sequence,
				publishMessage: (message): void => {
					if (message.kind === 'reviewCandidateStarted')
						expect(
							store.startReviewCandidate({
								disposition: message.disposition,
								identity: {
									generation: message.reviewGeneration,
									packageId: message.packageId,
									publicationId: message.publicationId,
									revision: message.revision,
									sourceIdentity: message.sourceIdentity,
								},
							}),
						).toBe(true);
					else if (message.kind === 'reviewCandidateReady')
						installTask = gate.handleCandidateReady(message, {
							activeEditorStableFileIdentities: [],
							stableFileIdentities: [],
						});
					else throw new Error('Unexpected candidate event.');
				},
				publishReviewDisplay: ({ patches, reviewPublicationIdentity }): void =>
					publishDisplay(patches, reviewPublicationIdentity),
				requestResnapshot: (): void => {},
				requestResnapshotLatest: (): void => {},
				workerDerivationEpoch: (): number => 1,
			});
			const fixture = bridgeProductReviewBatchRecordSchema.parse(corpus.records[2]?.record);
			if (fixture.recordKind !== 'publication' || fixture.displayed === null)
				throw new Error('Complete publication fixture missing.');
			const displayedFixture = fixture.displayed;
			const installPublication = async (revision: number): Promise<string> => {
				const publicationId = `00000000-0000-7000-8000-${String(revision).padStart(12, '0')}`;
				const publication = {
					...fixture,
					desired: { ...fixture.desired, status: 'ready' as const },
					displayed: { ...displayedFixture, publicationId, revision },
					publicationId,
					revision,
				};
				const begin = bridgeProductBatchFrameSchema.parse({
					...sessionCorpus.transportV2.batchFrames[0],
					publicationId,
					targetRevision: revision,
				});
				if (begin.kind !== 'subscription.batchBegin') throw new Error('Review begin required.');
				await application.sinks().install({
					begin,
					certified: true,
					staleRecords: [],
					domain: 'default',
					records: [{ key: 'publication', revision: publication.revision, value: publication }],
				});
				return publicationId;
			};
			try {
				let displayedPublicationId: string | null = null;
				if (retainedDisplay) {
					displayedPublicationId = await installPublication(1);
					await installTask;
				}
				const displayedSnapshot = store.getSnapshot();
				holdAdmission = true;
				const failedPublicationId = await installPublication(2);
				await admissionEntered.promise;
				expect(application.handleMetadataFailure(1)).toBe('retainedActive');
				expect(store.getReviewCandidateSourceDiagnostic()?.status).toBe('stale');
				admission.resolve({ candidatePublicationId: failedPublicationId, status: 'admitted' });
				await installTask;
				expect(receipts).toEqual(displayedPublicationId === null ? [] : [displayedPublicationId]);
				// The production application emitted the stale source; no artificial CandidateReady or source hold was injected.
				expect(sourceListeners).toBe(0);
				expect(store.getReviewRefreshPresentation().candidate).toBeNull();
				expect(store.getReviewRefreshPresentation().activeIdentity?.publicationId ?? null).toBe(
					displayedPublicationId,
				);
				expect(store.getSnapshot()).toBe(displayedSnapshot);
				expect(lifecyclePhases).toContain('candidateSuperseded');
				if (recoveryExhausted) {
					const transport = createTransportHarness({
						deadlineClock: { schedule: (): (() => void) => (): void => {} },
						onViewRecoveryStatus: (event): void =>
							store.applyViewRecoveryStatusEvent({
								...event,
								direction: 'serverWorkerToMain',
								kind: 'viewRecoveryStatus',
								transferDescriptors: [],
								wireVersion: 1,
							}),
					});
					transport.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
					transport.transport.reportMetadataReopenExhausted('review.metadata');
					expect(store.getViewRecoveryStatus('review.metadata')?.status).toBe('failedRetryable');
					expect(store.getReviewRefreshPresentation().failure).toBeNull();
				} else {
					holdAdmission = false;
					const recoveredPublicationId = await installPublication(3);
					await installTask;
					expect(requests.at(-1)).toEqual({
						candidatePublicationId: recoveredPublicationId,
						expectedDisplayedPublicationId: displayedPublicationId,
					});
					expect(receipts.at(-1)).toBe(recoveredPublicationId);
					expect(receipts).not.toContain(failedPublicationId);
					expect(store.getReviewRefreshPresentation()).toMatchObject({
						activeIdentity: { publicationId: recoveredPublicationId },
						candidate: null,
						failure: null,
					});
					expect(sourceListeners).toBe(0);
				}
			} finally {
				gate.close();
			}
		},
	);
});
