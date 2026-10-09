import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from '../../foundation/telemetry/bridge-telemetry-event.js';
import {
	ACTIVE,
	CANDIDATE,
	SUCCESSOR,
	LATEST,
	createHarness,
	recordingTelemetryRecorder,
	installPublication,
	mainIdentity,
	candidateReady,
	candidateFailed,
	candidateStarted,
	reviewDisplayEvent,
	reviewRenderPatch,
	reviewPierrePublication,
} from './bridge-main-review-publication-integration.test-support.js';

describe('Bridge main Review publication integration', () => {
	test('late candidate source readiness resumes one installation after an early ready fact', async () => {
		const harness = createHarness();
		harness.startCandidate(CANDIDATE, 'ordinary', []);
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		await harness.integration.whenSettled();
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);

		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		await harness.integration.whenSettled();
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(1);
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		harness.admit(admission, CANDIDATE, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installed);
		await harness.integration.whenSettled();
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		harness.dispose();
	});

	test('a failed source ends an awaiting candidate with a typed failure and no install request', async () => {
		const harness = createHarness();
		harness.startCandidate(CANDIDATE, 'ordinary', []);
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		await harness.integration.whenSettled();
		const display = reviewDisplayEvent(CANDIDATE, 'item-b');
		const failedSourcePatch = {
			operation: 'failed',
			payload: { error: 'metadataUnavailable', status: 'failed' },
			slice: 'reviewSource',
		} as const;

		harness.receive({
			...display,
			patches: display.patches.map((patch) =>
				patch.slice === 'reviewSource' ? failedSourcePatch : patch,
			),
		});
		await harness.integration.whenSettled();

		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);
		expect(harness.store.getReviewRefreshPresentation().candidate).toBeNull();
		expect(
			harness.telemetrySamples.some(
				(sample): boolean =>
					sample.stringAttributes['agentstudio.bridge.phase'] === 'review_refresh_candidate_failed',
			),
		).toBe(true);
		harness.dispose();
	});

	test('a superseded source wait cannot install the retired candidate', async () => {
		const harness = createHarness();
		harness.startCandidate(CANDIDATE, 'ordinary', []);
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		await harness.integration.whenSettled();
		harness.startCandidate(SUCCESSOR, 'ordinary', []);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
		await harness.integration.whenSettled();
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);

		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		await harness.integration.whenSettled();
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		expect(admission).toMatchObject({ candidatePublicationId: SUCCESSOR.publicationId });
		expect(harness.commandKinds.filter((kind) => kind === 'reviewPublicationInstallAdmit')).toEqual(
			['reviewPublicationInstallAdmit'],
		);
		harness.dispose();
	});

	test('retains the displayed item while exact-active metadata rebinds to a newer worker epoch', async () => {
		// Arrange — installed content precedes a subscription-only authority replacement.
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-a');
			const display = reviewDisplayEvent(ACTIVE, 'item-a');
			const identifiedDisplay = {
				...display,
				projectionRevision: 2,
				sequence: 10,
				patches: display.patches.map((patch) =>
					patch.slice === 'reviewItem' && patch.operation === 'batch'
						? {
								...patch,
								payload: {
									...patch.payload,
									items: patch.payload.items.map((item) => ({
										...item,
										metadata: { ...item.metadata, contentRoles: ['head' as const] },
										contentFacts: [
											{
												role: 'head' as const,
												semanticDocumentRevision: 'stable-document',
												contentDigest: {
													algorithm: 'sha256' as const,
													authority: 'authoritative' as const,
													value: 'a'.repeat(64),
												},
											},
										],
									})),
								},
							}
						: patch,
				),
			};
			harness.receive(identifiedDisplay);
			harness.receive(reviewPierrePublication(ACTIVE, 'item-a', 14));
			const displayedItem = harness.store.getReviewCodeViewItemSnapshot('item-a');
			expect(displayedItem).toBeDefined();

			// Act — same publication/content, no replacement content has arrived yet.
			harness.receive({ ...candidateStarted(ACTIVE, 'ordinary', []), epoch: 2 });
			harness.receive({
				...identifiedDisplay,
				epoch: 2,
				projectionRevision: 3,
				sequence: 20,
			});

			// Assert — a new transport epoch cannot blank the last complete display.
			expect(harness.store.getReviewCodeViewItemSnapshot('item-a')).toBe(displayedItem);
			expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
				mainIdentity(ACTIVE),
			);

			// Changed content must still retire the old render copy even under the same publication.
			harness.receive({
				...identifiedDisplay,
				epoch: 2,
				projectionRevision: 4,
				sequence: 21,
				patches: identifiedDisplay.patches.map((patch) =>
					patch.slice === 'reviewItem' && patch.operation === 'batch'
						? {
								...patch,
								payload: {
									...patch.payload,
									items: patch.payload.items.map((item) => ({
										...item,
										contentFacts: item.contentFacts.map((fact) => ({
											...fact,
											contentDigest: { ...fact.contentDigest, value: 'b'.repeat(64) },
										})),
									})),
								},
							}
						: patch,
				),
			});
			expect(harness.store.getReviewCodeViewItemSnapshot('item-a')).toBeUndefined();
		} finally {
			harness.dispose();
		}
	});

	test('applies exact-active projection patches without staging a successor candidate', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');

		// Act
		harness.receive({
			...reviewDisplayEvent(ACTIVE, 'item-active-query'),
			projectionRevision: 2,
			sequence: 3,
		});

		// Assert
		expect(harness.store.getReviewItemSnapshot('item-active-query')).toBeDefined();
		expect(harness.store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: mainIdentity(ACTIVE),
			candidate: null,
			failure: null,
		});
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);
		harness.dispose();
	});

	test('routes render work from a newer exact-active worker derivation epoch', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		const activeDisplayEvent = {
			...reviewDisplayEvent(ACTIVE, 'item-active-query'),
			epoch: 2,
			projectionRevision: 2,
			sequence: 3,
		};

		// Act
		harness.receive(activeDisplayEvent);
		harness.receive({
			...reviewRenderPatch(ACTIVE, 'item-active-query'),
			workerDerivationEpoch: 2,
		});
		harness.receive({
			...reviewPierrePublication(ACTIVE, 'item-active-query', 14),
			workerDerivationEpoch: 2,
		});

		// Assert
		expect(harness.store.getReviewCodeViewItemSnapshot('item-active-query')).toBeDefined();
		expect(harness.courierJobs.map((job) => job.itemId)).toContain('item-active-query');
		harness.dispose();
	});

	test('orders real RPC display, ready, admission, promotion, installed, and acknowledgement', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');

		// Act
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');

		// Assert
		expect(harness.store.getReviewItemSnapshot('item-a')).toBeDefined();
		expect(harness.store.getReviewItemSnapshot('item-b')).toBeUndefined();
		expect(admission).toMatchObject({
			candidatePublicationId: CANDIDATE.publicationId,
			expectedDisplayedPublicationId: ACTIVE.publicationId,
		});

		// Act
		harness.admit(admission, CANDIDATE, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');

		// Assert
		expect(harness.store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: mainIdentity(CANDIDATE),
			candidate: null,
			failure: null,
		});
		expect(harness.store.getReviewItemSnapshot('item-b')).toBeDefined();
		expect(installed).toMatchObject({
			packageId: CANDIDATE.packageId,
			publicationId: CANDIDATE.publicationId,
			reviewGeneration: CANDIDATE.reviewGeneration,
			revision: CANDIDATE.revision,
			sourceIdentity: CANDIDATE.sourceIdentity,
		});

		// Act
		harness.ack(installed);
		await harness.integration.whenSettled();

		// Assert
		expect(harness.commandKinds.slice(-2)).toEqual([
			'reviewPublicationInstallAdmit',
			'reviewPublicationInstalled',
		]);
		harness.dispose();
	});

	test('does not dispatch install admission before active editor preparation settles', async () => {
		// Arrange
		let prepareCallCount = 0;
		let resolvePreparation = (_prepared: boolean): void => {};
		const harness = createHarness({
			prepareActiveEditorsForInstallation: (): Promise<boolean> => {
				prepareCallCount += 1;
				return new Promise((resolve): void => {
					resolvePreparation = resolve;
				});
			},
		});
		await installPublication(harness, ACTIVE, 'item-a');
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: ['item-b'],
			stableFileIdentities: ['item-b'],
		});
		harness.startCandidate(CANDIDATE, 'ordinary', ['item-b']);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));

		// Act
		harness.receive(candidateReady(CANDIDATE, 'ordinary', ['item-b']));

		// Assert
		expect(prepareCallCount).toBe(1);
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);

		// Act
		resolvePreparation(true);
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		harness.admit(admission, CANDIDATE, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installed);
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		harness.dispose();
	});

	test('allocates install admission and installed receipt from the main command epoch', async () => {
		// Arrange
		const harness = createHarness();
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));

		// Act
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');

		// Assert
		expect(admission.epoch).toBe(101);

		// Act
		harness.admit(admission, CANDIDATE, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');

		// Assert
		expect(installed.epoch).toBe(102);
		harness.dispose();
	});

	test('installs admitted B once and accepts replayed newest C through active-plus-one', async () => {
		// Arrange
		const harness = createHarness();
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		const admissionB = await harness.nextCommand('reviewPublicationInstallAdmit');
		expect(admissionB).toMatchObject({
			candidatePublicationId: CANDIDATE.publicationId,
			expectedDisplayedPublicationId: null,
		});

		// Act: C completes while B owns installation; its first delivery cannot replace B.
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		harness.receive(reviewRenderPatch(SUCCESSOR, 'item-c'));
		harness.receive(reviewPierrePublication(SUCCESSOR, 'item-c', 22));
		harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
		expect(harness.store.getReviewRefreshPresentation().candidate?.identity).toEqual(
			mainIdentity(CANDIDATE),
		);
		expect(harness.rejectedItemIds).toContain('item-c');
		expect(harness.courierJobs).toEqual([]);
		harness.admit(admissionB, CANDIDATE, 'admitted');
		const installedB = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installedB);
		await harness.integration.whenSettled();

		// Act: the comm worker re-exposes only newest C after native acknowledges B.
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		harness.receive(reviewRenderPatch(SUCCESSOR, 'item-c'));
		harness.receive(reviewPierrePublication(SUCCESSOR, 'item-c', 22));
		harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
		const admissionC = await harness.nextCommand('reviewPublicationInstallAdmit');
		expect(admissionC).toMatchObject({
			candidatePublicationId: SUCCESSOR.publicationId,
			expectedDisplayedPublicationId: CANDIDATE.publicationId,
		});
		harness.admit(admissionC, SUCCESSOR, 'admitted');
		const installedC = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installedC);
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: mainIdentity(SUCCESSOR),
			candidate: null,
			failure: null,
		});
		expect(harness.courierJobs.map((job) => job.itemId)).toEqual(['item-c']);
		expect(harness.store.getReviewCodeViewItemSnapshot('item-c')).toBeDefined();
		expect(harness.store.getReviewAvailabilitySnapshot('item-c')).toEqual({ state: 'ready' });
		harness.dispose();
	});

	test('accepts replayed D after native rejects installing C', async () => {
		// Arrange: B is displayed and C owns the installing bank.
		const harness = createHarness();
		await installPublication(harness, CANDIDATE, 'item-b');
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
		const admissionC = await harness.nextCommand('reviewPublicationInstallAdmit');

		// Act: D completes while C is pinned, then native rejects stale C.
		harness.receive(reviewDisplayEvent(LATEST, 'item-d'));
		harness.receive(candidateReady(LATEST, 'ordinary', []));
		expect(harness.store.getReviewRefreshPresentation().candidate?.identity).toEqual(
			mainIdentity(SUCCESSOR),
		);
		harness.admit(admissionC, SUCCESSOR, 'rejected');
		await harness.integration.whenSettled();
		expect(harness.store.getReviewRefreshPresentation().candidate).toBeNull();

		// Act: the worker's rejection recovery re-exposes only newest D.
		harness.receive(reviewDisplayEvent(LATEST, 'item-d'));
		harness.receive(candidateReady(LATEST, 'ordinary', []));
		const admissionD = await harness.nextCommand('reviewPublicationInstallAdmit');
		expect(admissionD).toMatchObject({
			candidatePublicationId: LATEST.publicationId,
			expectedDisplayedPublicationId: CANDIDATE.publicationId,
		});
		harness.admit(admissionD, LATEST, 'admitted');
		const installedD = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installedD);
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: mainIdentity(LATEST),
			candidate: null,
			failure: null,
		});
		harness.dispose();
	});

	test('accepts one synchronous install-admission response without retaining later responses', async () => {
		// Arrange
		const harness = createHarness({ synchronousAdmissionStatus: 'admitted' });
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));

		// Act
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		const installed = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installed);
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		harness.dispose();
	});

	test('holds promoted work with injected attention and Apply now installs the newest candidate', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: ['file-b'],
		});
		harness.startCandidate(CANDIDATE, 'promoted', ['file-b']);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(candidateReady(CANDIDATE, 'promoted', ['file-b']));
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation().candidate).toMatchObject({
			identity: mainIdentity(CANDIDATE),
			role: 'updateReady',
		});
		expect(harness.pendingCommandCount('reviewPublicationInstallAdmit')).toBe(0);

		// Arrange successor before action commit
		harness.startCandidate(SUCCESSOR, 'promoted', ['file-c']);
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: ['file-c'],
		});
		harness.receive(candidateReady(SUCCESSOR, 'promoted', ['file-c']));
		await harness.integration.whenSettled();

		// Act
		const apply = harness.integration.applyNow();
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		if (admission.command !== 'reviewPublicationInstallAdmit') {
			throw new Error('Expected Review publication install admission command.');
		}
		expect(admission.candidatePublicationId).toBe(SUCCESSOR.publicationId);
		harness.admit(admission, SUCCESSOR, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installed);
		await apply;

		// Assert
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(SUCCESSOR),
		);
		harness.dispose();
	});

	test('keeps candidate render and Pierre state off active A, drops B on C, and flushes C on promotion', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		const catalogCursorBeforeHeldSuccessors = harness.store.getReviewCatalogSnapshot().changeCursor;
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));

		// Act
		harness.receive(reviewRenderPatch(CANDIDATE, 'item-b'));
		harness.receive(reviewPierrePublication(CANDIDATE, 'item-b', 21));

		// Assert
		expect(harness.store.getReviewItemSnapshot('item-a')).toBeDefined();
		expect(harness.store.getReviewItemSnapshot('item-b')).toBeUndefined();
		expect(harness.store.getReviewCodeViewItemSnapshot('item-b')).toBeUndefined();
		expect(harness.courierJobs).toEqual([]);

		// Act
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));
		harness.receive(reviewRenderPatch(SUCCESSOR, 'item-c'));
		harness.receive(reviewPierrePublication(SUCCESSOR, 'item-c', 22));
		harness.receive(candidateReady(SUCCESSOR, 'ordinary', []));
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		harness.admit(admission, SUCCESSOR, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');

		// Assert
		expect(harness.rejectedItemIds).toContain('item-b');
		expect(harness.courierJobs.map((job) => job.itemId)).toEqual(['item-c']);
		expect(harness.store.getReviewCodeViewItemSnapshot('item-c')).toBeDefined();
		expect(harness.store.getReviewAvailabilitySnapshot('item-c')).toEqual({ state: 'ready' });
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(SUCCESSOR),
		);
		expect(harness.store.getReviewItemSnapshot('item-a')).toBeUndefined();
		expect(harness.store.getReviewItemSnapshot('item-b')).toBeUndefined();
		expect(harness.store.getReviewItemSnapshot('item-c')).toBeDefined();
		expect(harness.store.readReviewCatalogChangesAfter(catalogCursorBeforeHeldSuccessors)).toEqual({
			changes: [
				expect.objectContaining({
					itemIds: expect.arrayContaining(['item-a', 'item-c']),
					reset: true,
				}),
			],
			resetRequired: false,
		});

		// Act
		harness.ack(installed);
		await harness.integration.whenSettled();
		harness.dispose();
	});

	test('worker replacement discards candidate work and a late admission cannot promote it', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(reviewPierrePublication(CANDIDATE, 'item-b', 31));
		harness.receive(candidateReady(CANDIDATE, 'ordinary', []));
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');

		// Act
		harness.store.prepareForWorkerReplacement();
		harness.fail(admission);
		harness.admit(admission, CANDIDATE, 'admitted');
		await harness.integration.whenSettled();

		// Assert
		expect(harness.store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: mainIdentity(ACTIVE),
			candidate: null,
			failure: null,
		});
		expect(harness.rejectedItemIds).toContain('item-b');
		expect(harness.pendingCommandCount('reviewPublicationInstalled')).toBe(0);
		expect(
			harness.telemetrySamples.some(
				(sample): boolean =>
					sample.stringAttributes['agentstudio.bridge.phase'] ===
						'review_refresh_cleanup_terminal' &&
					sample.stringAttributes['agentstudio.bridge.result_reason'] === 'worker_replacement',
			),
		).toBe(true);
		harness.dispose();
	});

	test('records lifecycle events through the current telemetry recorder after bootstrap', async () => {
		// Arrange
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		const postBootstrapSamples: BridgeTelemetrySample[] = [];
		harness.telemetryRecorderRef.current = recordingTelemetryRecorder(postBootstrapSamples);
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: ['file-b'],
		});

		// Act
		harness.startCandidate(CANDIDATE, 'promoted', ['file-b']);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.receive(candidateReady(CANDIDATE, 'promoted', ['file-b']));

		// Assert
		expect(postBootstrapSamples).toContainEqual(
			expect.objectContaining({
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.phase': 'review_refresh_candidate_held',
				}),
			}),
		);
		harness.dispose();
	});

	test('records two affected stable identities for a same-source successor publication', async () => {
		const harness = createHarness();
		try {
			await installPublication(harness, ACTIVE, 'item-before-mutation');
			const successor = {
				...ACTIVE,
				publicationId: '00000000-0000-7000-8000-000000000014',
				revision: ACTIVE.revision + 1,
			};
			const samplesAfterMutation: BridgeTelemetrySample[] = [];
			harness.telemetryRecorderRef.current = recordingTelemetryRecorder(samplesAfterMutation);
			const affectedStableFileIdentities = ['file-before-mutation', 'file-after-mutation'];

			harness.startCandidate(successor, 'ordinary', affectedStableFileIdentities);
			// The harness's receive() convenience synthesizes an empty candidate start for display patches.
			harness.integration.handleMessage(reviewDisplayEvent(successor, 'item-after-mutation'));
			harness.receive(candidateReady(successor, 'ordinary', affectedStableFileIdentities));
			const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
			harness.admit(admission, successor, 'admitted');
			const installed = await harness.nextCommand('reviewPublicationInstalled');
			harness.ack(installed);
			await harness.integration.whenSettled();

			const candidateReadySamples = samplesAfterMutation.filter(
				(sample): boolean =>
					sample.name === 'performance.bridge.web.review_refresh_lifecycle' &&
					sample.stringAttributes['agentstudio.bridge.phase'] === 'review_refresh_candidate_ready',
			);
			expect(candidateReadySamples).toHaveLength(1);
			expect(candidateReadySamples[0]).toMatchObject({
				stringAttributes: {
					'agentstudio.bridge.review.refresh.presentation_class': 'ordinary',
				},
				numericAttributes: {
					'agentstudio.bridge.review.generation': ACTIVE.reviewGeneration,
					'agentstudio.bridge.review.refresh.affected_stable_file.count': 2,
				},
			});
		} finally {
			harness.dispose();
		}
	});

	test('ignores stale B failure, retains affected C failure, and clears it when attention leaves', async () => {
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: ['any-review-file'],
		});
		harness.startCandidate(CANDIDATE, 'promoted', ['file-b']);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));
		harness.startCandidate(SUCCESSOR, 'promoted', ['any-review-file']);
		harness.receive(reviewDisplayEvent(SUCCESSOR, 'item-c'));

		harness.receive(candidateFailed(CANDIDATE, true));
		expect(harness.store.getReviewRefreshPresentation().candidate?.identity).toEqual(
			mainIdentity(SUCCESSOR),
		);
		expect(harness.store.getReviewRefreshPresentation().failure).toBeNull();

		harness.receive(candidateFailed(SUCCESSOR, true));
		expect(harness.store.getReviewRefreshPresentation().candidate).toBeNull();
		expect(harness.store.getReviewRefreshPresentation().failure).toMatchObject({
			identity: mainIdentity(SUCCESSOR),
			presentationClass: { kind: 'promoted', reason: 'files' },
			retryable: true,
		});

		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: [],
		});
		await harness.integration.whenSettled();
		expect(harness.store.getReviewRefreshPresentation().failure).toBeNull();
		harness.dispose();
	});

	test('fences stale ready and failure after the restarted worker installs its publication', async () => {
		const harness = createHarness();
		await installPublication(harness, ACTIVE, 'item-a');
		harness.receive({ ...candidateStarted(CANDIDATE, 'promoted', ['file-b']), epoch: 1 });
		harness.store.prepareForWorkerReplacement();
		harness.integration.setSemanticAttention({
			activeEditorStableFileIdentities: [],
			stableFileIdentities: ['file-b'],
		});
		harness.startCandidate(CANDIDATE, 'promoted', ['file-b']);
		harness.receive(reviewDisplayEvent(CANDIDATE, 'item-b'));

		harness.receive({ ...candidateReady(CANDIDATE, 'promoted', ['file-b']), epoch: 1 });
		await harness.integration.whenSettled();
		expect(harness.store.getReviewRefreshPresentation().candidate).toMatchObject({
			identity: mainIdentity(CANDIDATE),
			role: 'provisional',
		});

		harness.receive(candidateReady(CANDIDATE, 'promoted', ['file-b']));
		const admission = await harness.nextCommand('reviewPublicationInstallAdmit');
		harness.admit(admission, CANDIDATE, 'admitted');
		const installed = await harness.nextCommand('reviewPublicationInstalled');
		harness.ack(installed);
		await harness.integration.whenSettled();
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		expect(harness.store.getReviewRefreshPresentation().candidate).toBeNull();

		harness.receive({ ...candidateFailed(CANDIDATE, true), epoch: 1 });
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		expect(harness.store.getReviewRefreshPresentation().failure).toBeNull();

		harness.receive(candidateFailed(CANDIDATE, true));
		expect(harness.store.getReviewRefreshPresentation().candidate).toBeNull();
		expect(harness.store.getReviewRefreshPresentation().activeIdentity).toEqual(
			mainIdentity(CANDIDATE),
		);
		expect(harness.store.getReviewRefreshPresentation().failure).toBeNull();
		harness.dispose();
	});
});
