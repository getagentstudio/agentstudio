import {
	recordBridgeCommWorkerTaskTelemetry,
	type BridgeCommWorkerTelemetryRecorder,
} from './bridge-comm-worker-telemetry.js';

export type BridgeWorkerContentPreparationRank =
	| 'selected'
	| 'visible'
	| 'nearby'
	| 'speculative'
	| 'background';

export interface BridgeWorkerContentPreparationContext {
	readonly elapsedMs: number;
	readonly maxSliceMs: number;
	readonly remainingBudgetMs: number;
	readonly shouldYield: () => boolean;
}

export interface BridgeWorkerContentPreparationResult {
	readonly complete: boolean;
	readonly continuation?: 'pump' | 'external';
}

export interface BridgeWorkerContentPreparationTelemetry {
	readonly payloadClass?: string;
	readonly sourceEpoch?: number;
	readonly workKind: string;
}

export interface BridgeWorkerContentPreparationWork {
	readonly id: string;
	readonly rank: BridgeWorkerContentPreparationRank;
	readonly telemetry?: BridgeWorkerContentPreparationTelemetry;
	readonly runSlice: (
		context: BridgeWorkerContentPreparationContext,
	) => BridgeWorkerContentPreparationResult;
}

export interface CreateWorkerContentPreparationPumpProps {
	readonly maxSliceMs: number;
	readonly now?: () => number;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}

export interface WorkerContentPreparationPumpRunResult {
	readonly completedIds: readonly string[];
	readonly yielded: boolean;
}

export interface WorkerContentPreparationPump {
	readonly enqueue: (work: BridgeWorkerContentPreparationWork) => void;
	readonly enqueueOrPromote: (work: BridgeWorkerContentPreparationWork) => void;
	readonly cancel: (workId: string) => void;
	readonly runUntilBudget: () => WorkerContentPreparationPumpRunResult;
	readonly getPendingWorkIds: () => readonly string[];
}

const BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER: Readonly<
	Record<BridgeWorkerContentPreparationRank, number>
> = {
	selected: 0,
	visible: 1,
	nearby: 2,
	speculative: 3,
	background: 4,
};

export const BRIDGE_WORKER_CONTENT_PREPARATION_MAX_SLICE_MS = 8;
const BRIDGE_WORKER_CONTENT_PREPARATION_DEFAULT_MAXIMUM_PRIORITY_BYPASSES = 8;

