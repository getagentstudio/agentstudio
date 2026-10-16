import type { BridgeWorkerContentAvailabilityPatchPayload } from '../../src/core/comm-worker/bridge-worker-contracts.js';

export interface SelectedContentOwnerIdentity {
	readonly channelId: number;
	readonly itemId: string;
	readonly workerDerivationEpoch: number;
	readonly publicationId: string | null;
}

export interface SelectedContentOwnerFailure extends SelectedContentOwnerIdentity {
	readonly reason: string;
	readonly state: 'failed' | 'unavailable';
}

/** A terminal read belongs to one selected item and one current source/worker incarnation. */
export function selectedContentTerminalFailure(props: {
	readonly surface: 'file' | 'review';
	readonly current: SelectedContentOwnerIdentity;
	readonly observed: SelectedContentOwnerIdentity;
	readonly availability: BridgeWorkerContentAvailabilityPatchPayload;
}): SelectedContentOwnerFailure | null {
	if (
		props.current.channelId !== props.observed.channelId ||
		props.current.itemId !== props.observed.itemId ||
		props.current.workerDerivationEpoch !== props.observed.workerDerivationEpoch ||
		props.current.publicationId !== props.observed.publicationId
	)
		return null;
	const { state, reason } = props.availability;
	if (state !== 'failed' && state !== 'unavailable') return null;
	if (reason === undefined || reason === 'none' || reason === 'source_reset') return null;
	// File load failure and descriptor retirement may already have an automatic successor.
	// Only a permanent content classification closes this demand without guessing retry state.
	if (props.surface === 'file' && (state !== 'unavailable' || reason !== 'content_unavailable'))
		return null;
	return { ...props.observed, reason, state };
}

export interface SelectedContentOwnerSnapshot {
	readonly selectedItemId: string | null;
	readonly selectionRequestId: string | null;
	readonly workerDerivationEpoch: number | null;
	readonly publicationId: string | null;
	readonly phase: 'awaiting-selection' | 'selected' | 'source-installed' | 'content-result';
	readonly failure: SelectedContentOwnerFailure | null;
	readonly contentClosedSha256?: string | null;
	readonly preparedSha256?: string | null;
}

