// oxlint-disable unicorn/require-post-message-target-origin -- WorkerGlobalScope.postMessage does not accept targetOrigin.
import type {
	BridgeTelemetryProducerId,
	BridgeTelemetryProducerInstallation,
	BridgeTelemetryWorkerBatchTransport,
	BridgeTelemetryWorkerBootstrap,
	BridgeTelemetryWorkerControlResponse,
	BridgeTelemetryWorkerDrainResult,
	BridgeTelemetryWorkerIngressResult,
	BridgeTelemetryWorkerProducerCreditGrant,
	BridgeTelemetryWorkerProducerCommand,
	BridgeTelemetryWorkerRuntime,
} from './bridge-telemetry-worker-contracts.js';
import {
	bridgeTelemetryWorkerControlRequestSchema,
	bridgeTelemetryWorkerInstallSchema,
} from './bridge-telemetry-worker-contracts.js';
import { createBridgeTelemetryWorkerRuntime } from './bridge-telemetry-worker-factory.js';
import { createBridgeTelemetryWorkerFetchTransport } from './bridge-telemetry-worker-transport.js';

export type BridgeTelemetryWorkerPortReply =
	| {
			readonly type: 'producer.ingress-result';
			readonly result: BridgeTelemetryWorkerIngressResult;
	  }
	| BridgeTelemetryWorkerProducerCreditGrant
	| BridgeTelemetryWorkerProducerCommand;

export type BridgeTelemetryWorkerFlushScheduler = (
	callback: () => Promise<void>,
	delayMilliseconds: number,
) => void;

export interface BridgeTelemetryWorkerPortHost {
	readonly runtime: BridgeTelemetryWorkerRuntime;
	readonly replaceProducer: (
		producerId: BridgeTelemetryProducerId,
		port: MessagePort,
	) => Promise<void>;
	readonly drain: () => Promise<BridgeTelemetryWorkerDrainResult>;
	readonly drainAndClose: () => Promise<BridgeTelemetryWorkerDrainResult>;
	readonly dispose: () => void;
}

export interface CreateBridgeTelemetryWorkerPortHostProps {
	readonly bootstrap: BridgeTelemetryWorkerBootstrap;
	readonly transport: BridgeTelemetryWorkerBatchTransport;
	readonly mainPort: MessagePort;
	readonly commPort: MessagePort;
	readonly scheduleFlush?: BridgeTelemetryWorkerFlushScheduler;
	readonly scheduleLifecycleTimeout?: (
		callback: () => void,
		delayMilliseconds: number,
	) => () => void;
}

export type BridgeTelemetryWorkerHealthMessage = {
	readonly type: 'telemetry.health';
	readonly status: 'ready' | 'degraded';
	readonly message: string;
};

export interface BridgeTelemetryWorkerGlobalScope {
	readonly postMessage: (
		message: BridgeTelemetryWorkerHealthMessage | BridgeTelemetryWorkerControlResponse,
		transfer?: readonly Transferable[],
	) => void;
	readonly addEventListener: (
		type: 'message',
		listener: (event: MessageEvent<unknown>) => void,
	) => void;
}

export interface BridgeTelemetryWorkerEntryDependencies {
	readonly createTransport: (
		bootstrap: BridgeTelemetryWorkerBootstrap,
	) => BridgeTelemetryWorkerBatchTransport;
}

