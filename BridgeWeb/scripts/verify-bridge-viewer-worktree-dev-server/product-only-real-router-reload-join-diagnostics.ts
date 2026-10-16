import type {
	Page,
	Request as PlaywrightRequest,
	Response as PlaywrightResponse,
} from 'playwright';
import { errors } from 'playwright';

import type { BridgeViewerUnresolvedWaiter } from './product-only-real-router-contract.ts';

const maximumCandidateCount = 32;
const maximumStreamCount = 4;
const maximumWorkerCount = 8;

type ReloadJoinWaiterName = 'file-metadata-open' | 'subscription-receipt' | 'review-metadata-open';

interface ReloadJoinRouteEntry {
	documentGeneration: number;
	httpStatus: number | null;
	ordinal: number;
	requestKind: string | null;
	requestSettled: boolean;
	responseCode: string | null;
	responseKind: string | null;
	subscriptionKind: string | null;
}

interface ReloadJoinWorker {
	readonly closed: boolean;
	readonly closedBeforeJourneyCompletion: boolean;
	readonly documentGeneration: number;
	readonly kind: 'comm-worker' | 'module-worker' | 'portable-blob-worker';
}

interface ReloadJoinResponseObservation {
	readonly entry: ReloadJoinRouteEntry | null;
	readonly responseDocumentGeneration: number | null;
}

type ReloadJoinWaiterState =
	| { readonly state: 'armed' }
	| { readonly observation: ReloadJoinResponseObservation; readonly state: 'fulfilled' }
	| { readonly reason: 'owned-deadline' | 'other' | 'wait-timeout'; readonly state: 'rejected' };

interface ReloadJoinDiagnostics {
	readonly armOrdinal: number;
	readonly targetDocumentGeneration: number;
	readonly candidates: ReloadJoinResponseObservation[];
	candidateCount: number;
	omittedCandidateCount: number;
	readonly waiters: Map<ReloadJoinWaiterName, ReloadJoinWaiterState>;
}

export interface BridgeViewerReloadJoinResponses {
	readonly fileMetadataOpen: Promise<PlaywrightResponse>;
	readonly subscriptionReceipt: Promise<PlaywrightResponse>;
	readonly reviewMetadataOpen: Promise<PlaywrightResponse>;
}

export interface ArmReloadJoinWaitersProps {
	readonly armOrdinal: number;
	readonly page: Page;
	// The page generation stamped on a request at its `request` event, or null
	// for a request the journey does not track.
	readonly requestDocumentGeneration: (request: PlaywrightRequest) => number | null;
	// Reload waiters are armed before navigation for the next page generation; a
	// response settles a waiter only when its request carries this generation, so
	// a late response to the previous document can never satisfy the reload join.
	readonly targetDocumentGeneration: number;
	readonly timeoutMilliseconds: number;
}

export class BridgeViewerReloadJoinDiagnosticRecorder {
	#diagnostics: ReloadJoinDiagnostics | null = null;
	readonly #observationByResponse = new WeakMap<
		PlaywrightResponse,
		ReloadJoinResponseObservation
	>();

