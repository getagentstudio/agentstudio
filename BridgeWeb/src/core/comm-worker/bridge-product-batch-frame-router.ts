import {
	bridgeProductBatchDiagnostic,
	recordBridgeProductBatchDiagnostic,
	type BridgeProductBatchDiagnostic,
} from './bridge-product-batch-diagnostics.js';
import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	BridgeProductViewBatchReceiver,
	type BridgeProductViewInstallation,
} from './bridge-product-view-batch-receiver.js';
import type { BridgeProductViewAcknowledgementRequest } from './bridge-product-view-control-wire-contracts.js';

export interface BridgeProductBatchFrameSinks {
	readonly diagnostic?: (sample: BridgeProductBatchDiagnostic) => void;
	readonly subscriptionRetired?: (subscriptionId: string) => void;
	readonly verify?: (installation: BridgeProductViewInstallation) => void;
	readonly install: (installation: BridgeProductViewInstallation) => Promise<void> | void;
	readonly certifiedInstallCompleted?: (
		frame: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>,
	) => void;
	readonly receipt: (
		frame: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchPart' }>,
		through: number,
	) => void;
	readonly resnapshot: (frame: BridgeProductBatchFrame) => void;
	readonly resnapshotLatest: (subscriptionId: string, domain: string) => void;
	readonly snapshotBeginAccepted?: (
		frame: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>,
	) => boolean | void;
}

/** W4 routes certified installations; each application owns its typed install. */
export class BridgeProductBatchFrameRouter {
	readonly #deadlineClock: BridgeProductDeadlineClock;
	readonly #progressDeadlineMilliseconds: number;
	readonly #progressBySubscriptionId = new Map<
		string,
		Map<
			string,
			{
				readonly begin: Extract<
					BridgeProductBatchFrame,
					{ readonly kind: 'subscription.batchBegin' }
				>;
				readonly cancel: () => void;
			}
		>
	>();
	readonly #acceptedScopeBySubscriptionId = new Map<
		string,
		{
			readonly scope: Extract<
				BridgeProductBatchFrame,
				{ readonly kind: 'subscription.batchBegin' }
			>['scope'];
			readonly scopeRevision: number;
		}
	>();
	readonly #receiversBySubscriptionId = new Map<
		string,
		{
			readonly receiver: BridgeProductViewBatchReceiver;
			handle: string;
			readonly lastBeginByDomain: Map<
				string,
				Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>
			>;
			scopeRevision: number;
		}
	>();
	#sinks: BridgeProductBatchFrameSinks | null = null;

	constructor(props: {
		readonly deadlineClock: BridgeProductDeadlineClock;
		readonly progressDeadlineMilliseconds: number;
	}) {
		if (
			!Number.isSafeInteger(props.progressDeadlineMilliseconds) ||
			props.progressDeadlineMilliseconds <= 0
		)
			throw new Error('View batch progress deadline must be a positive safe integer.');
		this.#deadlineClock = props.deadlineClock;
		this.#progressDeadlineMilliseconds = props.progressDeadlineMilliseconds;
	}

	setSinks(sinks: BridgeProductBatchFrameSinks): void {
		this.#sinks = sinks;
	}