export function createBridgeTelemetryWorkerPortHost(
	props: CreateBridgeTelemetryWorkerPortHostProps,
): BridgeTelemetryWorkerPortHost {
	const runtime = createBridgeTelemetryWorkerRuntime({
		bootstrap: props.bootstrap,
		transport: props.transport,
	});
	if (runtime === null) {
		throw new Error('Telemetry worker port host requires enabled telemetry');
	}
	const enabledRuntime: BridgeTelemetryWorkerRuntime = runtime;
	const activePorts = new Map<BridgeTelemetryProducerId, MessagePort>();
	const scheduleFlush = props.scheduleFlush ?? defaultBridgeTelemetryWorkerFlushScheduler;
	const scheduleLifecycleTimeout =
		props.scheduleLifecycleTimeout ?? defaultBridgeTelemetryWorkerLifecycleTimeout;
	let hostState: 'active' | 'draining' | 'disposed' = 'active';
	let flushScheduledOrRunning = false;
	let activeFlush: Promise<void> | null = null;
	let nextBarrierSequence = 0;
	let producerBarrierWaiters: Array<{
		readonly isSatisfied: () => boolean;
		readonly resolve: () => void;
		readonly reject: (error: Error) => void;
	}> = [];
	let producerSettlementWaiters: Array<{
		readonly isSatisfied: () => boolean;
		readonly resolve: () => void;
		readonly reject: (error: Error) => void;
	}> = [];
	let lifecycleTail: Promise<void> = Promise.resolve();
	let pendingLifecycleCount = 0;
	installPort('main', props.mainPort, enabledRuntime.installProducer('main'));
	installPort('comm', props.commPort, enabledRuntime.installProducer('comm'));

	function installPort(
		producerId: BridgeTelemetryProducerId,
		port: MessagePort,
		installation: BridgeTelemetryProducerInstallation,
	): void {
		activePorts.get(producerId)?.close();
		activePorts.set(producerId, port);
		port.addEventListener('message', (event: MessageEvent<unknown>): void => {
			void enabledRuntime.acceptProducerMessage(installation, event.data).then((result): void => {
				resolveProducerBarrierWaitersIfSatisfied();
				resolveProducerSettlementWaitersIfSatisfied();
				if (hostState !== 'active') {
					return;
				}
				port.postMessage({
					type: 'producer.ingress-result',
					result,
				} satisfies BridgeTelemetryWorkerPortReply);
				publishProducerCreditGrants();
				if (result.type === 'accepted' && result.buffered) {
					schedulePolicyFlush();
				}
			});
		});
		port.start();
	}

	function publishProducerCreditGrants(): void {
		const sampleGrants = enabledRuntime.takeProducerCreditGrants();
		const controlGrants = enabledRuntime.takeProducerControlCreditGrants();
		for (const producerId of ['main', 'comm'] as const) {
			const port = activePorts.get(producerId);
			if (port === undefined) {
				continue;
			}
			if (sampleGrants[producerId] > 0) {
				port.postMessage({
					type: 'producer.credit-grant',
					sampleCredits: sampleGrants[producerId],
				} satisfies BridgeTelemetryWorkerPortReply);
			}
			if (controlGrants[producerId] > 0) {
				port.postMessage({
					type: 'producer.credit-grant',
					controlCredits: controlGrants[producerId],
				} satisfies BridgeTelemetryWorkerPortReply);
			}
		}
	}

	function schedulePolicyFlush(): void {
		if (hostState !== 'active' || flushScheduledOrRunning) {
			return;
		}
		flushScheduledOrRunning = true;
		scheduleFlush(async (): Promise<void> => {
			if (hostState !== 'active') {
				flushScheduledOrRunning = false;
				return;
			}
			const flush = enabledRuntime.flush();
			activeFlush = flush;
			try {
				await flush;
				if (hostState === 'active') {
					publishProducerCreditGrants();
				}
			} finally {
				activeFlush = null;
				flushScheduledOrRunning = false;
			}
			const snapshot = enabledRuntime.snapshot();
			if (
				hostState === 'active' &&
				(snapshot.bufferedSampleCount > 0 || snapshot.bufferedBytes > 0)
			) {
				schedulePolicyFlush();
			}
		}, props.bootstrap.policy.minimumFlushIntervalMilliseconds);
	}

	function producerBarriersAreSatisfied(
		producerIds: readonly BridgeTelemetryProducerId[],
	): boolean {
		const producers = enabledRuntime.snapshot().producers;
		return producerIds.every(
			(producerId) =>
				producers[producerId]?.barrierHighWatermark !== null &&
				producers[producerId]?.barrierHighWatermark !== undefined,
		);
	}

	function resolveProducerBarrierWaitersIfSatisfied(): void {
		const pending: typeof producerBarrierWaiters = [];
		for (const waiter of producerBarrierWaiters) {
			if (waiter.isSatisfied()) {
				waiter.resolve();
			} else {
				pending.push(waiter);
			}
		}
		producerBarrierWaiters = pending;
	}

	function waitForProducerBarriers(
		producerIds: readonly BridgeTelemetryProducerId[],
	): Promise<void> {
		const isSatisfied = (): boolean => producerBarriersAreSatisfied(producerIds);
		if (isSatisfied()) {
			return Promise.resolve();
		}
		return new Promise((resolve, reject) => {
			producerBarrierWaiters.push({ isSatisfied, resolve, reject });
		});
	}

	function producerSettlementsAreSatisfied(
		producerIds: readonly BridgeTelemetryProducerId[],
	): boolean {
		return producerIds.every(enabledRuntimeSettlementReceived);
	}

	function enabledRuntimeSettlementReceived(producerId: BridgeTelemetryProducerId): boolean {
		return enabledRuntime.producerSettlementReceived(producerId);
	}

	function resolveProducerSettlementWaitersIfSatisfied(): void {
		const pending: typeof producerSettlementWaiters = [];
		for (const waiter of producerSettlementWaiters) {
			if (waiter.isSatisfied()) {
				waiter.resolve();
			} else {
				pending.push(waiter);
			}
		}
		producerSettlementWaiters = pending;
	}

	function waitForProducerSettlements(
		producerIds: readonly BridgeTelemetryProducerId[],
	): Promise<void> {
		const isSatisfied = (): boolean => producerSettlementsAreSatisfied(producerIds);
		if (isSatisfied()) {
			return Promise.resolve();
		}
		return new Promise((resolve, reject) => {
			producerSettlementWaiters.push({ isSatisfied, resolve, reject });
		});
	}

	function beginProducerBarriers(
		producerIds: readonly BridgeTelemetryProducerId[],
	): Map<BridgeTelemetryProducerId, string> {
		const barrierIds = new Map<BridgeTelemetryProducerId, string>();
		for (const producerId of producerIds) {
			nextBarrierSequence += 1;
			const barrierId = `telemetry-barrier-${nextBarrierSequence.toString(36)}`;
			const installation = enabledRuntime.prepareProducerBarrier(producerId, barrierId);
			barrierIds.set(producerId, barrierId);
			activePorts.get(producerId)?.postMessage({
				type: 'producer.barrier.request',
				barrierId,
				generation: installation.generation,
			} satisfies BridgeTelemetryWorkerProducerCommand);
		}
		return barrierIds;
	}

	function beginProducerSettlements(
		barrierIds: ReadonlyMap<BridgeTelemetryProducerId, string>,
		disposition: 'close' | 'reopen',
	): void {
		for (const producerId of ['main', 'comm'] as const) {
			const barrierId = barrierIds.get(producerId);
			const producer = enabledRuntime.snapshot().producers[producerId];
			if (barrierId === undefined || producer === null) {
				throw new Error(`Telemetry producer settlement is missing ${producerId}`);
			}
			enabledRuntime.prepareProducerSettlement(producerId, barrierId);
			activePorts.get(producerId)?.postMessage({
				type: 'producer.settlement.request',
				barrierId,
				generation: producer.generation,
				disposition,
				sampleCredits: 0,
				controlCredits: 0,
			} satisfies BridgeTelemetryWorkerProducerCommand);
		}
	}

	function grantInitialProducerCreditsAfterReopen(): void {
		for (const producerId of ['main', 'comm'] as const) {
			const port = activePorts.get(producerId);
			if (port === undefined) continue;
			port.postMessage({
				type: 'producer.credit-grant',
				sampleCredits: props.bootstrap.policy.initialSampleCredits,
			} satisfies BridgeTelemetryWorkerPortReply);
			port.postMessage({
				type: 'producer.credit-grant',
				controlCredits: props.bootstrap.policy.initialControlCredits,
			} satisfies BridgeTelemetryWorkerPortReply);
		}
	}

	function enqueueLifecycle<TResult>(operation: () => Promise<TResult>): Promise<TResult> {
		pendingLifecycleCount += 1;
		const result = lifecycleTail.then(operation, operation);
		lifecycleTail = result.then(
			(): void => {},
			(): void => {},
		);
		void result.then(
			(): void => {
				pendingLifecycleCount -= 1;
			},
			(): void => {
				pendingLifecycleCount -= 1;
			},
		);
		return result;
	}

	function withLifecycleTimeout<TResult>(
		operation: Promise<TResult>,
		message: string,
		onTimeout: (error: Error) => void,
	): Promise<TResult> {
		return new Promise((resolve, reject): void => {
			const cancelTimeout = scheduleLifecycleTimeout((): void => {
				const error = new Error(message);
				onTimeout(error);
				reject(error);
			}, props.bootstrap.policy.drainTimeoutMilliseconds);
			void operation.then(
				(value): void => {
					cancelTimeout();
					resolve(value);
				},
				(error: unknown): void => {
					cancelTimeout();
					reject(error instanceof Error ? error : new Error(message));
				},
			);
		});
	}

	function rejectBarrierWaiters(error: Error): void {
		for (const waiter of producerBarrierWaiters) {
			waiter.reject(error);
		}
		producerBarrierWaiters = [];
	}

	function rejectSettlementWaiters(error: Error): void {
		for (const waiter of producerSettlementWaiters) {
			waiter.reject(error);
		}
		producerSettlementWaiters = [];
	}

	async function performDrain(closeAfterDrain: boolean): Promise<BridgeTelemetryWorkerDrainResult> {
		if (hostState === 'disposed') {
			throw new Error('Telemetry worker port host was disposed.');
		}
		hostState = 'draining';
		if (activeFlush !== null) {
			await activeFlush;
		}
		const barrierIds = beginProducerBarriers(['main', 'comm']);
		await waitForProducerBarriers(['main', 'comm']);
		await enabledRuntime.drainBufferedForSettlement();
		beginProducerSettlements(barrierIds, closeAfterDrain ? 'close' : 'reopen');
		await waitForProducerSettlements(['main', 'comm']);
		const finalResult = enabledRuntime.finishDrain(closeAfterDrain);
		if (closeAfterDrain) {
			for (const port of activePorts.values()) {
				port.close();
			}
			activePorts.clear();
			hostState = 'disposed';
		} else {
			hostState = 'active';
			grantInitialProducerCreditsAfterReopen();
		}
		return finalResult;
	}

	return {
		runtime: enabledRuntime,
		replaceProducer: async (producerId, port): Promise<void> => {
			if (hostState !== 'active' || pendingLifecycleCount > 0) {
				port.close();
				throw new Error('Telemetry producer replacement requires an idle active host.');
			}
			const oldPort = activePorts.get(producerId);
			if (oldPort !== undefined) {
				const barrierIds = beginProducerBarriers([producerId]);
				try {
					await withLifecycleTimeout(
						waitForProducerBarriers([producerId]),
						`Telemetry producer ${producerId} replacement barrier timed out.`,
						rejectBarrierWaiters,
					);
				} catch {
					enabledRuntime.failProof();
				}
				const barrierId = barrierIds.get(producerId);
				if (
					barrierId !== undefined &&
					enabledRuntime.snapshot().producers[producerId]?.barrierHighWatermark !== null
				) {
					enabledRuntime.prepareProducerSettlement(producerId, barrierId);
					const producer = enabledRuntime.snapshot().producers[producerId];
					if (producer !== null) {
						oldPort.postMessage({
							type: 'producer.settlement.request',
							barrierId,
							generation: producer.generation,
							disposition: 'close',
							sampleCredits: 0,
							controlCredits: 0,
						} satisfies BridgeTelemetryWorkerProducerCommand);
						try {
							await withLifecycleTimeout(
								waitForProducerSettlements([producerId]),
								`Telemetry producer ${producerId} replacement settlement timed out.`,
								rejectSettlementWaiters,
							);
						} catch {
							enabledRuntime.failProof();
						}
					}
				}
			}
			installPort(producerId, port, enabledRuntime.replaceProducer(producerId));
		},
		drain: (): Promise<BridgeTelemetryWorkerDrainResult> =>
			enqueueLifecycle(() => performDrain(false)),
		drainAndClose: (): Promise<BridgeTelemetryWorkerDrainResult> =>
			enqueueLifecycle(() => performDrain(true)),
		dispose: (): void => {
			hostState = 'disposed';
			const disposalError = new Error('Telemetry worker port host was disposed.');
			for (const waiter of producerBarrierWaiters) {
				waiter.reject(disposalError);
			}
			producerBarrierWaiters = [];
			for (const waiter of producerSettlementWaiters) {
				waiter.reject(disposalError);
			}
			producerSettlementWaiters = [];
			for (const port of activePorts.values()) {
				port.close();
			}
			activePorts.clear();
		},
	};
}