	arm(props: ArmReloadJoinWaitersProps): BridgeViewerReloadJoinResponses {
		const { page, targetDocumentGeneration, timeoutMilliseconds } = props;
		const responseIsFromTargetGeneration = (response: PlaywrightResponse): boolean =>
			props.requestDocumentGeneration(response.request()) === targetDocumentGeneration;
		this.#diagnostics = {
			armOrdinal: props.armOrdinal,
			targetDocumentGeneration,
			candidateCount: 0,
			candidates: [],
			omittedCandidateCount: 0,
			waiters: new Map<ReloadJoinWaiterName, ReloadJoinWaiterState>([
				['file-metadata-open', { state: 'armed' }],
				['subscription-receipt', { state: 'armed' }],
				['review-metadata-open', { state: 'armed' }],
			]),
		};
		return {
			subscriptionReceipt: this.#observeWaiter(
				'subscription-receipt',
				page.waitForResponse(
					(response): boolean =>
						responseIsFromTargetGeneration(response) && responseIsSubscriptionReceipt(response),
					{ timeout: timeoutMilliseconds },
				),
			),
			fileMetadataOpen: this.#observeWaiter(
				'file-metadata-open',
				page.waitForResponse(
					(response): boolean =>
						responseIsFromTargetGeneration(response) &&
						responseIsSubscriptionOpen(response, 'file.metadata'),
					{ timeout: timeoutMilliseconds },
				),
			),
			reviewMetadataOpen: this.#observeWaiter(
				'review-metadata-open',
				page.waitForResponse(
					(response): boolean =>
						responseIsFromTargetGeneration(response) &&
						responseIsSubscriptionOpen(response, 'review.metadata'),
					{ timeout: timeoutMilliseconds },
				),
			),
		};
	}

	unresolvedWaiters(): readonly BridgeViewerUnresolvedWaiter[] {
		const diagnostics = this.#diagnostics;
		if (diagnostics === null) return [];
		return reloadJoinWaiterNames
			.filter((name): boolean => diagnostics.waiters.get(name)?.state !== 'fulfilled')
			.map(
				(name): BridgeViewerUnresolvedWaiter => ({
					documentGeneration: diagnostics.targetDocumentGeneration,
					name,
				}),
			);
	}

	observeResponse(
		response: PlaywrightResponse,
		entry: ReloadJoinRouteEntry,
		responseDocumentGeneration: number,
	): void {
		const observation = { entry, responseDocumentGeneration };
		this.#observationByResponse.set(response, observation);
		const diagnostics = this.#diagnostics;
		if (diagnostics === null || !entryIsCandidate(entry)) return;
		diagnostics.candidateCount += 1;
		if (diagnostics.candidates.length >= maximumCandidateCount) {
			diagnostics.omittedCandidateCount += 1;
			return;
		}
		diagnostics.candidates.push(observation);
	}

	emitFailure(
		entries: readonly ReloadJoinRouteEntry[],
		workers: readonly ReloadJoinWorker[],
	): void {
		const diagnostics = this.#diagnostics;
		if (diagnostics === null) {
			writeLine('summary armed=false');
			return;
		}
		writeLine(
			`summary armed=true armOrdinal=${diagnostics.armOrdinal} targetGen=${diagnostics.targetDocumentGeneration} candidates=${diagnostics.candidateCount} recorded=${diagnostics.candidates.length} omitted=${diagnostics.omittedCandidateCount}`,
		);
		for (const name of reloadJoinWaiterNames) {
			const state = diagnostics.waiters.get(name) ?? { state: 'armed' };
			writeLine(waiterLine(name, diagnostics.targetDocumentGeneration, state));
		}
		for (const [index, observation] of diagnostics.candidates.entries()) {
			writeLine(`candidate index=${index + 1} ${observationFields(observation)}`);
		}
		const streams = entries
			.filter((entry): boolean => entry.requestKind === 'metadataStream.open')
			.slice(-maximumStreamCount);
		for (const entry of streams) {
			writeLine(
				`stream ordinal=${entry.ordinal} requestGen=${entry.documentGeneration} status=${numberValue(entry.httpStatus)} settled=${entry.requestSettled}`,
			);
		}
		const recordedWorkers = workers.slice(0, maximumWorkerCount);
		for (const [index, worker] of recordedWorkers.entries()) {
			writeLine(
				`worker cohort=${index + 1} kind=${worker.kind} generation=${worker.documentGeneration} closed=${worker.closed} closedBeforeCompletion=${worker.closedBeforeJourneyCompletion}`,
			);
		}
		writeLine(
			`workers total=${workers.length} recorded=${recordedWorkers.length} omitted=${Math.max(0, workers.length - recordedWorkers.length)}`,
		);
	}

	#observeWaiter(
		name: ReloadJoinWaiterName,
		promise: Promise<PlaywrightResponse>,
	): Promise<PlaywrightResponse> {
		return promise.then(
			(response): PlaywrightResponse => {
				this.#diagnostics?.waiters.set(name, {
					observation: this.#observationByResponse.get(response) ?? {
						entry: null,
						responseDocumentGeneration: null,
					},
					state: 'fulfilled',
				});
				return response;
			},
			(error: unknown): never => {
				this.#diagnostics?.waiters.set(name, {
					reason: rejectionReason(error),
					state: 'rejected',
				});
				throw error;
			},
		);
	}
}