	acceptScope(props: {
		readonly scope: Extract<
			BridgeProductBatchFrame,
			{ readonly kind: 'subscription.batchBegin' }
		>['scope'];
		readonly scopeRevision: number;
		readonly subscriptionId: string;
	}): void {
		const accepted = this.#acceptedScopeBySubscriptionId.get(props.subscriptionId);
		if (accepted !== undefined && props.scopeRevision <= accepted.scopeRevision) return;
		this.#acceptedScopeBySubscriptionId.set(props.subscriptionId, {
			scope: props.scope,
			scopeRevision: props.scopeRevision,
		});
		const state = this.#receiversBySubscriptionId.get(props.subscriptionId);
		if (state === undefined || props.scopeRevision <= state.scopeRevision) return;
		const filterChanged = state.receiver.setScope(props.scope, props.scopeRevision);
		state.scopeRevision = props.scopeRevision;
		if (filterChanged) {
			this.#clearProgress(props.subscriptionId);
			state.lastBeginByDomain.clear();
		}
	}

	accept(frame: BridgeProductBatchFrame): void {
		const sinks = this.#sinks;
		if (sinks === null) throw new Error('Bridge product batch application owner is absent.');
		let state = this.#receiversBySubscriptionId.get(frame.subscriptionId);
		if (frame.kind === 'subscription.batchBegin') {
			if (state === undefined) {
				const acceptedScope = this.#acceptedScopeBySubscriptionId.get(frame.subscriptionId);
				const initialScope =
					acceptedScope !== undefined && acceptedScope.scopeRevision >= frame.scopeRevision
						? acceptedScope
						: { scope: frame.scope, scopeRevision: frame.scopeRevision };
				state = {
					receiver: new BridgeProductViewBatchReceiver({
						handle: frame.handle,
						scope: initialScope.scope,
						scopeRevision: initialScope.scopeRevision,
						subscriptionId: frame.subscriptionId,
						subscriptionKind: frame.subscriptionKind,
					}),
					handle: frame.handle,
					lastBeginByDomain: new Map(),
					scopeRevision: initialScope.scopeRevision,
				};
				this.#receiversBySubscriptionId.set(frame.subscriptionId, state);
			} else if (frame.handle !== state.handle) {
				this.#clearProgress(frame.subscriptionId);
				state.receiver.replaceHandle(frame.handle, frame.scope, frame.scopeRevision);
				state.lastBeginByDomain.clear();
				state.handle = frame.handle;
				state.scopeRevision = frame.scopeRevision;
			} else if (frame.scopeRevision > state.scopeRevision) {
				this.#clearProgress(frame.subscriptionId);
				state.receiver.setScope(frame.scope, frame.scopeRevision);
				state.lastBeginByDomain.clear();
				state.scopeRevision = frame.scopeRevision;
			}
			state.receiver.admitDomain(frame.domain, frame.incarnation);
		}
		if (state === undefined) {
			recordBridgeProductBatchDiagnostic(
				sinks.diagnostic,
				bridgeProductBatchDiagnostic({
					frame,
					step: 'receiverRejection',
					rejection: 'missingReceiver',
				}),
			);
			sinks.resnapshot(frame);
			return;
		}
		const alreadyStaged =
			frame.kind === 'subscription.batchPart' && state.receiver.hasStagedPart(frame);
		const verify = sinks.verify;
		const acceptance = state.receiver.accept(
			frame,
			verify === undefined
				? undefined
				: (installation): void => {
						try {
							verify(installation);
						} catch (error) {
							recordBridgeProductBatchDiagnostic(
								sinks.diagnostic,
								bridgeProductBatchDiagnostic({
									frame: installation.begin,
									step: 'payloadVerification',
									error,
								}),
							);
							throw error;
						}
					},
			(begin): boolean => sinks.snapshotBeginAccepted?.(begin) !== false,
		);
		const freshBegin =
			frame.kind === 'subscription.batchBegin' &&
			acceptance.kind === 'staged' &&
			(frame.mode !== 'snapshot' || acceptance.snapshotCause !== undefined);
		if (freshBegin && frame.kind === 'subscription.batchBegin') {
			state.lastBeginByDomain.set(frame.domain, frame);
		}
		if (acceptance.kind === 'resnapshot') {
			const tracked = this.#progressBySubscriptionId.get(frame.subscriptionId)?.get(frame.domain);
			if (tracked !== undefined && !state.receiver.hasIncompleteStage(tracked.begin))
				this.#clearDomainProgress(frame.subscriptionId, frame.domain);
		}
		if (
			frame.kind === 'subscription.batchBegin' &&
			acceptance.kind === 'ignored' &&
			acceptance.snapshotContained === true
		)
			this.#clearDomainProgress(frame.subscriptionId, frame.domain);
		if (acceptance.kind !== 'ignored') {
			if (frame.kind === 'subscription.batchBegin' && freshBegin) this.#armProgress(state, frame);
			else if (
				frame.kind === 'subscription.batchPart' &&
				acceptance.kind === 'staged' &&
				!alreadyStaged
			)
				this.#rearmProgress(state, frame);
			else if (
				frame.kind === 'subscription.batchComplete' &&
				this.#progressBySubscriptionId.get(frame.subscriptionId)?.get(frame.domain)?.begin
					.batchId === frame.batchId
			)
				this.#clearDomainProgress(frame.subscriptionId, frame.domain);
		}
		if (acceptance.kind === 'resnapshot') {
			recordBridgeProductBatchDiagnostic(
				sinks.diagnostic,
				bridgeProductBatchDiagnostic({
					frame,
					step: 'receiverRejection',
					rejection: acceptance.rejection,
				}),
			);
			sinks.resnapshot(frame);
		}
		if (
			frame.kind === 'subscription.batchPart' &&
			(acceptance.kind === 'staged' || acceptance.kind === 'ignored') &&
			acceptance.receivedThroughDeliverySequence !== undefined
		)
			sinks.receipt(frame, acceptance.receivedThroughDeliverySequence);
		for (const installation of state.receiver.takeInstallations()) {
			try {
				const installed = sinks.install(installation);
				if (installed !== undefined) {
					void installed.catch((error: unknown): void => {
						recordBridgeProductBatchDiagnostic(
							sinks.diagnostic,
							bridgeProductBatchDiagnostic({
								frame: installation.begin,
								step: 'applicationInstall',
								error,
							}),
						);
						sinks.resnapshot(installation.begin);
					});
				}
			} catch (error) {
				recordBridgeProductBatchDiagnostic(
					sinks.diagnostic,
					bridgeProductBatchDiagnostic({
						frame: installation.begin,
						step: 'applicationInstall',
						error,
					}),
				);
				// A typed application rejected this domain's certified bank. Keep
				// siblings flowing and ask native for this domain again.
				sinks.resnapshot(installation.begin);
			}
		}
	}

	requestResnapshotForLostReceipt(request: BridgeProductViewAcknowledgementRequest): void {
		const state = this.#receiversBySubscriptionId.get(request.subscriptionId);
		const begin = state?.lastBeginByDomain.get(request.domain);
		if (
			begin === undefined ||
			begin.domain !== request.domain ||
			begin.handle !== request.handle ||
			begin.incarnation !== request.incarnation ||
			begin.paneSessionId !== request.paneSessionId ||
			begin.workerInstanceId !== request.workerInstanceId
		)
			return;
		this.#sinks?.resnapshot(begin);
	}

	retireSubscription(subscriptionId: string): void {
		this.#sinks?.subscriptionRetired?.(subscriptionId);
		this.#clearProgress(subscriptionId);
		this.#acceptedScopeBySubscriptionId.delete(subscriptionId);
		this.#receiversBySubscriptionId.delete(subscriptionId);
	}

	clear(): void {
		for (const subscriptionId of this.#receiversBySubscriptionId.keys())
			this.#sinks?.subscriptionRetired?.(subscriptionId);
		for (const subscriptionId of this.#progressBySubscriptionId.keys())
			this.#clearProgress(subscriptionId);
		this.#acceptedScopeBySubscriptionId.clear();
		this.#receiversBySubscriptionId.clear();
	}

	#armProgress(
		state: { readonly receiver: BridgeProductViewBatchReceiver },
		begin: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchBegin' }>,
	): void {
		if (
			this.#progressBySubscriptionId.get(begin.subscriptionId)?.get(begin.domain)?.begin.batchId ===
			begin.batchId
		)
			return;
		this.#clearDomainProgress(begin.subscriptionId, begin.domain);
		const tracked = {
			begin,
			cancel: (): void => {},
		};
		const cancel = this.#deadlineClock.schedule(this.#progressDeadlineMilliseconds, (): void => {
			if (this.#progressBySubscriptionId.get(begin.subscriptionId)?.get(begin.domain) !== tracked)
				return;
			this.#clearDomainProgress(begin.subscriptionId, begin.domain);
			if (state.receiver.abandonIncompleteStage(begin))
				this.#sinks?.resnapshotLatest(begin.subscriptionId, begin.domain);
		});
		tracked.cancel = cancel;
		const domains = this.#progressBySubscriptionId.get(begin.subscriptionId) ?? new Map();
		domains.set(begin.domain, tracked);
		this.#progressBySubscriptionId.set(begin.subscriptionId, domains);
	}

	#rearmProgress(
		state: { readonly receiver: BridgeProductViewBatchReceiver },
		part: Extract<BridgeProductBatchFrame, { readonly kind: 'subscription.batchPart' }>,
	): void {
		const begin = this.#progressBySubscriptionId.get(part.subscriptionId)?.get(part.domain)?.begin;
		if (begin?.batchId === part.batchId) {
			this.#clearDomainProgress(part.subscriptionId, part.domain);
			this.#armProgress(state, begin);
		}
	}

	#clearDomainProgress(subscriptionId: string, domain: string): void {
		const domains = this.#progressBySubscriptionId.get(subscriptionId);
		const tracked = domains?.get(domain);
		tracked?.cancel();
		domains?.delete(domain);
		if (domains?.size === 0) this.#progressBySubscriptionId.delete(subscriptionId);
	}

	#clearProgress(subscriptionId: string): void {
		for (const domain of this.#progressBySubscriptionId.get(subscriptionId)?.keys() ?? [])
			this.#clearDomainProgress(subscriptionId, domain);
	}
}
