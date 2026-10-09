import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';
import { BridgeProductTestFactRecorder } from './test-fixtures/bridge-product-test-fact-recorder.js';

type ReviewPreparationObservation =
	| {
			readonly kind: 'drainScheduled';
			readonly drain: BridgeCommWorkerPreparationDrain;
			readonly index: number;
	  }
	| { readonly kind: 'messagePosted'; readonly message: BridgeWorkerServerToMainMessage }
	| { readonly kind: 'contentOpened'; readonly descriptorId: string }
	| { readonly kind: 'retryDeadlineRegistered' };

export interface ReviewPreparationObservations {
	readonly facts: BridgeProductTestFactRecorder<ReviewPreparationObservation>;
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
	readonly schedule: (drain: BridgeCommWorkerPreparationDrain) => void;
	readonly beforePostMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly contentOpened: (descriptorId: string) => void;
	readonly retryDeadlineRegistered: () => void;
	readonly close: () => void;
}

export function createReviewPreparationObservations(): ReviewPreparationObservations {
	const facts = new BridgeProductTestFactRecorder<ReviewPreparationObservation>();
	const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
	let isClosed = false;
	return {
		facts,
		scheduledDrains,
		schedule: (drain): void => {
			if (isClosed) return;
			const index = scheduledDrains.length;
			scheduledDrains.push(drain);
			facts.record({ kind: 'drainScheduled', drain, index });
		},
		beforePostMessage: (message): void => {
			if (!isClosed) facts.record({ kind: 'messagePosted', message });
		},
		contentOpened: (descriptorId): void => {
			if (!isClosed) facts.record({ kind: 'contentOpened', descriptorId });
		},
		retryDeadlineRegistered: (): void => {
			if (!isClosed) facts.record({ kind: 'retryDeadlineRegistered' });
		},
		close: (): void => {
			isClosed = true;
			facts.close(new Error('Review preparation observation closed.'));
		},
	};
}

export async function driveReviewPreparationUntil(props: {
	readonly hasExpectedEvent: () => boolean;
	readonly observations: ReviewPreparationObservations;
	readonly startIndex: number;
}): Promise<void> {
	let observationPosition = 0;
	const drainTasks: ReturnType<BridgeCommWorkerPreparationDrain>[] = [];
	try {
		while (!props.hasExpectedEvent()) {
			// Each iteration consumes a distinct scheduled-drain or posted-message fact.
			// oxlint-disable-next-line no-await-in-loop -- A recorder observation is a protocol event, never a scheduler poll.
			const fact = await props.observations.facts.waitFor(
				(): boolean => true,
				++observationPosition,
			);
			if (fact.kind !== 'drainScheduled' || fact.index < props.startIndex) continue;
			const task = fact.drain();
			// A drain can depend on a later scheduled drain: retain it, then keep driving events.
			void task.catch((error: unknown): void => {
				props.observations.facts.close(error instanceof Error ? error : new Error(String(error)));
			});
			drainTasks.push(task);
		}
	} finally {
		await Promise.all(drainTasks);
	}
}
