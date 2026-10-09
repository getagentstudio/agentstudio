import type { WorktreeAnnotationLifecycleTelemetryRecorder } from '../../worktree-annotations/worktree-annotation-lifecycle-telemetry.js';
import type {
	BridgeCommWorkerAnnotationCatalog,
	BridgeCommWorkerAnnotationCatalogPublication,
} from './bridge-comm-worker-annotation-catalog-applicator.js';
import {
	BridgeCommWorkerAnnotationProjectionQueryController,
	type BridgeCommWorkerAnnotationProjectionDemand,
	type BridgeCommWorkerAnnotationProjectionPublication,
	type BridgeCommWorkerAnnotationProjectionSourceAuthorityStalePublication,
} from './bridge-comm-worker-annotation-projection-query-controller.js';
import { bridgeCommWorkerAnnotationProjectionTransport } from './bridge-comm-worker-annotation-projection-transport.js';
import {
	fileMetadataInterestsInPriorityOrder,
	reviewMetadataInterestLaneForDemandRole,
	reviewMetadataInterestsInPriorityOrder,
} from './bridge-comm-worker-metadata-interest-order.js';
import type { BridgeCommWorkerDemandMember } from './bridge-comm-worker-reconciler.js';
import {
	bridgeProductWorktreeAnnotationDecodedCommandResultSchema,
	type BridgeProductReviewAnnotationPublicationIdentity,
	type BridgeProductCallResult,
	type BridgeProductWorktreeAnnotationOperation,
} from './bridge-product-call-contracts.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import type { BridgeProductFileSourceIdentity } from './bridge-product-file-contracts.js';
import type { BridgeProductMetadataApplicationOptions } from './bridge-product-metadata-application-protocol.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { BridgeProductSubscriptionResetError } from './bridge-product-subscription-state.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import type { BridgeProductViewScopeRequest } from './bridge-product-view-control-wire-contracts.js';
import {
	BridgeProductViewReopenLifecycle,
	type BridgeProductMetadataSurface,
} from './bridge-product-view-reopen-lifecycle.js';

type FileMetadataProtocol = typeof bridgeProductFileMetadataApplicationProtocol;
type FileMetadataSubscription = BridgeProductMetadataApplicationSubscription<FileMetadataProtocol>;
type FileMetadataFailureHandler = (error: unknown, workerDerivationEpoch: number) => void;
type FileMetadataDemandFailureHandler = (error: unknown, workerDerivationEpoch: number) => void;
type FileMetadataInterest = Extract<
	BridgeProductViewScopeRequest['scope'],
	{ kind: 'file' }
>['interests'][number];
type FileMetadataInterestLane = FileMetadataInterest['lane'];
type FileSourceDiscoveryResult = BridgeProductCallResult<'file.source.current'>;
type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;
type ReviewMetadataFailureHandler = (error: unknown, workerDerivationEpoch: number) => void;
type ReviewMetadataInterest = Extract<
	BridgeProductViewScopeRequest['scope'],
	{ kind: 'review' }
>['interests'][number];
type ReviewMetadataInterestLane = ReviewMetadataInterest['lane'];

export interface BridgeCommWorkerFileMetadataDemand {
	readonly epoch: number;
	readonly nearbyPaths: readonly string[];
	readonly selectedPath: string | null;
	readonly visiblePaths: readonly string[];
}

export interface BridgeCommWorkerReviewActiveDemandSnapshot {
	readonly activeDemand: readonly {
		readonly itemId: string;
		readonly role: BridgeCommWorkerDemandMember['role'];
	}[];
	readonly workerDerivationEpoch: number;
}

