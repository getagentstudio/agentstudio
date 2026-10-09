import { describe, expect, test } from 'vitest';

import {
	FakeCandidateStore,
	ImmediateInstallationPort,
	DeferredInstallationPort,
	identity,
	candidateReady,
	candidateFailed,
	attention,
	sameSourceStart,
} from './bridge-main-review-installation-gate.test-support.js';
import {
	createBridgeMainReviewPresentationInstallationGate as createBridgeMainReviewPresentationInstallationGateImpl,
	type BridgeMainReviewRefreshLifecycleEvent,
} from './bridge-main-review-presentation-installation-gate.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';

const ACTIVE = identity(1, '11');
const CANDIDATE = identity(2, '12');
const SUCCESSOR = identity(3, '13');

type InstallationGateProps = Omit<
	Parameters<typeof createBridgeMainReviewPresentationInstallationGateImpl>[0],
	'prepareActiveEditorsForInstallation'
> & {
	readonly prepareActiveEditorsForInstallation?: () => Promise<boolean>;
};

function createBridgeMainReviewPresentationInstallationGate(
	props: InstallationGateProps,
): ReturnType<typeof createBridgeMainReviewPresentationInstallationGateImpl> {
	return createBridgeMainReviewPresentationInstallationGateImpl({
		prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(true),
		...props,
	});
}