const reloadJoinWaiterNames: readonly ReloadJoinWaiterName[] = [
	'subscription-receipt',
	'file-metadata-open',
	'review-metadata-open',
];

function entryIsCandidate(entry: ReloadJoinRouteEntry): boolean {
	return (
		entry.requestKind === 'subscription.acknowledge' ||
		(entry.requestKind === 'subscription.open' &&
			(entry.subscriptionKind === 'file.metadata' || entry.subscriptionKind === 'review.metadata'))
	);
}

function waiterLine(
	name: ReloadJoinWaiterName,
	targetDocumentGeneration: number,
	state: ReloadJoinWaiterState,
): string {
	const waiter = `waiter name=${name} gen=${targetDocumentGeneration}`;
	switch (state.state) {
		case 'armed':
			return `${waiter} state=pending`;
		case 'fulfilled':
			return `${waiter} state=fulfilled ${observationFields(state.observation)}`;
		case 'rejected':
			return `${waiter} state=rejected reason=${state.reason}`;
	}
}

function observationFields(observation: ReloadJoinResponseObservation): string {
	const entry = observation.entry;
	return [
		`ordinal=${entry?.ordinal ?? 'unknown'}`,
		`requestGen=${entry?.documentGeneration ?? 'unknown'}`,
		`responseGen=${observation.responseDocumentGeneration ?? 'unknown'}`,
		`kind=${token(entry?.requestKind ?? null)}`,
		`subscription=${token(entry?.subscriptionKind ?? null)}`,
		`status=${numberValue(entry?.httpStatus ?? null)}`,
		`responseKind=${token(entry?.responseKind ?? null)}`,
		`responseCode=${token(entry?.responseCode ?? null)}`,
	].join(' ');
}

function rejectionReason(error: unknown): 'owned-deadline' | 'other' | 'wait-timeout' {
	if (
		error instanceof Error &&
		error.message.includes('BRIDGE_PRODUCT_JOURNEY_DEADLINE_EXCEEDED')
	) {
		return 'owned-deadline';
	}
	return error instanceof errors.TimeoutError ? 'wait-timeout' : 'other';
}

function responseIsSubscriptionReceipt(response: PlaywrightResponse): boolean {
	if (new URL(response.url()).pathname !== '/__bridge-product/command') return false;
	return (
		recordValue(parseJSONOrNull(response.request().postData()))?.['kind'] ===
		'subscription.acknowledge'
	);
}

function responseIsSubscriptionOpen(
	response: PlaywrightResponse,
	subscriptionKind: 'file.metadata' | 'review.metadata',
): boolean {
	if (new URL(response.url()).pathname !== '/__bridge-product/command') return false;
	const body = recordValue(parseJSONOrNull(response.request().postData()));
	const subscription = recordValue(body?.['subscription']);
	return (
		body?.['kind'] === 'subscription.open' &&
		subscription?.['subscriptionKind'] === subscriptionKind
	);
}

function parseJSONOrNull(value: string | null): unknown {
	if (value === null || value.length === 0) return null;
	try {
		return JSON.parse(value) as unknown;
	} catch {
		return null;
	}
}

function recordValue(value: unknown): Readonly<Record<string, unknown>> | null {
	return isRecordValue(value) ? value : null;
}

function isRecordValue(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function token(value: string | null): string {
	return value !== null && /^[A-Za-z0-9._-]{1,64}$/u.test(value) ? value : 'unknown';
}

function numberValue(value: number | null): string {
	return value === null ? 'unknown' : String(value);
}

function writeLine(value: string): void {
	process.stderr.write(`[bridge-product-reload-join] ${value}\n`);
}