export class BridgeCommWorkerProductController {
	readonly #annotationProjectionBySurface: Record<
		'file' | 'review',
		BridgeCommWorkerAnnotationProjectionQueryController
	>;
	readonly #onFileMetadataFailure: FileMetadataFailureHandler;
	readonly #onFileMetadataDemandFailure: FileMetadataDemandFailureHandler;
	readonly #onActiveViewerModeAdmitted: (mode: 'file' | 'review') => void;
	readonly #onAnnotationCatalog: (
		publication: BridgeCommWorkerAnnotationCatalogPublication,
	) => void;
	readonly #onReviewMetadataFailure: ReviewMetadataFailureHandler;
	readonly #onReviewWorkerDerivationEpochChanged: (workerDerivationEpoch: number | null) => void;
	readonly #onFileSourceUnavailable: () => void;
	readonly #productTransport: BridgeProductTransportSession;
	readonly #annotationSessionIdsBySurface: Record<'file' | 'review', Set<string>> = {
		file: new Set(),
		review: new Set(),
	};
	readonly #annotationSurfaceActive: Record<'file' | 'review', boolean> = {
		file: false,
		review: false,
	};
	readonly #annotationSourceGeneration: Record<'file' | 'review', number | null> = {
		file: null,
		review: null,
	};
	#reviewAnnotationPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null =
		null;
	readonly #callCurrentFileSource: () => Promise<FileSourceDiscoveryResult>;
	readonly #subscribeFile: (
		options: BridgeProductMetadataApplicationOptions<FileMetadataProtocol>,
	) => FileMetadataSubscription;
	readonly #subscribeReview: (
		options: BridgeProductMetadataApplicationOptions<ReviewMetadataProtocol>,
	) => ReviewMetadataSubscription;
	#fileSubscription: FileMetadataSubscription | null = null;
	#fileSource: BridgeProductFileSourceIdentity | null = null;
	#filePathScope: readonly string[] = [];
	readonly #fileInterestPathsByLane = new Map<FileMetadataInterestLane, readonly string[]>();
	#fileInterestRevision = 0;
	#fileInterestUpdate: Promise<void> = Promise.resolve();
	#fileInterestUpdateFailed = false;
	#fileDesiredInterestSignature: string | null = null;
	#hasPublishedFileMetadataInterests = false;
	#fileWorkerDerivationEpoch = 0;
	#fileDemandEpoch = 0;
	#hasFileMetadataDemand = false;
	#fileSourceEnsure: Promise<void> | null = null;
	readonly #metadataViewLifecycle: BridgeProductViewReopenLifecycle;
	#reviewSubscription: ReviewMetadataSubscription | null = null;
	readonly #reviewInterestItemIdsByLane = new Map<ReviewMetadataInterestLane, readonly string[]>();
	#reviewInterestUpdate: Promise<void> = Promise.resolve();
	#reviewInterestRevision = 0;
	#reviewDesiredInterestSignature: string | null = null;
	#reviewWorkerDerivationEpoch = 0;
	#latestActiveViewerModeRequestOrdinal = 0;

	constructor(props: {
		readonly callCurrentFileSource?: () => Promise<FileSourceDiscoveryResult>;
		readonly onAnnotationCatalog?: (
			publication: BridgeCommWorkerAnnotationCatalogPublication,
		) => void;
		readonly onAnnotationProjectionConvergence?: (
			publication: BridgeCommWorkerAnnotationProjectionPublication,
		) => void;
		readonly onActiveViewerModeAdmitted?: (mode: 'file' | 'review') => void;
		readonly onFileMetadataFailure?: FileMetadataFailureHandler;
		readonly onFileMetadataDemandFailure?: FileMetadataDemandFailureHandler;
		readonly onFileSourceUnavailable?: () => void;
		readonly onReviewMetadataFailure?: ReviewMetadataFailureHandler;
		readonly onReviewWorkerDerivationEpochChanged?: (workerDerivationEpoch: number | null) => void;
		readonly productTransport: BridgeProductTransportSession;
		readonly telemetryClient?: WorktreeAnnotationLifecycleTelemetryRecorder | undefined;
		readonly subscribeFile?: (
			options: BridgeProductMetadataApplicationOptions<FileMetadataProtocol>,
		) => FileMetadataSubscription;
		readonly subscribeReview?: (
			options: BridgeProductMetadataApplicationOptions<ReviewMetadataProtocol>,
		) => ReviewMetadataSubscription;
	}) {
		this.#metadataViewLifecycle = new BridgeProductViewReopenLifecycle(
			props.productTransport.metadataReopenPolicy.viewMaximumConsecutiveResnapshots,
		);
		this.#onActiveViewerModeAdmitted = props.onActiveViewerModeAdmitted ?? ignoreActiveViewerMode;
		this.#onFileMetadataFailure = props.onFileMetadataFailure ?? ignoreFileMetadataFailure;
		this.#onFileMetadataDemandFailure =
			props.onFileMetadataDemandFailure ?? ignoreFileMetadataFailure;
		this.#onFileSourceUnavailable = props.onFileSourceUnavailable ?? ignoreFileSourceUnavailable;
		this.#onReviewMetadataFailure = props.onReviewMetadataFailure ?? ignoreReviewMetadataFailure;
		this.#onReviewWorkerDerivationEpochChanged =
			props.onReviewWorkerDerivationEpochChanged ?? ignoreReviewWorkerDerivationEpochChange;
		this.#productTransport = props.productTransport;
		const onConvergence =
			props.onAnnotationProjectionConvergence ?? ignoreAnnotationProjectionConvergence;
		this.#onAnnotationCatalog = props.onAnnotationCatalog ?? ignoreAnnotationCatalog;
		const annotationProjectionTransport = bridgeCommWorkerAnnotationProjectionTransport(
			props.productTransport,
		);
		this.#annotationProjectionBySurface = {
			file: new BridgeCommWorkerAnnotationProjectionQueryController({
				onConvergence,
				onSourceAuthorityStale: (publication): void => {
					void this.reconcileAnnotationProjectionSourceAuthority(publication);
				},
				surface: 'file',
				transport: annotationProjectionTransport,
				telemetryClient: props.telemetryClient,
			}),
			review: new BridgeCommWorkerAnnotationProjectionQueryController({
				onConvergence,
				onSourceAuthorityStale: (publication): void => {
					void this.reconcileAnnotationProjectionSourceAuthority(publication);
				},
				surface: 'review',
				transport: annotationProjectionTransport,
				telemetryClient: props.telemetryClient,
			}),
		};
		this.#callCurrentFileSource =
			props.callCurrentFileSource ??
			((): Promise<FileSourceDiscoveryResult> =>
				this.#productTransport.call('file.source.current', {}));
		this.#subscribeFile =
			props.subscribeFile ??
			((options): FileMetadataSubscription =>
				this.#productTransport.subscribe(bridgeProductFileMetadataApplicationProtocol, options));
		this.#subscribeReview =
			props.subscribeReview ??
			((options): ReviewMetadataSubscription =>
				this.#productTransport.subscribe(bridgeProductReviewMetadataApplicationProtocol, options));
	}

	ensureAnnotationSubscriptions(): void {
		this.#annotationProjectionBySurface.file.ensureSubscription();
		this.#annotationProjectionBySurface.review.ensureSubscription();
	}

	acceptInstalledCommentCatalog(
		catalog: BridgeCommWorkerAnnotationCatalog,
		surface: 'file' | 'review',
	): void {
		if (!this.#annotationProjectionBySurface[surface].acceptInstalledCatalog(catalog)) return;
		this.#onAnnotationCatalog({ catalog, surface });
	}

	setAnnotationProjectionSurfaceActive(
		surface: 'file' | 'review',
		active: boolean,
		sourceGeneration: number | null,
	): void {
		this.#annotationSurfaceActive[surface] = active;
		// Main reports mode, while the certified W4 File installation owns the
		// source generation used by E4. A delayed Main update cannot move it.
		if (surface === 'review') this.#annotationSourceGeneration.review = sourceGeneration;
		this.#publishAnnotationProjectionDemand(surface);
	}

	setReviewAnnotationProjectionActive(active: boolean): void {
		this.#annotationSurfaceActive.review = active;
		this.#publishAnnotationProjectionDemand('review');
	}

	setReviewAnnotationProjectionIdentity(
		identity: BridgeProductReviewAnnotationPublicationIdentity | null,
	): void {
		this.#reviewAnnotationPublicationIdentity = identity;
		this.#annotationSourceGeneration.review = identity?.reviewGeneration ?? null;
		this.#publishAnnotationProjectionDemand('review');
	}

	retryAnnotationProjection(surface: 'file' | 'review'): void {
		// The source join may still be unavailable, but its notification E3 must
		// reopen now so a later installed catalog can restart the gated query.
		this.#annotationProjectionBySurface[surface].ensureSubscription();
		this.#annotationProjectionBySurface[surface].retry();
	}

	async waitForAnnotationProjectionIdle(surface: 'file' | 'review'): Promise<void> {
		await this.#annotationProjectionBySurface[surface].waitForIdle();
	}

	setAnnotationProjectionSourceUnavailable(surface: 'file' | 'review', error: unknown): void {
		this.#annotationProjectionBySurface[surface].sourceUnavailable(error);
	}

	reconcileAnnotationProjectionSourceAuthority(
		publication: BridgeCommWorkerAnnotationProjectionSourceAuthorityStalePublication,
	): Promise<void> {
		if (publication.currentSourceGeneration <= publication.requestedSourceGeneration) {
			this.setAnnotationProjectionSourceUnavailable(
				publication.surface,
				new Error('Annotation projection source authority did not advance.'),
			);
			return Promise.resolve();
		}
		// E4 projection currentness never owns the File or Review E3 lifetime. If W4 has
		// already installed the newer source, retry against it; otherwise setDemand
		// reissues the query when that installation reaches this controller.
		if (
			(this.#annotationSourceGeneration[publication.surface] ?? -1) >=
			publication.currentSourceGeneration
		) {
			this.#annotationProjectionBySurface[publication.surface].retry();
		}
		return Promise.resolve();
	}

	async disposeAnnotationProjections(): Promise<void> {
		await Promise.all([
			this.#annotationProjectionBySurface.file.dispose(),
			this.#annotationProjectionBySurface.review.dispose(),
		]);
	}

	ensureFileSource(): Promise<void> {
		if (this.#fileSourceEnsure !== null) return this.#fileSourceEnsure;
		try {
			this.#metadataViewLifecycle.admitOpen('file');
		} catch (error) {
			this.#productTransport.reportMetadataReopenExhausted('file.metadata');
			return Promise.reject(error);
		}
		const discoveryAttempt = this.#discoverAndOpenFileSource();
		const memoizedAttempt = discoveryAttempt.catch((error: unknown): never => {
			if (this.#fileSourceEnsure === memoizedAttempt) {
				this.#fileSourceEnsure = null;
				this.#metadataViewLifecycle.recordFailure('file', error);
			}
			throw error;
		});
		this.#fileSourceEnsure = memoizedAttempt;
		return memoizedAttempt;
	}

	acceptInstalledFileBatch(props: {
		readonly certified: boolean;
		readonly source: BridgeProductFileSourceIdentity;
		readonly subscriptionId: string;
		readonly workerDerivationEpoch: number;
	}): void {
		if (
			this.#fileSubscription?.subscriptionId !== props.subscriptionId ||
			this.#fileWorkerDerivationEpoch !== props.workerDerivationEpoch
		) {
			return;
		}
		this.#fileSource = props.source;
		this.#annotationSourceGeneration.file = props.source.subscriptionGeneration;
		this.#publishAnnotationProjectionDemand('file');
		if (props.certified) this.#metadataViewLifecycle.recordCertifiedInstall('file');
		this.#scheduleFileMetadataInterestPublication();
	}

	refreshInstalledFileAnnotationPlacement(): void {
		this.#annotationProjectionBySurface.file.refreshPlacementForInstalledFileView();
	}

	failCurrentMetadataRender(surface: 'file' | 'review'): void {
		const subscription = surface === 'file' ? this.#fileSubscription : this.#reviewSubscription;
		if (subscription === null) return;
		if (surface === 'file') this.#productTransport.failFileRender?.(subscription.subscriptionId);
		else this.#productTransport.failReviewRender?.(subscription.subscriptionId);
	}

	acceptInstalledReviewBatch(props: {
		readonly subscriptionId: string;
		readonly workerDerivationEpoch: number;
	}): void {
		if (
			this.#reviewSubscription?.subscriptionId !== props.subscriptionId ||
			this.#reviewWorkerDerivationEpoch !== props.workerDerivationEpoch
		)
			return;
		this.#metadataViewLifecycle.recordCertifiedInstall('review');
	}

	async retryMetadataView(surface: BridgeProductMetadataSurface): Promise<void> {
		this.#metadataViewLifecycle.retry(surface);
		if (surface === 'file') {
			if (this.#fileSubscription === null) this.#fileSourceEnsure = null;
			await this.ensureFileSource();
		} else this.ensureReviewMetadata();
	}

	ensureReviewMetadata(): void {
		if (this.#reviewSubscription !== null) return;
		try {
			this.#metadataViewLifecycle.admitOpen('review');
		} catch (error) {
			this.#productTransport.reportMetadataReopenExhausted('review.metadata');
			throw error;
		}
		const workerDerivationEpoch = this.#productTransport.advanceWorkerDerivationEpoch('review');
		this.#reviewWorkerDerivationEpoch = workerDerivationEpoch;
		this.#reviewDesiredInterestSignature = JSON.stringify([]);
		try {
			const subscription = this.#subscribeReview({});
			this.#reviewSubscription = subscription;
			this.#onReviewWorkerDerivationEpochChanged(workerDerivationEpoch);
			void this.#watchReviewMetadataLifecycle(subscription, workerDerivationEpoch).catch(
				(): void => {},
			);
			if (this.#reviewInterestItemIdsByLane.size > 0) {
				void this.#commitReviewMetadataInterests().catch((): void => {});
			}
		} catch (error) {
			this.#reviewDesiredInterestSignature = null;
			this.#metadataViewLifecycle.recordFailure('review', error);
			this.#onReviewMetadataFailure(error, workerDerivationEpoch);
			throw error;
		}
	}

	async sendProductControl(command: BridgeProductControlCommand): Promise<unknown> {
		switch (command.method) {
			case 'file.refresh.retry': {
				const needsSourceRecovery =
					this.#fileSubscription === null || this.#fileSourceEnsure === null;
				const result = await this.#productTransport.call('file.refresh.retry', {});
				if (needsSourceRecovery) await this.retryMetadataView('file');
				return result;
			}
			case 'file.annotations.command':
				return await this.#sendAnnotationCommand('file', command.params.operation, null);
			case 'review.annotations.command':
				return await this.#sendAnnotationCommand(
					'review',
					command.params.operation,
					command.params['reviewPublicationIdentity'],
				);
			case 'review.markFileViewed':
				return await this.#productTransport.call('review.markFileViewed', {
					itemId: command.params.fileId,
				});
			case 'review.comparison.update':
				this.#metadataViewLifecycle.materialDesiredChange(
					'review',
					JSON.stringify(command.params.target),
				);
				this.#ensureReviewMetadataForInteractiveControl();
				return await this.#productTransport.call('review.comparison.update', {
					target: command.params.target,
				});
			case 'review.comparisonTargets.query':
				this.#ensureReviewMetadataForInteractiveControl();
				return await this.#productTransport.call('review.comparisonTargets.query', {});
			case 'review.publication.install.admit':
				return await this.#productTransport.call(
					'review.publication.install.admit',
					command.params,
				);
			case 'review.publication.applied':
				return await this.#productTransport.call('review.publication.applied', command.params);
			case 'bridge.activeViewerMode.update':
				return await this.#sendActiveViewerModeUpdate(command);
			case 'bridge.intakeReady':
				return await this.#productTransport.call('review.intake.ready', {
					reason: command.params.reason ?? null,
					streamId: command.params.streamId ?? null,
				});
			default:
				return assertNeverBridgeProductControlCommand(command);
		}
	}

	#ensureReviewMetadataForInteractiveControl(): void {
		try {
			this.ensureReviewMetadata();
		} catch {
			// Exact control success remains independent of metadata-stream recovery.
		}
	}

	async #sendAnnotationCommand(
		surface: 'file' | 'review',
		operation: BridgeProductWorktreeAnnotationOperation,
		reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity | null,
	): Promise<unknown> {
		const result =
			surface === 'file'
				? await this.#productTransport.call('file.annotations.command', { operation })
				: await this.#productTransport.call('review.annotations.command', {
						operation,
						reviewPublicationIdentity:
							requireReviewAnnotationPublicationIdentity(reviewPublicationIdentity),
					});
		const parsedResult = bridgeProductWorktreeAnnotationDecodedCommandResultSchema.parse(result);
		if (parsedResult.outcome.status.kind !== 'committed') return parsedResult;
		if (operation.kind === 'demand.acquire') {
			this.#annotationSessionIdsBySurface[surface].add(operation.sessionId);
			this.#publishAnnotationProjectionDemand(surface);
		} else if (operation.kind === 'demand.release') {
			this.#annotationSessionIdsBySurface[surface].delete(operation.sessionId);
			this.#publishAnnotationProjectionDemand(surface);
		}
		return parsedResult;
	}

	#publishAnnotationProjectionDemand(surface: 'file' | 'review'): void {
		this.#annotationProjectionBySurface[surface].setDemand({
			active: this.#annotationSurfaceActive[surface],
			reviewPublicationIdentity:
				surface === 'review' ? this.#reviewAnnotationPublicationIdentity : null,
			sessionIds: [...this.#annotationSessionIdsBySurface[surface]],
			sourceGeneration: this.#annotationSourceGeneration[surface],
		} satisfies BridgeCommWorkerAnnotationProjectionDemand);
	}

	async replaceReviewMetadataInterestsFromActiveDemand(
		snapshot: BridgeCommWorkerReviewActiveDemandSnapshot,
	): Promise<void> {
		if (snapshot.workerDerivationEpoch !== this.#reviewWorkerDerivationEpoch) {
			throw new Error('Bridge Review demand interests belong to a retired worker authority.');
		}
		this.#reviewInterestItemIdsByLane.clear();
		const itemIdsByLane = new Map<ReviewMetadataInterestLane, string[]>();
		for (const { itemId, role } of snapshot.activeDemand) {
			const lane = reviewMetadataInterestLaneForDemandRole(role);
			const itemIds = itemIdsByLane.get(lane) ?? [];
			itemIds.push(itemId);
			itemIdsByLane.set(lane, itemIds);
		}
		for (const [lane, itemIds] of itemIdsByLane) {
			this.#reviewInterestItemIdsByLane.set(lane, itemIds);
		}
		await this.#commitReviewMetadataInterests();
	}

	async #commitReviewMetadataInterests(): Promise<void> {
		const interests = reviewMetadataInterestsInPriorityOrder(this.#reviewInterestItemIdsByLane);
		if (this.#reviewSubscription === null) {
			this.ensureReviewMetadata();
			return;
		}
		const signature = JSON.stringify(interests);
		if (signature === this.#reviewDesiredInterestSignature) {
			const subscription = this.#reviewSubscription;
			await this.#reviewInterestUpdate;
			if (subscription !== this.#reviewSubscription) {
				throw new Error(
					'Bridge Review metadata interest update belongs to a retired Review interest authority.',
				);
			}
			return;
		}
		this.#reviewDesiredInterestSignature = signature;
		this.#reviewInterestRevision += 1;
		const interestRevision = this.#reviewInterestRevision;
		const subscription = this.#reviewSubscription;
		const workerDerivationEpoch = this.#reviewWorkerDerivationEpoch;
		const nextUpdate = (async (): Promise<void> => {
			if (subscription !== this.#reviewSubscription) {
				throw new Error(
					'Bridge Review metadata interest update belongs to a retired Review interest authority.',
				);
			}
			try {
				if (this.#productTransport.setViewScopeForSubscription === undefined) {
					throw new Error('Review metadata view scope owner is unavailable.');
				}
				await this.#productTransport.setViewScopeForSubscription({
					scope: { kind: 'review', interests },
					subscriptionId: subscription.subscriptionId,
				});
				if (interestRevision !== this.#reviewInterestRevision) return;
				if (subscription !== this.#reviewSubscription) {
					throw new Error(
						'Bridge Review metadata interest update belongs to a retired Review interest authority.',
					);
				}
			} catch (error) {
				if (interestRevision !== this.#reviewInterestRevision) return;
				if (subscription === this.#reviewSubscription) {
					this.#reviewDesiredInterestSignature = null;
					this.#onReviewMetadataFailure(error, workerDerivationEpoch);
				}
				throw error;
			}
		})();
		this.#reviewInterestUpdate = nextUpdate;
		await nextUpdate;
	}

	async #watchReviewMetadataLifecycle(
		subscription: ReviewMetadataSubscription,
		workerDerivationEpoch: number,
	): Promise<void> {
		try {
			for await (const _terminal of subscription.events) {
				// E3 carries lifecycle only; a data frame is rejected by the wire decoder.
			}
		} catch (error) {
			if (subscription !== this.#reviewSubscription) return;
			this.#retireFailedReviewMetadataSubscription(subscription);
			this.#metadataViewLifecycle.recordFailure('review', error);
			if (error instanceof BridgeProductSubscriptionResetError) {
				try {
					this.ensureReviewMetadata();
				} catch {
					// The typed failure is already published; later demand can retry.
				}
			}
			this.#onReviewMetadataFailure(error, workerDerivationEpoch);
			throw error;
		}
		if (subscription !== this.#reviewSubscription) return;
		const error = new Error('Bridge Review metadata subscription ended unexpectedly.');
		this.#retireFailedReviewMetadataSubscription(subscription);
		this.#metadataViewLifecycle.recordFailure('review', error);
		this.#onReviewMetadataFailure(error, workerDerivationEpoch);
		throw error;
	}

	#retireFailedReviewMetadataSubscription(subscription: ReviewMetadataSubscription): void {
		if (subscription !== this.#reviewSubscription) return;
		this.#onReviewWorkerDerivationEpochChanged(null);
		this.#reviewSubscription = null;
		this.#reviewDesiredInterestSignature = null;
		this.#reviewInterestUpdate = Promise.resolve();
	}

	async updateFileMetadataDemand(demand: BridgeCommWorkerFileMetadataDemand): Promise<void> {
		if (demand.epoch < this.#fileDemandEpoch) return;
		this.#fileDemandEpoch = demand.epoch;
		this.#hasFileMetadataDemand = true;
		const selectedPaths = demand.selectedPath === null ? [] : [demand.selectedPath];
		const selectedPathSet = new Set(selectedPaths);
		const visiblePaths = uniqueFileDemandPaths(demand.visiblePaths).filter(
			(path) => !selectedPathSet.has(path),
		);
		const selectedOrVisiblePathSet = new Set([...selectedPaths, ...visiblePaths]);
		const nearbyPaths = uniqueFileDemandPaths(demand.nearbyPaths).filter(
			(path) => !selectedOrVisiblePathSet.has(path),
		);
		this.#metadataViewLifecycle.materialDesiredChange(
			'file',
			JSON.stringify({ selectedPaths, visiblePaths, nearbyPaths }),
		);
		this.#replaceFileInterestLane('foreground', selectedPaths);
		this.#replaceFileInterestLane('visible', visiblePaths);
		this.#replaceFileInterestLane('nearby', nearbyPaths);
		await this.#publishFileMetadataInterests();
	}

	async #discoverAndOpenFileSource(): Promise<void> {
		const discovery = await this.#callCurrentFileSource();
		if (discovery.status === 'unavailable') {
			this.#onFileSourceUnavailable();
			return;
		}
		const workerDerivationEpoch = this.#productTransport.advanceWorkerDerivationEpoch('file');
		this.#fileWorkerDerivationEpoch = workerDerivationEpoch;
		this.#filePathScope = [];
		this.#fileDesiredInterestSignature = null;
		this.#hasPublishedFileMetadataInterests = false;
		this.#fileInterestRevision += 1;
		const subscription = this.#subscribeFile({
			source: discovery.source,
		});
		this.#fileSubscription = subscription;
		void this.#watchFileMetadataLifecycle(subscription, workerDerivationEpoch).catch(
			(): void => {},
		);
	}

	#replaceFileInterestLane(lane: FileMetadataInterestLane, paths: readonly string[]): void {
		const uniquePaths = uniqueFileDemandPaths(paths);
		if (uniquePaths.length === 0) {
			this.#fileInterestPathsByLane.delete(lane);
			return;
		}
		this.#fileInterestPathsByLane.set(lane, uniquePaths);
	}

	async #publishFileMetadataInterests(): Promise<void> {
		if (!this.#hasFileMetadataDemand) {
			return;
		}
		const subscription = this.#fileSubscription;
		const source = this.#fileSource;
		if (subscription === null || source === null) {
			return;
		}
		const interests = fileMetadataInterestsInPriorityOrder(this.#fileInterestPathsByLane);
		if (interests.length === 0 && !this.#hasPublishedFileMetadataInterests) {
			return;
		}
		const update = {
			interests,
			pathScope: this.#filePathScope,
		};
		const signature = JSON.stringify({
			interests,
			pathScope: this.#filePathScope,
			sourceId: source.sourceId,
			subscriptionGeneration: source.subscriptionGeneration,
		});
		if (signature === this.#fileDesiredInterestSignature) {
			await this.#fileInterestUpdate;
			return;
		}
		this.#fileDesiredInterestSignature = signature;
		this.#fileInterestRevision += 1;
		const interestRevision = this.#fileInterestRevision;
		const workerDerivationEpoch = this.#fileWorkerDerivationEpoch;
		const nextUpdate = this.#performFileMetadataInterestUpdate({
			interestRevision,
			subscription,
			update,
			workerDerivationEpoch,
		});
		this.#fileInterestUpdate = nextUpdate;
		await nextUpdate;
	}

	async #performFileMetadataInterestUpdate(props: {
		readonly interestRevision: number;
		readonly subscription: FileMetadataSubscription;
		readonly update: {
			readonly interests: readonly FileMetadataInterest[];
			readonly pathScope: readonly string[];
		};
		readonly workerDerivationEpoch: number;
	}): Promise<void> {
		if (
			props.subscription !== this.#fileSubscription ||
			props.interestRevision !== this.#fileInterestRevision
		) {
			return;
		}
		try {
			if (this.#productTransport.setViewScopeForSubscription === undefined) {
				throw new Error('File metadata view scope owner is unavailable.');
			}
			const settlement = await this.#productTransport.setViewScopeForSubscription({
				scope: {
					changeFilter: { kind: 'none' },
					interests: props.update.interests,
					kind: 'file',
					pathScope: props.update.pathScope,
				},
				subscriptionId: props.subscription.subscriptionId,
			});
			if (
				props.subscription !== this.#fileSubscription ||
				props.interestRevision !== this.#fileInterestRevision
			)
				return;
			if (settlement.kind === 'cancelled') return;
			this.#hasPublishedFileMetadataInterests = true;
			this.#fileInterestUpdateFailed = false;
		} catch (error) {
			if (
				props.subscription === this.#fileSubscription &&
				props.interestRevision === this.#fileInterestRevision
			) {
				this.#fileDesiredInterestSignature = null;
				this.#fileInterestUpdateFailed = true;
				this.#onFileMetadataDemandFailure(error, props.workerDerivationEpoch);
			}
			throw error;
		}
	}

	async #watchFileMetadataLifecycle(
		subscription: FileMetadataSubscription,
		workerDerivationEpoch: number,
	): Promise<void> {
		try {
			for await (const _terminal of subscription.events) {
				// E3 carries lifecycle only; File rows arrive through sealed W4 batches.
			}
		} catch (error) {
			if (!this.#retireFailedFileMetadataSubscription(subscription)) return;
			this.#metadataViewLifecycle.recordFailure('file', error);
			if (error instanceof BridgeProductSubscriptionResetError) {
				await this.ensureFileSource().catch((): void => {});
			}
			this.#onFileMetadataFailure(error, workerDerivationEpoch);
			throw error;
		}
		if (!this.#retireFailedFileMetadataSubscription(subscription)) return;
		const error = new Error('Bridge File metadata subscription ended unexpectedly.');
		this.#metadataViewLifecycle.recordFailure('file', error);
		this.#onFileMetadataFailure(error, workerDerivationEpoch);
		throw error;
	}

	#retireFailedFileMetadataSubscription(subscription: FileMetadataSubscription): boolean {
		if (subscription !== this.#fileSubscription) return false;
		this.#fileSubscription = null;
		this.#fileSource = null;
		this.#fileSourceEnsure = null;
		this.#fileDesiredInterestSignature = null;
		this.#hasPublishedFileMetadataInterests = false;
		this.#fileInterestUpdate = Promise.resolve();
		this.#fileInterestUpdateFailed = false;
		return true;
	}

	#scheduleFileMetadataInterestPublication(): void {
		void this.#publishFileMetadataInterests()
			.catch((): void => {})
			.then((): void => {
				if (!this.#fileInterestUpdateFailed) return;
				void this.#publishFileMetadataInterests().catch((): void => {});
			});
	}

	async #sendActiveViewerModeUpdate(
		command: Extract<
			BridgeProductControlCommand,
			{ readonly method: 'bridge.activeViewerMode.update' }
		>,
	): Promise<unknown> {
		const expectedProtocol = command.params.mode === 'review' ? 'review' : 'worktree-file';
		if (
			command.params.activeSource !== null &&
			command.params.activeSource.protocol !== expectedProtocol
		) {
			throw new Error('Bridge active viewer source does not match its selected surface.');
		}
		const requestOrdinal = this.#latestActiveViewerModeRequestOrdinal + 1;
		this.#latestActiveViewerModeRequestOrdinal = requestOrdinal;
		const request = {
			activeSource:
				command.params.activeSource === null
					? null
					: {
							generation: command.params.activeSource.generation,
							streamId: command.params.activeSource.streamId,
						},
			nativeSelectionRequestId: command.params.nativeSelectionRequestId,
			sequence: command.params.sequence,
			sessionId: command.params.sessionId,
		};
		if (command.params.mode === 'review') {
			const result = await this.#productTransport.call('review.activeViewerMode.update', request);
			if (requestOrdinal === this.#latestActiveViewerModeRequestOrdinal) {
				this.#onActiveViewerModeAdmitted('review');
			}
			try {
				// The visible-mode callback is latest-wins. The accepted Review
				// control still owns a live subscription after File becomes visible.
				this.ensureReviewMetadata();
			} catch {
				// Exact active-mode success remains independent of metadata-stream recovery.
			}
			return result;
		}
		const result = await this.#productTransport.call('file.activeViewerMode.update', request);
		if (requestOrdinal !== this.#latestActiveViewerModeRequestOrdinal) return result;
		this.#onActiveViewerModeAdmitted('file');
		try {
			await this.ensureFileSource();
		} catch (error) {
			// Exact active-mode success remains independent of metadata-stream recovery.
			this.#onFileMetadataFailure(error, this.#fileWorkerDerivationEpoch);
		}
		return result;
	}
}

function requireReviewAnnotationPublicationIdentity(
	identity: BridgeProductReviewAnnotationPublicationIdentity | null,
): BridgeProductReviewAnnotationPublicationIdentity {
	if (identity === null) {
		throw new Error('Review annotation command has no installed publication identity.');
	}
	return identity;
}

function uniqueFileDemandPaths(paths: readonly string[]): readonly string[] {
	return [...new Set(paths)];
}

function assertNeverBridgeProductControlCommand(command: never): never {
	throw new Error(`Unhandled Bridge product command: ${JSON.stringify(command)}`);
}

function ignoreFileMetadataFailure(_error: unknown, _workerDerivationEpoch: number): void {}

function ignoreFileSourceUnavailable(): void {}

function ignoreActiveViewerMode(_mode: 'file' | 'review'): void {}

function ignoreReviewMetadataFailure(_error: unknown, _workerDerivationEpoch: number): void {}

function ignoreReviewWorkerDerivationEpochChange(_workerDerivationEpoch: number | null): void {}

function ignoreAnnotationProjectionConvergence(
	_publication: BridgeCommWorkerAnnotationProjectionPublication,
): void {}

function ignoreAnnotationCatalog(
	_publication: BridgeCommWorkerAnnotationCatalogPublication,
): void {}