/** Self-contained so the exact reducer tested in Node can run in a page init script. */
export function createSelectedContentOwnerRecorder(
	classify: typeof selectedContentTerminalFailure,
): {
	readonly observe: (channelId: number, message: unknown) => void;
	readonly read: (surface: 'file' | 'review') => SelectedContentOwnerSnapshot;
} {
	let currentChannelId = -1;
	// oxlint-disable-next-line unicorn/consistent-function-scoping -- Serialized with this enclosing recorder into the page realm.
	const empty = (): SelectedContentOwnerSnapshot => ({
		selectedItemId: null,
		selectionRequestId: null,
		workerDerivationEpoch: null,
		publicationId: null,
		phase: 'awaiting-selection',
		failure: null,
	});
	let snapshots = { file: empty(), review: empty() };
	// Native refresh completion is a different owner from a selected content attempt.
	// A later content-ready patch must not erase the refresh owner's final failure.
	let fileRefreshFailure: SelectedContentOwnerFailure | null = null;
	let fileRecovery: {
		readonly subscriptionId: string;
		readonly status: 'ready' | 'recovering' | 'failedRetryable';
	} | null = null;
	let preparedFile: {
		readonly itemId: string;
		readonly sequence: number;
		readonly sha256: string;
	} | null = null;
	const sequences = { file: -1, review: -1 };
	// oxlint-disable-next-line unicorn/consistent-function-scoping -- Serialized with this enclosing recorder into the page realm.
	const record = (value: unknown): value is Readonly<Record<string, unknown>> =>
		typeof value === 'object' && value !== null && !Array.isArray(value);
	return {
		read: (surface): SelectedContentOwnerSnapshot => {
			const snapshot = snapshots[surface];
			if (
				surface === 'file' &&
				fileRecovery?.status === 'failedRetryable' &&
				snapshot.selectedItemId !== null &&
				snapshot.workerDerivationEpoch !== null
			) {
				return {
					...snapshot,
					failure: {
						channelId: currentChannelId,
						itemId: snapshot.selectedItemId,
						workerDerivationEpoch: snapshot.workerDerivationEpoch,
						publicationId: snapshot.publicationId,
						state: 'failed',
						reason: `file-view-recovery:failedRetryable:${fileRecovery.subscriptionId}`,
					},
				};
			}
			return surface === 'file' && fileRefreshFailure?.itemId === snapshot.selectedItemId
				? { ...snapshot, failure: fileRefreshFailure }
				: snapshot;
		},
		observe: (channelId, message): void => {
			if (!record(message)) return;
			if (message['method'] === 'bridgeCommWorker.bootstrap') {
				if (channelId <= currentChannelId) return;
				currentChannelId = channelId;
				snapshots = { file: empty(), review: empty() };
				sequences.file = -1;
				sequences.review = -1;
				fileRefreshFailure = null;
				fileRecovery = null;
				preparedFile = null;
				return;
			}
			if (channelId !== currentChannelId || message['wireVersion'] !== 1) return;
			// W2 publishes this on the product port without a surface field. Its failed
			// status ends automatic recovery; Retry is a separate explicit operation.
			if (
				message['direction'] === 'serverWorkerToMain' &&
				message['kind'] === 'viewRecoveryStatus'
			) {
				const view = message['view'];
				const status = message['status'];
				if (
					!record(view) ||
					view['kind'] !== 'file.metadata' ||
					typeof view['subscriptionId'] !== 'string' ||
					view['subscriptionId'].length === 0 ||
					(status !== 'ready' && status !== 'recovering' && status !== 'failedRetryable')
				)
					return;
				// New subscriptions announce recovering before any of their later outcomes.
				if (
					fileRecovery !== null &&
					fileRecovery.subscriptionId !== view['subscriptionId'] &&
					status !== 'recovering'
				)
					return;
				fileRecovery = { subscriptionId: view['subscriptionId'], status };
				return;
			}
			const surface =
				message['surface'] === 'review'
					? 'review'
					: message['surface'] === 'file' || message['surface'] === 'fileView'
						? 'file'
						: null;
			if (surface === null) return;
			const previous = snapshots[surface];
			if (message['direction'] === 'mainToServerWorker' && message['command'] === 'select') {
				const itemId = message['selectedItemId'];
				const requestId = message['requestId'];
				if ((typeof itemId !== 'string' && itemId !== null) || typeof requestId !== 'string')
					return;
				snapshots[surface] = {
					...previous,
					selectedItemId: itemId,
					selectionRequestId: requestId,
					phase: 'selected',
					failure: null,
					contentClosedSha256: null,
					preparedSha256: null,
				};
				if (surface === 'file') preparedFile = null;
				return;
			}
			if (message['direction'] !== 'serverWorkerToMain') return;
			const kind = message['kind'];
			const publication = message['reviewPublicationIdentity'];
			const publicationId =
				record(publication) && typeof publication['publicationId'] === 'string'
					? publication['publicationId']
					: null;
			if (kind === 'fileDisplayPatch' || kind === 'reviewDisplayPatch') {
				const epoch = message['epoch'];
				if (
					typeof epoch !== 'number' ||
					!Number.isSafeInteger(epoch) ||
					epoch < 0 ||
					(previous.workerDerivationEpoch !== null && epoch < previous.workerDerivationEpoch)
				)
					return;
				// A status-only Review patch without a publication does not retire the installed bank.
				if (surface === 'review' && publicationId === null) return;
				const changed =
					epoch !== previous.workerDerivationEpoch || publicationId !== previous.publicationId;
				snapshots[surface] = {
					...previous,
					workerDerivationEpoch: epoch,
					publicationId,
					phase: 'source-installed',
					failure: changed ? null : previous.failure,
					...(changed ? { contentClosedSha256: null, preparedSha256: null } : {}),
				};
				if (changed && surface === 'file') preparedFile = null;
				if (changed) sequences[surface] = -1;
				if (changed && surface === 'file') fileRefreshFailure = null;
				return;
			}
			if (kind === 'filePierreRenderJob' && surface === 'file') {
				const job = message['job'];
				const sequence = message['publicationSequence'];
				if (
					message['workerDerivationEpoch'] !== previous.workerDerivationEpoch ||
					typeof sequence !== 'number' ||
					!Number.isSafeInteger(sequence) ||
					sequence < Math.max(0, sequences.file, preparedFile?.sequence ?? -1) ||
					!record(job) ||
					job['itemId'] !== previous.selectedItemId ||
					!Array.isArray(job['sourceCorrelations'])
				)
					return;
				for (const correlation of job['sourceCorrelations']) {
					if (
						record(correlation) &&
						correlation['itemId'] === previous.selectedItemId &&
						typeof correlation['observedSha256'] === 'string' &&
						previous.selectedItemId !== null
					) {
						preparedFile = {
							itemId: previous.selectedItemId,
							sequence,
							sha256: correlation['observedSha256'],
						};
						snapshots.file = { ...previous, preparedSha256: correlation['observedSha256'] };
						break;
					}
				}
				return;
			}
			if (kind !== 'fileRenderPatch' && kind !== 'reviewRenderPatch') return;
			const epoch = message['workerDerivationEpoch'];
			const sequence = message['publicationSequence'];
			if (
				epoch !== previous.workerDerivationEpoch ||
				publicationId !== previous.publicationId ||
				typeof sequence !== 'number' ||
				!Number.isSafeInteger(sequence) ||
				sequence < sequences[surface] ||
				!Array.isArray(message['patches']) ||
				previous.selectedItemId === null ||
				previous.workerDerivationEpoch === null
			)
				return;
			sequences[surface] = sequence;
			for (const patch of message['patches']) {
				if (record(patch) && surface === 'file' && patch['slice'] === 'panelChrome') {
					if (patch['operation'] === 'reset' || patch['operation'] === 'delete') {
						fileRefreshFailure = null;
						continue;
					}
					const payload = patch['payload'];
					if (patch['operation'] !== 'upsert' || !record(payload)) continue;
					const failure = payload['fileRefreshFailure'];
					if (failure === null) {
						fileRefreshFailure = null;
						continue;
					}
					if (!record(failure)) continue;
					const failureKind = failure['failureKind'];
					const retryable = failure['retryable'];
					const validFailure =
						((failureKind === 'missingRoot' ||
							failureKind === 'unreadableRoot' ||
							failureKind === 'fileSourceUnavailable') &&
							retryable === true) ||
						((failureKind === 'fileRefreshFailed' || failureKind === 'producerRejected') &&
							retryable === false);
					if (!validFailure) continue;
					// The native driver records this only after ending its automatic retry pass.
					// retryable describes a subsequent explicit Retry, not pending automatic work.
					fileRefreshFailure = {
						channelId,
						itemId: previous.selectedItemId,
						workerDerivationEpoch: previous.workerDerivationEpoch,
						publicationId,
						state: 'failed',
						reason: `file-refresh:${failureKind}`,
					};
					continue;
				}
				if (
					!record(patch) ||
					patch['slice'] !== 'contentAvailability' ||
					patch['operation'] !== 'upsert' ||
					patch['itemId'] !== previous.selectedItemId ||
					!record(patch['payload'])
				)
					continue;
				const payload = patch['payload'];
				const state = payload['state'];
				const reason = payload['reason'];
				if (
					state !== 'loading' &&
					state !== 'ready' &&
					state !== 'failed' &&
					state !== 'stale' &&
					state !== 'unavailable'
				)
					continue;
				if (
					reason !== undefined &&
					reason !== 'none' &&
					reason !== 'source_reset' &&
					reason !== 'load_failed' &&
					reason !== 'descriptor_missing' &&
					reason !== 'descriptor_rejected' &&
					reason !== 'content_unavailable'
				)
					continue;
				const current = {
					channelId,
					itemId: previous.selectedItemId,
					workerDerivationEpoch: previous.workerDerivationEpoch,
					publicationId,
				};
				snapshots[surface] = {
					...previous,
					phase: 'content-result',
					...(surface === 'file' &&
					state === 'ready' &&
					preparedFile?.itemId === previous.selectedItemId &&
					preparedFile?.sequence === sequence
						? { contentClosedSha256: preparedFile.sha256 }
						: {}),
					failure: classify({
						surface,
						current,
						observed: { ...current, itemId: patch['itemId'] },
						availability: { state, ...(reason === undefined ? {} : { reason }) },
					}),
				};
			}
		},
	};
}