describe('Bridge main Review presentation installation gate', () => {
	test('reports one scrubbed lifecycle sequence for hold, Apply now, and cleanup', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const events: BridgeMainReviewRefreshLifecycleEvent[] = [];
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			onLifecycleEvent: (event): void => {
				events.push(event);
			},
			store,
		});

		// Act
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'promoted', ['file-b']),
			attention(['file-b']),
		);
		await gate.applyNow();
		gate.close();

		// Assert
		expect(events).toEqual([
			{
				affectedStableFileCount: 1,
				generation: CANDIDATE.generation,
				phase: 'candidateReady',
				presentationClass: { kind: 'promoted', reason: 'files' },
			},
			{
				affectedStableFileCount: 1,
				generation: CANDIDATE.generation,
				phase: 'candidateHeld',
				presentationClass: { kind: 'promoted', reason: 'files' },
			},
			{
				affectedStableFileCount: 1,
				generation: CANDIDATE.generation,
				phase: 'installRequested',
				presentationClass: { kind: 'promoted', reason: 'files' },
				trigger: 'applyNow',
			},
			{
				affectedStableFileCount: 1,
				generation: CANDIDATE.generation,
				phase: 'installTerminal',
				presentationClass: { kind: 'promoted', reason: 'files' },
				result: 'success',
				resultReason: 'none',
				trigger: 'applyNow',
			},
			{
				activeBankCount: 1,
				candidateBankCount: 0,
				phase: 'cleanup',
				reason: 'close',
			},
		]);
	});

	test('auto-installs an ordinary candidate and sends its installed receipt', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});

		// Act
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', ['file-b']),
			attention([]),
		);

		// Assert
		expect(port.requests).toEqual([
			{
				candidatePublicationId: CANDIDATE.publicationId,
				expectedDisplayedPublicationId: ACTIVE.publicationId,
			},
		]);
		expect(store.promotions).toEqual([CANDIDATE.publicationId]);
		expect(port.receipts).toEqual([CANDIDATE.publicationId]);
		expect(store.presentation.activeIdentity).toEqual(CANDIDATE);
	});

	test('prepares an affected active editor before requesting install admission', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'ordinary' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		let prepareCallCount = 0;
		let resolvePreparation = (_prepared: boolean): void => {};
		const prepareActiveEditorsForInstallation = (): Promise<boolean> => {
			prepareCallCount += 1;
			return new Promise((resolve): void => {
				resolvePreparation = resolve;
			});
		};
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			prepareActiveEditorsForInstallation,
			store,
		});

		// Act
		const install = gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', ['file-b']),
			attention(['file-b'], ['file-b']),
		);

		// Assert
		expect(prepareCallCount).toBe(1);
		expect(port.requests).toEqual([]);
		expect(store.roles).toEqual(['provisional']);

		// Act
		resolvePreparation(true);
		await install;

		// Assert
		expect(port.requests).toHaveLength(1);
		expect(store.promotions).toEqual([CANDIDATE.publicationId]);
	});

	test('escalates an ordinary candidate when affected editor continuity cannot be prepared', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'ordinary' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(false),
			store,
		});

		// Act
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', ['file-b']),
			attention(['file-b'], ['file-b']),
		);

		// Assert
		expect(port.requests).toEqual([]);
		expect(store.promotions).toEqual([]);
		expect(store.presentation.activeIdentity).toEqual(ACTIVE);
		expect(store.presentation.candidate).toMatchObject({
			effectivePresentationClass: { kind: 'promoted', reason: 'activeAnchor' },
			identity: CANDIDATE,
			role: 'updateReady',
			startDisposition: {
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});
	});

	test('exposes promoted preservation failure without partial installation', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			prepareActiveEditorsForInstallation: (): Promise<boolean> => Promise.resolve(false),
			store,
		});
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'promoted', ['file-b']),
			attention(['file-b'], ['file-b']),
		);

		// Act
		await gate.applyNow();

		// Assert
		expect(port.requests).toEqual([]);
		expect(store.promotions).toEqual([]);
		expect(store.presentation).toMatchObject({
			activeIdentity: ACTIVE,
			candidate: null,
			failure: {
				identity: CANDIDATE,
				presentationClass: { kind: 'promoted', reason: 'files' },
				retryable: true,
			},
		});
	});

	test('fences late editor preparation after worker replacement', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'ordinary' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		let resolvePreparation = (_prepared: boolean): void => {};
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			prepareActiveEditorsForInstallation: () =>
				new Promise((resolve): void => {
					resolvePreparation = resolve;
				}),
			store,
		});
		const install = gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', ['file-b']),
			attention(['file-b'], ['file-b']),
		);

		// Act
		gate.prepareForWorkerReplacement();
		resolvePreparation(true);
		await install;

		// Assert
		expect(port.requests).toEqual([]);
		expect(store.promotions).toEqual([]);
		expect(store.presentation.candidate).toBeNull();
	});

	test('holds an affected promoted candidate and installs when semantic attention leaves', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});

		// Act
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'promoted', ['file-b']),
			attention(['file-b']),
		);
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'promoted', ['file-b']),
			attention(['file-b']),
		);

		// Assert
		expect(store.roles).toEqual(['updateReady']);
		expect(port.requests).toEqual([]);

		// Act
		await gate.semanticAttentionChanged(attention(['unaffected-file']));

		// Assert
		expect(store.roles).toEqual(['updateReady', 'provisional', 'installing']);
		expect(store.promotions).toEqual([CANDIDATE.publicationId]);
	});

	test('treats promoted unknown as affecting any current Review attention without an identity union', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'unknown' }, []),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		const unknownCandidate = candidateReady(CANDIDATE, 'promoted', []);

		// Act
		await gate.handleCandidateReady(unknownCandidate, attention(['any-current-review-file']));

		// Assert
		expect(store.roles).toEqual(['updateReady']);
		expect(port.requests).toEqual([]);

		// Act
		await gate.semanticAttentionChanged(attention([]));

		// Assert
		expect(store.promotions).toEqual([CANDIDATE.publicationId]);
	});

	test('Apply now admits the newest complete candidate present at action commit', async () => {
		// Arrange
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		await gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'promoted', ['file-b']),
			attention(['file-b']),
		);
		store.replaceCandidate(
			SUCCESSOR,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-c']),
		);
		await gate.handleCandidateReady(
			candidateReady(SUCCESSOR, 'promoted', ['file-c']),
			attention(['file-c']),
		);

		// Act
		await gate.applyNow();

		// Assert
		expect(port.requests).toHaveLength(1);
		expect(port.requests[0]?.candidatePublicationId).toBe(SUCCESSOR.publicationId);
		expect(store.promotions).toEqual([SUCCESSOR.publicationId]);
	});

	test('is idempotent for duplicate ready events and discards a rejected exact candidate', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new ImmediateInstallationPort(['rejected']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		const event = candidateReady(CANDIDATE, 'ordinary', []);

		// Act
		await gate.handleCandidateReady(event, attention([]));
		await gate.handleCandidateReady(event, attention([]));

		// Assert
		expect(port.requests).toHaveLength(1);
		expect(store.discards).toEqual([CANDIDATE.publicationId]);
		expect(store.presentation.activeIdentity).toEqual(ACTIVE);
		expect(store.presentation.candidate).toBeNull();
	});

	test('a rejected predecessor admission cannot leave a ready successor held without a displayed bank', async () => {
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		store.presentation = { ...store.presentation, activeIdentity: null };
		const port = new ImmediateInstallationPort(['rejected', 'admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		await gate.handleCandidateReady(candidateReady(CANDIDATE, 'ordinary', []), attention([]));
		expect(port.requests.map(({ candidatePublicationId }) => candidatePublicationId)).toEqual([
			CANDIDATE.publicationId,
		]);
		store.replaceCandidate(
			SUCCESSOR,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-c']),
		);
		await gate.handleCandidateReady(
			candidateReady(SUCCESSOR, 'promoted', ['file-c']),
			attention(['file-c']),
		);
		expect(port.requests.map(({ candidatePublicationId }) => candidatePublicationId)).toEqual([
			CANDIDATE.publicationId,
			SUCCESSOR.publicationId,
		]);
		expect(store.promotions).toEqual([SUCCESSOR.publicationId]);
		expect(port.receipts).toEqual([SUCCESSOR.publicationId]);
	});
	test('a displayed Review bank still holds an attention-affecting promoted successor', async () => {
		const store = new FakeCandidateStore(
			ACTIVE,
			SUCCESSOR,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-c']),
		);
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});

		await gate.handleCandidateReady(
			candidateReady(SUCCESSOR, 'promoted', ['file-c']),
			attention(['file-c']),
		);
		expect(port.requests).toEqual([]);
		expect(store.presentation.activeIdentity).toEqual(ACTIVE);
		expect(store.presentation.candidate?.role).toBe('updateReady');
	});

	test('a retained active identity without confirmed display cannot hold the successor', async () => {
		const store = new FakeCandidateStore(
			ACTIVE,
			SUCCESSOR,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-c']),
		);
		store.presentation = { ...store.presentation, activeIdentity: null };
		const port = new ImmediateInstallationPort(['admitted']);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		store.presentation = { ...store.presentation, activeIdentity: ACTIVE };

		await gate.handleCandidateReady(
			candidateReady(SUCCESSOR, 'promoted', ['file-c']),
			attention(['file-c']),
		);
		expect(port.requests.map(({ candidatePublicationId }) => candidatePublicationId)).toEqual([
			SUCCESSOR.publicationId,
		]);
		expect(store.promotions).toEqual([SUCCESSOR.publicationId]);
	});
	test('a rejected successor after a rejected predecessor reaches an install terminal', async () => {
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		store.presentation = { ...store.presentation, activeIdentity: null };
		const port = new ImmediateInstallationPort(['rejected', 'rejected']);
		const events: BridgeMainReviewRefreshLifecycleEvent[] = [];
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			onLifecycleEvent: (event): void => {
				events.push(event);
			},
			store,
		});
		await gate.handleCandidateReady(candidateReady(CANDIDATE, 'ordinary', []), attention([]));
		store.replaceCandidate(
			SUCCESSOR,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-c']),
		);

		await gate.handleCandidateReady(
			candidateReady(SUCCESSOR, 'promoted', ['file-c']),
			attention(['file-c']),
		);
		expect(port.requests.map(({ candidatePublicationId }) => candidatePublicationId)).toEqual([
			CANDIDATE.publicationId,
			SUCCESSOR.publicationId,
		]);
		expect(events).toContainEqual({
			affectedStableFileCount: 1,
			generation: SUCCESSOR.generation,
			phase: 'installTerminal',
			presentationClass: { kind: 'promoted', reason: 'files' },
			result: 'stale',
			resultReason: 'admissionRejected',
			trigger: 'automatic',
		});
		expect(store.presentation.candidate).toBeNull();
		expect(port.receipts).toEqual([]);
	});

	test('pins an admitted identity until it promotes despite successor arrival', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new DeferredInstallationPort();
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		const firstInstall = gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', []),
			attention([]),
		);
		const firstRequest = await port.nextRequest();
		expect(store.replaceCandidate(SUCCESSOR)).toBe(false);
		await gate.handleCandidateReady(candidateReady(SUCCESSOR, 'ordinary', []), attention([]));

		// Act
		firstRequest.resolve('admitted');
		await firstInstall;

		// Assert
		expect(store.promotions).toEqual([CANDIDATE.publicationId]);
		expect(port.receipts).toEqual([CANDIDATE.publicationId]);
	});

	test('invalidates late admission on worker replacement and close', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new DeferredInstallationPort();
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		const install = gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', []),
			attention([]),
		);
		const request = await port.nextRequest();

		// Act
		gate.prepareForWorkerReplacement();
		request.resolve('admitted');
		await install;
		store.replaceCandidate(SUCCESSOR);
		gate.close();
		await gate.handleCandidateReady(candidateReady(SUCCESSOR, 'ordinary', []), attention([]));

		// Assert
		expect(store.promotions).toEqual([]);
		expect(port.receipts).toEqual([]);
		expect(store.presentation.candidate).toBeNull();
	});

	test('stale admission failure cannot discard replacement-worker replay', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new DeferredInstallationPort();
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		const oldInstall = gate.handleCandidateReady(
			candidateReady(CANDIDATE, 'ordinary', []),
			attention([]),
		);
		const oldRequest = await port.nextRequest();

		// Act
		gate.prepareForWorkerReplacement();
		expect(store.replaceCandidate(CANDIDATE)).toBe(true);
		oldRequest.reject();
		await oldInstall;

		// Assert
		expect(store.presentation.candidate?.identity).toEqual(CANDIDATE);
		expect(store.discards).toEqual([CANDIDATE.publicationId]);
	});

	test('retains an installed active bank and automatically retries only its failed receipt', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new ImmediateInstallationPort(['admitted'], 1);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});

		// Act
		await gate.handleCandidateReady(candidateReady(CANDIDATE, 'ordinary', []), attention([]));

		// Assert
		expect(store.presentation.activeIdentity).toEqual(CANDIDATE);
		expect(port.receiptAttempts).toEqual([CANDIDATE.publicationId, CANDIDATE.publicationId]);
		expect(port.receipts).toEqual([CANDIDATE.publicationId]);
		expect(port.replacementRequestCount).toBe(0);
	});

	test('requests worker recovery after one exact receipt retry fails', async () => {
		// Arrange
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new ImmediateInstallationPort(['admitted'], 10);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});

		// Act
		await gate.handleCandidateReady(candidateReady(CANDIDATE, 'ordinary', []), attention([]));

		// Assert — bounded attempts retain the displayed bank and delegate recovery to the pane service.
		expect(port.receiptAttempts).toEqual([CANDIDATE.publicationId, CANDIDATE.publicationId]);
		expect(port.replacementRequestCount).toBe(1);
		expect(port.replacementSource).toBe('reviewInstalledReceiptFailed');
		expect(store.presentation.activeIdentity).toEqual(CANDIDATE);
	});

	test('page that applied B blocks C admission until the B receipt settles', async () => {
		const store = new FakeCandidateStore(ACTIVE, CANDIDATE);
		const port = new ImmediateInstallationPort(['admitted', 'admitted']);
		const receiptEntered = createBridgeProductDeferred<void>();
		const receiptSettlement = createBridgeProductDeferred<void>();
		const sendReceipt = port.sendInstalledReceipt;
		port.sendInstalledReceipt = async (installedIdentity): Promise<void> => {
			if (installedIdentity.publicationId === CANDIDATE.publicationId) {
				receiptEntered.resolve();
				await receiptSettlement.promise;
			}
			await sendReceipt(installedIdentity);
		};
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: port,
			store,
		});
		try {
			const firstInstall = gate.handleCandidateReady(
				candidateReady(CANDIDATE, 'ordinary', []),
				attention([]),
			);
			await receiptEntered.promise;
			expect(store.presentation.activeIdentity).toEqual(CANDIDATE);
			store.replaceCandidate(SUCCESSOR);
			await gate.handleCandidateReady(candidateReady(SUCCESSOR, 'ordinary', []), attention([]));
			expect(port.requests).toHaveLength(1);
			expect(store.presentation.activeIdentity).toEqual(CANDIDATE);
			receiptSettlement.resolve();
			await firstInstall;
			expect(port.requests[1]).toEqual({
				candidatePublicationId: SUCCESSOR.publicationId,
				expectedDisplayedPublicationId: CANDIDATE.publicationId,
			});
			expect(store.presentation.activeIdentity).toEqual(SUCCESSOR);
		} finally {
			receiptSettlement.resolve();
			gate.close();
		}
	});

	test('retains only affected promoted failure and ignores stale B failure after C starts', async () => {
		const store = new FakeCandidateStore(
			ACTIVE,
			CANDIDATE,
			sameSourceStart({ kind: 'promoted', reason: 'files' }, ['file-b']),
		);
		const gate = createBridgeMainReviewPresentationInstallationGate({
			installationPort: new ImmediateInstallationPort([]),
			store,
		});
		store.replaceCandidate(SUCCESSOR, sameSourceStart({ kind: 'promoted', reason: 'unknown' }, []));

		gate.handleCandidateFailed(candidateFailed(CANDIDATE, true), attention(['file-b']));
		expect(store.presentation.candidate?.identity).toEqual(SUCCESSOR);
		expect(store.presentation.failure).toBeNull();

		gate.handleCandidateFailed(candidateFailed(SUCCESSOR, true), attention(['any-file']));
		expect(store.presentation.candidate).toBeNull();
		expect(store.presentation.failure).toMatchObject({
			identity: SUCCESSOR,
			presentationClass: { kind: 'promoted', reason: 'unknown' },
			retryable: true,
		});

		await gate.semanticAttentionChanged(attention([]));
		expect(store.presentation.failure).toBeNull();
	});

	test('keeps ordinary and replacement candidate failure off the global presentation', () => {
		for (const startDisposition of [
			sameSourceStart({ kind: 'ordinary' }, ['file-b']),
			{ kind: 'replacement' as const },
		]) {
			const store = new FakeCandidateStore(ACTIVE, CANDIDATE, startDisposition);
			const gate = createBridgeMainReviewPresentationInstallationGate({
				installationPort: new ImmediateInstallationPort([]),
				store,
			});
			gate.handleCandidateFailed(candidateFailed(CANDIDATE, true), attention(['file-b']));
			expect(store.presentation.candidate).toBeNull();
			expect(store.presentation.failure).toBeNull();
		}
	});
});
