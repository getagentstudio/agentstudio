import type { BridgeCommWorkerReviewRuntimeSource } from './bridge-comm-worker-review-source-diff.js';
import { registerTestBridgeCommWorkerRuntimePortProtocol as registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.fixture.test-support.js';
import { type BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	assertBridgeCommWorkerPreparationDrain,
	createBridgeCommWorkerReviewProductTestSource,
	flushBridgeWorkerRuntimeContinuations,
	type BridgeCommWorkerReviewProductTestSource,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeWorkerReviewContentOpen } from './bridge-worker-review-content-fetch.js';

export async function drainBridgeWorkerVisibleDemandRuntimeUntil(props: {
	readonly hasExpectedEvent: () => boolean;
	readonly scheduledDrains: readonly BridgeCommWorkerPreparationDrain[];
	readonly startIndex: number;
}): Promise<void> {
	let nextDrainIndex = props.startIndex;
	const activeDrainCompletions = new Set<ReturnType<BridgeCommWorkerPreparationDrain>>();
	let drainFailure: unknown = null;
	while (!props.hasExpectedEvent()) {
		await flushBridgeWorkerRuntimeContinuations();
		while (nextDrainIndex < props.scheduledDrains.length) {
			const drain = assertBridgeCommWorkerPreparationDrain(props.scheduledDrains[nextDrainIndex]);
			nextDrainIndex += 1;
			const completion = drain();
			activeDrainCompletions.add(completion);
			void completion.then(
				(): void => {
					activeDrainCompletions.delete(completion);
				},
				(error: unknown): void => {
					drainFailure = error;
					activeDrainCompletions.delete(completion);
				},
			);
		}
		if (drainFailure !== null) throw drainFailure;
		if (
			!props.hasExpectedEvent() &&
			activeDrainCompletions.size === 0 &&
			nextDrainIndex >= props.scheduledDrains.length
		) {
			throw new Error('Expected owned Bridge visible-demand work before the target event.');
		}
	}
}

export function createTrackedBridgeWorkerReviewContentOpen(
	openContent: BridgeWorkerReviewContentOpen,
): {
	readonly openContent: BridgeWorkerReviewContentOpen;
	readonly openedDescriptorIds: readonly string[];
	readonly pendingCompletions: () => readonly Promise<void>[];
} {
	const openedDescriptorIds: string[] = [];
	const pendingCompletions = new Set<Promise<void>>();
	return {
		openContent: (descriptor, abortSignal) => {
			openedDescriptorIds.push(descriptor.descriptorId);
			const stream = openContent(descriptor, abortSignal);
			const completion = stream.terminal.then((): void => {});
			pendingCompletions.add(completion);
			void completion.then(
				(): void => {
					pendingCompletions.delete(completion);
				},
				(): void => {
					pendingCompletions.delete(completion);
				},
			);
			return stream;
		},
		openedDescriptorIds,
		pendingCompletions: (): readonly Promise<void>[] => [...pendingCompletions],
	};
}

export async function drainBridgeWorkerVisibleDemandRuntimeUntilQuiescent(props: {
	readonly pendingContentCompletions: () => readonly Promise<void>[];
	readonly pendingPreparationWorkIds: () => readonly string[];
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
}): Promise<void> {
	const activeDrainCompletions = new Set<ReturnType<BridgeCommWorkerPreparationDrain>>();
	let drainFailure: unknown = null;
	for (;;) {
		await flushBridgeWorkerRuntimeContinuations();
		const drains = props.scheduledDrains.splice(0);
		for (const drain of drains) {
			const completion = drain();
			activeDrainCompletions.add(completion);
			void completion.then(
				(): void => {
					activeDrainCompletions.delete(completion);
				},
				(error: unknown): void => {
					drainFailure = error;
					activeDrainCompletions.delete(completion);
				},
			);
		}
		// A drain may start an async fetch whose external continuation schedules the next drain.
		// Observe that microtask-owned continuation before deciding the runtime is quiescent.
		// oxlint-disable-next-line no-await-in-loop -- Quiescence requires the post-drain continuation boundary.
		await flushBridgeWorkerRuntimeContinuations();
		const contentCompletions = props.pendingContentCompletions();
		if (drainFailure !== null) throw drainFailure;
		if (contentCompletions.length > 0) {
			// oxlint-disable-next-line no-await-in-loop -- Owned content terminals must settle before testing runtime quiescence.
			await Promise.all(contentCompletions);
			await flushBridgeWorkerRuntimeContinuations();
		}
		const pendingWorkIds = props.pendingPreparationWorkIds();
		if (
			props.scheduledDrains.length === 0 &&
			props.pendingContentCompletions().length === 0 &&
			pendingWorkIds.length === 0
		) {
			if (activeDrainCompletions.size > 0) {
				// oxlint-disable-next-line no-await-in-loop -- With no queued work, active owned drains must settle before the final quiescence check.
				await Promise.all(activeDrainCompletions);
			}
			await flushBridgeWorkerRuntimeContinuations();
			if (
				props.scheduledDrains.length === 0 &&
				props.pendingContentCompletions().length === 0 &&
				props.pendingPreparationWorkIds().length === 0 &&
				activeDrainCompletions.size === 0
			) {
				return;
			}
			continue;
		}
		if (
			drains.length === 0 &&
			props.scheduledDrains.length === 0 &&
			contentCompletions.length === 0 &&
			activeDrainCompletions.size === 0
		) {
			throw new Error(
				`Bridge visible-demand pump retained unscheduled work: ${pendingWorkIds.join(',')}`,
			);
		}
	}
}

type InitialReviewSource = Omit<BridgeCommWorkerReviewRuntimeSource, 'reviewPublicationIdentity'>;

export async function registerBridgeRuntimeWithInitialReviewSource(
	dispatch: {
		readonly message: (data: unknown) => void;
		readonly port: Parameters<typeof registerBridgeCommWorkerRuntimePortProtocol>[0];
	},
	props: Parameters<typeof registerBridgeCommWorkerRuntimePortProtocol>[1] & InitialReviewSource,
): Promise<BridgeCommWorkerReviewProductTestSource> {
	const {
		contentItems,
		contentRequestDescriptors,
		renderSemantics,
		rows,
		schedulePreparationDrain,
		...runtimeProps
	} = props;
	if (schedulePreparationDrain === undefined) {
		throw new Error('Expected a visible-demand test preparation scheduler.');
	}
	const initializationDrains: BridgeCommWorkerPreparationDrain[] = [];
	let isInitializingSource = true;
	const reviewProductSource = createBridgeCommWorkerReviewProductTestSource();
	registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
		...runtimeProps,
		productTransport: reviewProductSource.productTransport,
		schedulePreparationDrain: (drain): void => {
			if (isInitializingSource) {
				initializationDrains.push(drain);
				return;
			}
			schedulePreparationDrain(drain);
		},
	});
	activateBridgeCommWorkerReviewViewerMode(dispatch, 'initial-visible-demand-source');
	reviewProductSource.publishSource(
		{
			contentItems,
			contentRequestDescriptors,
			renderSemantics,
			rows,
		},
		4,
	);
	await flushBridgeWorkerRuntimeContinuations();
	for (let drainRound = 0; drainRound < 16; drainRound += 1) {
		for (const initializationDrain of initializationDrains.splice(0)) {
			void initializationDrain();
		}
		// oxlint-disable-next-line no-await-in-loop -- Each bounded round exposes source-reset continuation drains.
		await flushBridgeWorkerRuntimeContinuations();
		if (initializationDrains.length === 0) break;
	}
	if (initializationDrains.length > 0) {
		throw new Error('Visible-demand source initialization exceeded its bounded drain rounds.');
	}
	isInitializingSource = false;
	return reviewProductSource;
}