export function createWorkerContentPreparationPump(
	props: CreateWorkerContentPreparationPumpProps,
): WorkerContentPreparationPump {
	assertBridgeWorkerContentPreparationPumpConfiguration(props);
	const now = props.now ?? performance.now.bind(performance);
	const pendingWorkById = new Map<string, BridgeWorkerContentPreparationWork>();
	const enqueuedAtMillisecondsByWorkId = new Map<string, number>();
	const priorityBypassesByWorkId = new Map<string, number>();
	const taskTelemetryByWorkId = new Map<
		string,
		{
			durationMilliseconds: number;
			queueWaitMilliseconds: number;
			work: BridgeWorkerContentPreparationWork;
		}
	>();
	const finishTaskTelemetry = (
		work: BridgeWorkerContentPreparationWork,
		durationMilliseconds: number,
		queueWaitMilliseconds: number,
		result: 'cancelled' | 'failed' | 'success',
	): void => {
		recordBridgeCommWorkerTaskTelemetry({
			durationMilliseconds,
			lane: work.rank,
			queueWaitMilliseconds,
			result,
			taskKind: 'content_preparation',
			...(work.telemetry?.payloadClass === undefined
				? {}
				: { payloadClass: work.telemetry.payloadClass }),
			...(work.telemetry?.sourceEpoch === undefined
				? {}
				: { sourceEpoch: work.telemetry.sourceEpoch }),
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
			...(work.telemetry?.workKind === undefined ? {} : { workKind: work.telemetry.workKind }),
		});
	};

	return {
		enqueue: (work: BridgeWorkerContentPreparationWork): void => {
			enqueueOrPromoteBridgeWorkerPreparationWork({
				enqueuedAtMillisecondsByWorkId,
				now,
				pendingWorkById,
				priorityBypassesByWorkId,
				work,
			});
		},
		enqueueOrPromote: (work: BridgeWorkerContentPreparationWork): void => {
			enqueueOrPromoteBridgeWorkerPreparationWork({
				enqueuedAtMillisecondsByWorkId,
				now,
				pendingWorkById,
				priorityBypassesByWorkId,
				work,
			});
		},
		cancel: (workId: string): void => {
			const taskTelemetry = taskTelemetryByWorkId.get(workId);
			const pendingWork = pendingWorkById.get(workId);
			if (taskTelemetry !== undefined) {
				finishTaskTelemetry(
					taskTelemetry.work,
					taskTelemetry.durationMilliseconds,
					taskTelemetry.queueWaitMilliseconds,
					'cancelled',
				);
			} else if (pendingWork !== undefined) {
				finishTaskTelemetry(
					pendingWork,
					0,
					Math.max(0, now() - (enqueuedAtMillisecondsByWorkId.get(workId) ?? now())),
					'cancelled',
				);
			}
			taskTelemetryByWorkId.delete(workId);
			pendingWorkById.delete(workId);
			enqueuedAtMillisecondsByWorkId.delete(workId);
			priorityBypassesByWorkId.delete(workId);
		},
		runUntilBudget: (): WorkerContentPreparationPumpRunResult => {
			const startedAtMs = now();
			const completedIds: string[] = [];
			while (pendingWorkById.size > 0) {
				const elapsedMs = now() - startedAtMs;
				const work = takeNextBridgeWorkerPreparationWork({
					pendingWorkById,
					priorityBypassesByWorkId,
				});
				const sliceStartedAtMilliseconds = now();
				const remainingBudgetMs = Math.max(0, props.maxSliceMs - elapsedMs);
				const queueWaitMilliseconds =
					sliceStartedAtMilliseconds -
					(enqueuedAtMillisecondsByWorkId.get(work.id) ?? sliceStartedAtMilliseconds);
				enqueuedAtMillisecondsByWorkId.delete(work.id);
				const taskTelemetry = taskTelemetryByWorkId.get(work.id) ?? {
					durationMilliseconds: 0,
					queueWaitMilliseconds,
					work,
				};
				taskTelemetry.work = work;
				taskTelemetryByWorkId.set(work.id, taskTelemetry);
				let result: BridgeWorkerContentPreparationResult;
				try {
					result = work.runSlice({
						elapsedMs,
						maxSliceMs: remainingBudgetMs,
						remainingBudgetMs,
						shouldYield: (): boolean => now() - sliceStartedAtMilliseconds >= remainingBudgetMs,
					});
				} catch (error) {
					taskTelemetry.durationMilliseconds += now() - sliceStartedAtMilliseconds;
					finishTaskTelemetry(
						work,
						taskTelemetry.durationMilliseconds,
						taskTelemetry.queueWaitMilliseconds,
						'failed',
					);
					taskTelemetryByWorkId.delete(work.id);
					throw error;
				}
				taskTelemetry.durationMilliseconds += now() - sliceStartedAtMilliseconds;
				if (result.complete) {
					completedIds.push(work.id);
					finishTaskTelemetry(
						work,
						taskTelemetry.durationMilliseconds,
						taskTelemetry.queueWaitMilliseconds,
						'success',
					);
					taskTelemetryByWorkId.delete(work.id);
				} else if (result.continuation !== 'external') {
					enqueueOrPromoteBridgeWorkerPreparationWork({
						enqueuedAtMillisecondsByWorkId,
						now,
						pendingWorkById,
						priorityBypassesByWorkId,
						work,
					});
				}
				if (pendingWorkById.size > 0 && now() - startedAtMs >= props.maxSliceMs) {
					return {
						completedIds,
						yielded: true,
					};
				}
			}
			return {
				completedIds,
				yielded: false,
			};
		},
		getPendingWorkIds: (): readonly string[] => [...pendingWorkById.keys()],
	};
}