const defaultBridgeTelemetryWorkerFlushScheduler: BridgeTelemetryWorkerFlushScheduler = (
	callback,
	delayMilliseconds,
): void => {
	globalThis.setTimeout((): void => {
		void callback();
	}, delayMilliseconds);
};

const defaultBridgeTelemetryWorkerLifecycleTimeout = (
	callback: () => void,
	delayMilliseconds: number,
): (() => void) => {
	const timeout = globalThis.setTimeout(callback, delayMilliseconds);
	return (): void => globalThis.clearTimeout(timeout);
};

export function bootstrapBridgeTelemetryWorkerEntry(
	scope: BridgeTelemetryWorkerGlobalScope,
	dependencies: BridgeTelemetryWorkerEntryDependencies = defaultBridgeTelemetryWorkerEntryDependencies,
): void {
	let installedHost: BridgeTelemetryWorkerPortHost | null = null;
	let installedBootstrap: BridgeTelemetryWorkerBootstrap | null = null;
	scope.addEventListener('message', (event: MessageEvent<unknown>): void => {
		const decodedInstall = bridgeTelemetryWorkerInstallSchema.safeParse(event.data);
		if (decodedInstall.success) {
			if (installedHost !== null) {
				decodedInstall.data.mainPort.close();
				decodedInstall.data.commPort.close();
				scope.postMessage({
					type: 'telemetry.health',
					status: 'degraded',
					message: 'Telemetry worker was already installed.',
				});
				return;
			}
			installedHost = createBridgeTelemetryWorkerPortHost({
				bootstrap: decodedInstall.data.bootstrap,
				transport: dependencies.createTransport(decodedInstall.data.bootstrap),
				mainPort: decodedInstall.data.mainPort,
				commPort: decodedInstall.data.commPort,
			});
			installedBootstrap = decodedInstall.data.bootstrap;
			for (const producerPort of [decodedInstall.data.mainPort, decodedInstall.data.commPort]) {
				const producerId =
					producerPort === decodedInstall.data.mainPort ? ('main' as const) : ('comm' as const);
				const generation = installedHost.runtime.snapshot().producers[producerId]?.generation ?? 1;
				producerPort.postMessage({
					type: 'producer.ready',
					generation,
					initialSampleCredits: decodedInstall.data.bootstrap.policy.initialSampleCredits,
					initialControlCredits: decodedInstall.data.bootstrap.policy.initialControlCredits,
				} satisfies BridgeTelemetryWorkerPortReply);
			}
			scope.postMessage({
				type: 'telemetry.health',
				status: 'ready',
				message: 'Telemetry worker ready.',
			});
			return;
		}
		const decodedControl = bridgeTelemetryWorkerControlRequestSchema.safeParse(event.data);
		if (!decodedControl.success || installedHost === null || installedBootstrap === null) {
			scope.postMessage({
				type: 'telemetry.health',
				status: 'degraded',
				message: 'Telemetry worker requires a strict installed control request.',
			});
			return;
		}
		if (decodedControl.data.type === 'telemetry.snapshot') {
			scope.postMessage({
				type: 'telemetry.snapshot.result',
				requestId: decodedControl.data.requestId,
				snapshot: installedHost.runtime.snapshot(),
			});
			return;
		}
		if (decodedControl.data.type === 'telemetry.producer.replace') {
			const replacement = decodedControl.data;
			const bootstrap = installedBootstrap;
			void installedHost
				.replaceProducer(replacement.producerId, replacement.producerPort)
				.then((): void => {
					const generation =
						installedHost?.runtime.snapshot().producers[replacement.producerId]?.generation ?? 1;
					replacement.producerPort.postMessage({
						type: 'producer.ready',
						generation,
						initialSampleCredits: bootstrap.policy.initialSampleCredits,
						initialControlCredits: bootstrap.policy.initialControlCredits,
					} satisfies BridgeTelemetryWorkerPortReply);
					scope.postMessage({
						type: 'telemetry.producer.replaced',
						requestId: replacement.requestId,
						producerId: replacement.producerId,
					});
				})
				.catch((error: unknown): void => {
					replacement.producerPort.close();
					scope.postMessage({
						type: 'telemetry.health',
						status: 'degraded',
						message:
							error instanceof Error ? error.message : 'Telemetry producer replacement failed.',
					});
				});
			return;
		}
		const closesWorker = decodedControl.data.type === 'telemetry.drainAndClose';
		const drain = closesWorker ? installedHost.drainAndClose() : installedHost.drain();
		void drain.then((result): void => {
			scope.postMessage({
				type: closesWorker ? 'telemetry.drainedAndClosed' : 'telemetry.drained',
				requestId: decodedControl.data.requestId,
				result,
			});
		});
	});
}

const defaultBridgeTelemetryWorkerEntryDependencies: BridgeTelemetryWorkerEntryDependencies = {
	createTransport: (bootstrap) =>
		createBridgeTelemetryWorkerFetchTransport({ endpointUrl: bootstrap.endpointUrl }),
};

declare const self: BridgeTelemetryWorkerGlobalScope | undefined;

if (typeof self !== 'undefined' && typeof self.addEventListener === 'function') {
	bootstrapBridgeTelemetryWorkerEntry(self);
}
