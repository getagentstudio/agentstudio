import { onTestFinished } from 'vitest';

import { BridgeTestFactRecorder } from '../../../tests/test-support/bridge-test-fact-recorder.js';
import { encodeBridgeWorkerRenderDispositionCommand } from './bridge-comm-worker-protocol.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import type { createRecordingBridgeCommWorkerPort } from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductContentStream } from './bridge-product-transport-contract.js';
import type { BridgeWorkerServerToMainMessage } from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

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
	readonly facts: BridgeTestFactRecorder<ReviewPreparationObservation>;
	readonly scheduledDrains: BridgeCommWorkerPreparationDrain[];
	readonly schedule: (drain: BridgeCommWorkerPreparationDrain) => void;
	readonly beforePostMessage: (message: BridgeWorkerServerToMainMessage) => void;
	readonly contentOpened: (descriptorId: string) => void;
	readonly retryDeadlineRegistered: () => void;
	readonly close: (reason?: Error) => void;
}

export function createReviewPreparationObservations(): ReviewPreparationObservations {
	const facts = new BridgeTestFactRecorder<ReviewPreparationObservation>();
	const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
	let isClosed = false;
	const close = (reason = new Error('Review preparation observation closed.')): void => {
		isClosed = true;
		facts.close(reason);
	};
	onTestFinished((): void => close());
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
		close,
	};
}

export async function driveReviewPreparationUntil(props: {
	readonly hasExpectedEvent: () => boolean;
	readonly label?: string;
	readonly observations: ReviewPreparationObservations;
	readonly startIndex: number;
}): Promise<void> {
	let observationPosition = 0;
	const label = props.label ?? `Review preparation: ${props.hasExpectedEvent.toString()}`;
	let lastObserved = 'no owner facts';
	let completed = false;
	onTestFinished((context): void => {
		if (!completed && (context.signal.aborted || context.task.result?.state === 'fail'))
			console.info(`Awaiting ${label}; last observed ${lastObserved}`);
	});
	const drainTasks: ReturnType<BridgeCommWorkerPreparationDrain>[] = [];
	try {
		while (!props.hasExpectedEvent()) {
			// Each iteration consumes a distinct scheduled-drain or posted-message fact.
			// oxlint-disable-next-line no-await-in-loop -- A recorder observation is a protocol event, never a scheduler poll.
			const fact = await props.observations.facts.waitFor(
				(): boolean => true,
				label,
				++observationPosition,
			);
			lastObserved =
				fact.kind === 'drainScheduled'
					? `drainScheduled:${fact.index}`
					: fact.kind === 'messagePosted'
						? `messagePosted:${fact.message.kind}`
						: fact.kind;
			if (fact.kind !== 'drainScheduled' || fact.index < props.startIndex) continue;
			const task = fact.drain();
			// A drain can depend on a later scheduled drain: retain it, then keep driving events.
			void task.catch((error: unknown): void => {
				props.observations.close(error instanceof Error ? error : new Error(String(error)));
			});
			drainTasks.push(task);
		}
	} finally {
		await Promise.all(drainTasks);
	}
	completed = true;
}

export async function requirePreparationContinuationBeforeDrainCompletion(props: {
	readonly firstDrainCompletion: Promise<unknown>;
	readonly observations: ReviewPreparationObservations;
	readonly isContinuationScheduled: (fact: ReviewPreparationObservation) => boolean;
}): Promise<void> {
	let firstDrainFailure: Error | undefined;
	const firstDrainOutcome = props.firstDrainCompletion.then(
		(): { readonly kind: 'completed' } => ({ kind: 'completed' }),
		(error: unknown): { readonly error: Error; readonly kind: 'failed' } => {
			firstDrainFailure = error instanceof Error ? error : new Error(String(error));
			props.observations.close(firstDrainFailure);
			return { error: firstDrainFailure, kind: 'failed' };
		},
	);
	const continuationOutcome = props.observations.facts
		.waitFor(
			props.isContinuationScheduled,
			'Review preparation continuation scheduled before first drain completion',
		)
		.then(
			(): { readonly kind: 'scheduled' } => ({ kind: 'scheduled' }),
			(error: unknown): { readonly error: Error; readonly kind: 'failed' } => ({
				error: firstDrainFailure ?? (error instanceof Error ? error : new Error(String(error))),
				kind: 'failed',
			}),
		);
	const outcome = await Promise.race([firstDrainOutcome, continuationOutcome]);
	if (outcome.kind === 'failed') throw outcome.error;
	if (outcome.kind === 'completed')
		throw new Error('First preparation drain completed before its continuation was scheduled.');
}

export async function cleanupReviewPreparationFixtures(props: {
	readonly sources: readonly {
		readonly close: () => void;
		readonly pendingSourceInstallation: () => Promise<void> | null;
	}[];
	readonly observations: readonly { readonly close: () => void }[];
	readonly restore: () => void;
}): Promise<void> {
	try {
		const results = await Promise.allSettled(
			props.sources.map(async (source): Promise<void> => {
				source.close();
				const installation = source.pendingSourceInstallation();
				if (installation !== null) await installation;
			}),
		);
		const errors = results.flatMap((result): unknown[] =>
			result.status === 'rejected' ? [result.reason] : [],
		);
		if (errors.length === 1) throw errors[0];
		if (errors.length > 1)
			throw new AggregateError(errors, 'Review preparation installation cleanup failed.');
	} finally {
		try {
			for (const observation of props.observations) observation.close();
		} finally {
			props.restore();
		}
	}
}

export function queueLatestReviewPublication(
	dispatch: ReturnType<typeof createRecordingBridgeCommWorkerPort>['dispatch'],
	postedMessages: ReturnType<typeof createRecordingBridgeCommWorkerPort>['postedMessages'],
	requestLabel: string,
): void {
	const publication = postedMessages
		.flatMap((postedMessage) =>
			postedMessage.message.kind === 'reviewPierreRenderJob' ? [postedMessage.message] : [],
		)
		.at(-1);
	if (publication === undefined) throw new Error('Expected a Review publication to queue.');
	dispatch.message(
		encodeBridgeWorkerRenderDispositionCommand({
			epoch: publication.workerDerivationEpoch,
			receipts: [
				bridgeWorkerRenderDispositionReceiptSchema.parse({
					...publication.renderReceiptIdentity,
					disposition: 'queued',
					kind: 'render.disposition',
					receivedAtMilliseconds: 0,
				}),
			],
			requestId: `request-queue-${requestLabel}`,
		}),
	);
}

export function unexpectedEOFReviewContentStream(
	descriptorId: string,
): BridgeProductContentStream<'review.content'> {
	return {
		contentKind: 'review.content',
		contentRequestId: `unexpected-eof-${descriptorId}`,
		frames: emptyReviewContentFrames(),
		terminal: Promise.resolve({
			code: 'internal',
			contentKind: 'review.content',
			descriptorId,
			kind: 'error',
			retryable: true,
			safeMessage: 'Unexpected EOF while reading Review content.',
		}),
	};
}

async function* emptyReviewContentFrames(): AsyncIterable<never> {}