function enqueueOrPromoteBridgeWorkerPreparationWork(props: {
	readonly enqueuedAtMillisecondsByWorkId: Map<string, number>;
	readonly now: () => number;
	readonly pendingWorkById: Map<string, BridgeWorkerContentPreparationWork>;
	readonly priorityBypassesByWorkId: Map<string, number>;
	readonly work: BridgeWorkerContentPreparationWork;
}): void {
	const existingWork = props.pendingWorkById.get(props.work.id);
	if (existingWork === undefined) {
		props.enqueuedAtMillisecondsByWorkId.set(props.work.id, props.now());
		props.pendingWorkById.set(props.work.id, props.work);
		props.priorityBypassesByWorkId.set(props.work.id, 0);
		return;
	}
	const promotedRank = chooseHigherPriorityBridgeWorkerPreparationRank(
		existingWork.rank,
		props.work.rank,
	);
	if (promotedRank !== existingWork.rank) {
		props.enqueuedAtMillisecondsByWorkId.set(props.work.id, props.now());
		props.priorityBypassesByWorkId.set(props.work.id, 0);
	}
	props.pendingWorkById.set(props.work.id, {
		...existingWork,
		rank: promotedRank,
	});
}

function chooseHigherPriorityBridgeWorkerPreparationRank(
	leftRank: BridgeWorkerContentPreparationRank,
	rightRank: BridgeWorkerContentPreparationRank,
): BridgeWorkerContentPreparationRank {
	return BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER[leftRank] <=
		BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER[rightRank]
		? leftRank
		: rightRank;
}

function takeNextBridgeWorkerPreparationWork(props: {
	readonly pendingWorkById: Map<string, BridgeWorkerContentPreparationWork>;
	readonly priorityBypassesByWorkId: Map<string, number>;
}): BridgeWorkerContentPreparationWork {
	let bestId: string | null = null;
	let bestRank = Number.POSITIVE_INFINITY;
	let starvedId: string | null = null;
	let starvedBypassCount = Number.NEGATIVE_INFINITY;
	for (const [workId, work] of props.pendingWorkById.entries()) {
		const rank = BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER[work.rank];
		if (rank < bestRank) {
			bestId = workId;
			bestRank = rank;
		}
		const bypassCount = props.priorityBypassesByWorkId.get(workId) ?? 0;
		if (
			bypassCount >= BRIDGE_WORKER_CONTENT_PREPARATION_DEFAULT_MAXIMUM_PRIORITY_BYPASSES &&
			bypassCount > starvedBypassCount
		) {
			starvedId = workId;
			starvedBypassCount = bypassCount;
		}
	}
	const selectedId = starvedId ?? bestId;
	if (selectedId === null) {
		throw new Error('Bridge worker content preparation queue is empty.');
	}
	const work = props.pendingWorkById.get(selectedId);
	props.pendingWorkById.delete(selectedId);
	props.priorityBypassesByWorkId.delete(selectedId);
	if (work === undefined) {
		throw new Error('Bridge worker content preparation queue lost its selected work item.');
	}
	const selectedRank = BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER[work.rank];
	for (const [workId, pendingWork] of props.pendingWorkById.entries()) {
		if (BRIDGE_WORKER_CONTENT_PREPARATION_RANK_ORDER[pendingWork.rank] <= selectedRank) continue;
		props.priorityBypassesByWorkId.set(
			workId,
			(props.priorityBypassesByWorkId.get(workId) ?? 0) + 1,
		);
	}
	return work;
}

function assertBridgeWorkerContentPreparationPumpConfiguration(
	props: CreateWorkerContentPreparationPumpProps,
): void {
	if (
		!Number.isFinite(props.maxSliceMs) ||
		props.maxSliceMs <= 0 ||
		props.maxSliceMs > BRIDGE_WORKER_CONTENT_PREPARATION_MAX_SLICE_MS
	) {
		throw new Error(
			'Bridge worker content preparation slices must be greater than zero and at most 8 ms.',
		);
	}
}
