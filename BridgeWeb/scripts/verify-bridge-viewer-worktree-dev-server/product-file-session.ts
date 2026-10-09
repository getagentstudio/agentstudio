import { randomUUID } from 'node:crypto';

import type { BridgeProductBatchFrame } from '../../src/core/comm-worker/bridge-product-batch-wire-contracts.js';
import { bridgeProductContentRequestSchema } from '../../src/core/comm-worker/bridge-product-content-contracts.js';
import { BridgeProductContentStreamDecoder } from '../../src/core/comm-worker/bridge-product-content-stream-decoder.js';
import {
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from '../../src/core/comm-worker/bridge-product-contract-primitives.js';
import {
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE,
	BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE,
	decodeBridgeProductDevBootstrapDelivery,
	type BridgeProductDevBootstrapRequest,
} from '../../src/core/comm-worker/bridge-product-dev-bootstrap.js';
import {
	installBridgeProductFileBatch,
	type BridgeProductInstalledFileView,
} from '../../src/core/comm-worker/bridge-product-file-batch-installer.js';
import type { BridgeProductFileBatchRow } from '../../src/core/comm-worker/bridge-product-file-batch-row-contracts.js';
import type { BridgeProductFileMemberStatusRecord } from '../../src/core/comm-worker/bridge-product-file-member-status-contracts.js';
import {
	bridgeProductContentAcknowledgementRefusedSchema,
	bridgeProductFrameAcknowledgementRequestSchema,
	type BridgeProductFrameAcknowledgementRequest,
} from '../../src/core/comm-worker/bridge-product-frame-acknowledgement-contracts.js';
import {
	bridgeProductAdmissionResponseSchema,
	bridgeProductOperationResultAcknowledgedResponseSchema,
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
} from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	bridgeProductMetadataStreamRequestSchema,
	encodeBridgeProductCapabilityHeader,
	type BridgeProductControlResponse,
	type BridgeProductSessionBootstrap,
} from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import {
	BridgeProductViewBatchReceiver,
	type BridgeProductViewInstallation,
} from '../../src/core/comm-worker/bridge-product-view-batch-receiver.js';
import {
	bridgeProductViewAcknowledgedResponseSchema,
	bridgeProductViewAcknowledgementRequestSchema,
	type BridgeProductViewScopeRequest,
} from '../../src/core/comm-worker/bridge-product-view-control-wire-contracts.js';
import { BridgeVerifierMetadataFrames } from './product-file-session-metadata-frames.js';

export type BridgeVerifierProductFileSessionState =
	| 'idle'
	| 'opening'
	| 'open'
	| 'closing'
	| 'closed';

type FileDescriptorOutcome = NonNullable<BridgeProductFileBatchRow['descriptorOutcome']>;
export interface BridgeVerifierProductFileSource {
	readonly acceptedStreamSequence: number;
	readonly installations: readonly BridgeProductViewInstallation[];
	readonly sourceIdentity: BridgeProductFileMemberStatusRecord['source'];
}

export interface BridgeVerifierProductFileContent {
	readonly byteLength: number;
	readonly bytes: ArrayBuffer;
}

export interface BridgeVerifierProductFileRefresh {
	readonly descriptor: FileDescriptorOutcome;
	readonly previousDescriptorId: string;
	readonly status: BridgeProductFileMemberStatusRecord;
}

export interface BridgeVerifierProductFileSessionProps {
	readonly baseUrl: string;
	readonly scenarioName: string;
}

interface BridgeVerifierProductAuthority {
	readonly capability: string;
	readonly paneSessionId: string;
	readonly policy: BridgeProductSessionBootstrap['policy'];
	readonly workerInstanceId: string;
}

export class BridgeVerifierProductFileSession {
	readonly #baseUrl: string;
	#authority: BridgeVerifierProductAuthority | null = null;
	readonly #metadataStreamId = `verifier-file-stream-${randomUUID()}`;
	readonly #scenarioName: string;
	readonly #subscriptionId = `verifier-file-subscription-${randomUUID()}`;
	readonly #viewHandle = `verifier-file-view-${randomUUID()}`;
	readonly #viewIncarnation = `verifier-file-incarnation-${randomUUID()}`;
	#controlSequence = 0;
	readonly #demandedPaths = new Set<string>();
	readonly #descriptorByPath = new Map<string, FileDescriptorOutcome>();
	#scopeRevision = 0;
	#batchReceiver: BridgeProductViewBatchReceiver | null = null;
	#installedFileView: BridgeProductInstalledFileView | null = null;
	readonly #installations: BridgeProductViewInstallation[] = [];
	#metadataStream: BridgeVerifierMetadataStream | null = null;
	#state: BridgeVerifierProductFileSessionState = 'idle';

	constructor(props: BridgeVerifierProductFileSessionProps) {
		this.#baseUrl = props.baseUrl.replace(/\/$/u, '');
		this.#scenarioName = props.scenarioName;
	}

	get state(): BridgeVerifierProductFileSessionState {
		return this.#state;
	}

	async open(): Promise<BridgeVerifierProductFileSource> {
		this.#requireState('idle');
		this.#state = 'opening';
		process.stderr.write('[product-file-source-open] waiting=authority\n');
		await this.#installServerAuthority();

		process.stderr.write('[product-file-source-open] waiting=workerSession.open\n');
		const opened = await this.#postControl({ kind: 'workerSession.open', request: null });
		if (opened.kind !== 'workerSession.accepted') {
			throw new Error(`Expected workerSession.accepted, received ${opened.kind}.`);
		}
		process.stderr.write('[product-file-source-open] waiting=file.source.current\n');
		const sourceResponse = await this.#postControl({
			call: { method: 'file.source.current', request: {} },
			kind: 'product.call',
			workerDerivationEpoch: 0,
		});
		if (
			sourceResponse.kind !== 'call.completed' ||
			sourceResponse.call.method !== 'file.source.current' ||
			sourceResponse.call.result.status !== 'available'
		) {
			throw new Error('Expected an available file.source.current product result.');
		}

		process.stderr.write('[product-file-source-open] waiting=metadataStream.open\n');
		this.#metadataStream = await this.#openMetadataStream();
		process.stderr.write('[product-file-source-open] waiting=metadataStream.accepted\n');
		const streamAccepted = await this.#metadataStream.frames.waitFor(
			(frame) => frame.kind === 'metadataStream.accepted',
		);
		if (streamAccepted.kind !== 'metadataStream.accepted') {
			throw new Error('Expected metadataStream.accepted.');
		}

		process.stderr.write('[product-file-source-open] waiting=subscription.open\n');
		const subscriptionResponse = await this.#postControl({
			kind: 'subscription.open',
			subscription: {
				source: sourceResponse.call.result.source,
				subscriptionKind: 'file.metadata',
			},
			subscriptionId: this.#subscriptionId,
			workerDerivationEpoch: 0,
		});
		if (subscriptionResponse.kind !== 'subscription.openAccepted') {
			throw new Error(`Expected subscription.openAccepted, received ${subscriptionResponse.kind}.`);
		}
		this.#batchReceiver = new BridgeProductViewBatchReceiver({
			handle: this.#viewHandle,
			scope: this.#fileScope([]),
			scopeRevision: 0,
			subscriptionId: this.#subscriptionId,
			subscriptionKind: 'file.metadata',
		});
		this.#batchReceiver.admitDomain('default', this.#viewIncarnation);
		process.stderr.write('[product-file-source-open] waiting=subscription.setScope\n');
		await this.#setFileScope([]);
		process.stderr.write('[product-file-source-open] waiting=File snapshot batch\n');
		const installed = await this.#waitForFileInstallation((): boolean => true);

		this.#state = 'open';
		return {
			acceptedStreamSequence: streamAccepted.streamSequence,
			installations: [...this.#installations],
			sourceIdentity: installed.memberStatus.source,
		};
	}

	async demandDescriptor(
		path: string,
		excludedDescriptorId?: string,
	): Promise<FileDescriptorOutcome> {
		this.#requireState('open');
		const cached = this.#descriptorByPath.get(path);
		if (
			cached !== undefined &&
			(excludedDescriptorId === undefined ||
				cached.availability.availabilityKind !== 'available' ||
				cached.availability.contentDescriptor.descriptorId !== excludedDescriptorId)
		) {
			return cached;
		}
		if (!this.#demandedPaths.has(path)) {
			const desiredPaths = [...this.#demandedPaths, path];
			await this.#setFileScope(desiredPaths);
			this.#demandedPaths.add(path);
		}
		const installed = await this.#waitForFileInstallation((view): boolean => {
			const outcome = this.#descriptorOutcomeForPath(view, path);
			return (
				outcome !== null &&
				(excludedDescriptorId === undefined ||
					outcome.availability.availabilityKind !== 'available' ||
					outcome.availability.contentDescriptor.descriptorId !== excludedDescriptorId)
			);
		});
		const descriptor = this.#descriptorOutcomeForPath(installed, path);
		if (descriptor === null) {
			throw new Error(`Expected a File descriptor outcome for ${path}.`);
		}
		this.#descriptorByPath.set(path, descriptor);
		return descriptor;
	}

	#fileScope(paths: readonly string[]): BridgeProductViewScopeRequest['scope'] {
		return {
			kind: 'file',
			changeFilter: { kind: 'none' },
			interests: paths.length === 0 ? [] : [{ lane: 'foreground', paths: [...paths] }],
			pathScope: [],
		};
	}

	async #setFileScope(paths: readonly string[]): Promise<void> {
		const scopeRevision = this.#scopeRevision + 1;
		const scope = this.#fileScope(paths);
		this.#requireBatchReceiver().setScope(scope, scopeRevision);
		const response = await this.#postControl({
			domain: 'default',
			handle: this.#viewHandle,
			incarnation: this.#viewIncarnation,
			kind: 'subscription.setScope',
			scope,
			scopeRevision,
			subscriptionId: this.#subscriptionId,
			subscriptionKind: 'file.metadata',
		});
		if (
			response.kind !== 'subscription.scopeAccepted' ||
			response.handle !== this.#viewHandle ||
			response.scopeRevision !== scopeRevision
		) {
			throw new Error('Expected the requested File view scope to be accepted.');
		}
		this.#scopeRevision = scopeRevision;
	}

	#descriptorOutcomeForPath(
		view: BridgeProductInstalledFileView,
		path: string,
	): FileDescriptorOutcome | null {
		return (
			view.currentRecords.find((record) => record.row.displayKey === path)?.row.descriptorOutcome ??
			null
		);
	}

	async #waitForFileInstallation(
		predicate: (view: BridgeProductInstalledFileView) => boolean,
	): Promise<BridgeProductInstalledFileView> {
		for (;;) {
			// oxlint-disable-next-line no-await-in-loop -- Coverage progresses rows; the certificate alone settles the initial inventory.
			await this.#requireMetadataStream().frames.waitFor(
				(frame) =>
					frame.kind === 'subscription.batchComplete' &&
					frame.subscriptionId === this.#subscriptionId,
			);
			let matchedView: BridgeProductInstalledFileView | null = null;
			for (const installation of this.#requireBatchReceiver().takeInstallations()) {
				if (installation.begin.subscriptionKind !== 'file.metadata') continue;
				const installed = installBridgeProductFileBatch(installation, this.#installedFileView);
				this.#installedFileView = installed;
				this.#installations.push(installation);
				if (installation.certified && predicate(installed)) matchedView = installed;
			}
			if (matchedView !== null) return matchedView;
		}
	}

	#requireBatchReceiver(): BridgeProductViewBatchReceiver {
		if (this.#batchReceiver === null) throw new Error('File batch receiver is not installed.');
		return this.#batchReceiver;
	}

	async openContent(
		descriptorEvent: FileDescriptorOutcome,
	): Promise<BridgeVerifierProductFileContent> {
		this.#requireState('open');
		if (descriptorEvent.availability.availabilityKind !== 'available') {
			throw new Error(`File descriptor for ${descriptorEvent.path} is not available.`);
		}
		const contentRequest = bridgeProductContentRequestSchema.parse({
			contentKind: 'file.content',
			contentRequestId: `verifier-file-content-${randomUUID()}`,
			descriptor: descriptorEvent.availability.contentDescriptor,
			kind: 'content.open',
			leaseId: `verifier-file-lease-${randomUUID()}`,
			operationCorrelationId: null,
			paneSessionId: this.#paneSessionId,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerDerivationEpoch: 0,
			workerInstanceId: this.#workerInstanceId,
		});
		if (contentRequest.contentKind !== 'file.content') {
			throw new Error('Expected a file.content request.');
		}
		const response = await fetch(this.#endpoint('/__bridge-product/content'), {
			body: JSON.stringify(contentRequest),
			headers: this.#headers(),
			method: 'POST',
		});
		if (response.status !== 200 || response.body === null) {
			throw new Error(
				`File content request failed with status ${response.status}: ${await response.text()}`,
			);
		}

		const decoder = new BridgeProductContentStreamDecoder(contentRequest);
		const reader = response.body.getReader();
		let terminal: Awaited<ReturnType<typeof decoder.push>>['terminal'] = null;
		let unacknowledgedDataFrameCount = 0;
		let unacknowledgedDataByteCount = 0;
		const maximumReservedFrameBytes = BRIDGE_PRODUCT_MAXIMUM_CONTENT_FRAME_BYTES + 4;
		const dataFrameWireOverheadBytes = 4 + 1 + 4 + 4 + 33;
		const policy = this.#requireAuthority().policy;
		for (;;) {
			// oxlint-disable-next-line no-await-in-loop -- Content frames must be decoded in stream order.
			const chunk = await reader.read();
			if (chunk.done) break;
			// oxlint-disable-next-line no-await-in-loop -- Content validation is ordered with stream reads.
			const decoded = await decoder.push(chunk.value);
			for (const frame of decoded.frames) {
				if (frame.header.kind === 'content.data') {
					unacknowledgedDataFrameCount += 1;
					unacknowledgedDataByteCount += dataFrameWireOverheadBytes + frame.payload.byteLength;
					if (
						decoded.terminal !== null ||
						(unacknowledgedDataFrameCount < policy.viewCreditParts &&
							unacknowledgedDataByteCount <= policy.viewCreditBytes - maximumReservedFrameBytes)
					)
						continue;
				} else if (frame.header.kind !== 'content.accepted') {
					continue;
				}
				// oxlint-disable-next-line no-await-in-loop -- ACK0 and window-closing receipts gate ordered source reads.
				await this.#postContentAcknowledgement({
					contentRequestId: contentRequest.contentRequestId,
					receivedThroughContentSequence: frame.header.contentSequence,
					kind: 'content.acknowledge',
					leaseId: contentRequest.leaseId,
					paneSessionId: contentRequest.paneSessionId,
					wireVersion: contentRequest.wireVersion,
					workerInstanceId: contentRequest.workerInstanceId,
				});
				if (frame.header.kind === 'content.data') {
					unacknowledgedDataFrameCount = 0;
					unacknowledgedDataByteCount = 0;
				}
			}
			terminal = decoded.terminal ?? terminal;
		}
		decoder.finish();
		if (terminal === null) throw new Error('File content stream ended without a terminal frame.');
		if (terminal.kind !== 'complete') {
			throw new Error(
				terminal.kind === 'error'
					? `File content ended with ${terminal.kind}: ${terminal.code}:${terminal.safeMessage ?? 'no message'}.`
					: `File content ended with ${terminal.kind}.`,
			);
		}
		return {
			byteLength: terminal.bytes.byteLength,
			bytes: terminal.bytes,
		};
	}

	async waitForRefresh(
		path: string,
		previousDescriptorId: string,
	): Promise<BridgeVerifierProductFileRefresh> {
		this.#requireState('open');
		const installed = await this.#waitForFileInstallation((view): boolean => {
			const outcome = this.#descriptorOutcomeForPath(view, path);
			return (
				outcome !== null &&
				(outcome.availability.availabilityKind !== 'available' ||
					outcome.availability.contentDescriptor.descriptorId !== previousDescriptorId) &&
				(view.memberStatus.unstaged ?? 0) > 0
			);
		});
		const descriptor = this.#descriptorOutcomeForPath(installed, path);
		if (descriptor === null) {
			throw new Error(`Expected replacement File descriptor outcome for ${path}.`);
		}
		this.#descriptorByPath.set(path, descriptor);
		return { descriptor, previousDescriptorId, status: installed.memberStatus };
	}

	async close(): Promise<void> {
		this.#requireState('open');
		this.#state = 'closing';
		const response = await this.#postControl({
			kind: 'subscription.cancel',
			subscriptionId: this.#subscriptionId,
			subscriptionKind: 'file.metadata',
			workerDerivationEpoch: 0,
		});
		if (response.kind !== 'subscription.cancelAccepted') {
			throw new Error(`Expected subscription.cancelAccepted, received ${response.kind}.`);
		}
		const metadataStream = this.#requireMetadataStream();
		await metadataStream.frames.waitFor(
			(frame) =>
				frame.kind === 'subscription.cancelled' && frame.subscriptionId === this.#subscriptionId,
		);
		await metadataStream.close();
		this.#metadataStream = null;
		this.#authority = null;
		this.#state = 'closed';
	}

	async #installServerAuthority(): Promise<void> {
		const response = await fetch(this.#endpoint(BRIDGE_PRODUCT_DEV_BOOTSTRAP_ROUTE), {
			body: JSON.stringify({
				navigationIntent: {
					commandId: 'verifier-file-context',
					commandKind: 'activateContext',
					surface: 'file',
				},
				reason: 'initial',
				tabId: 'verifier-file-session',
			} satisfies BridgeProductDevBootstrapRequest),
			headers: { 'Content-Type': BRIDGE_PRODUCT_DEV_BOOTSTRAP_REQUEST_MEDIA_TYPE },
			method: 'POST',
		});
		if (
			response.status !== 200 ||
			response.headers.get('content-type') !== BRIDGE_PRODUCT_DEV_BOOTSTRAP_RESPONSE_MEDIA_TYPE
		) {
			throw new Error(`Bridge product bootstrap failed with status ${response.status}.`);
		}
		const delivery = decodeBridgeProductDevBootstrapDelivery(await response.arrayBuffer());
		const capability = encodeBridgeProductCapabilityHeader(delivery.productCapability);
		new Uint8Array(delivery.productCapability).fill(0);
		this.#authority = {
			capability,
			paneSessionId: delivery.bootstrap.paneSessionId,
			policy: delivery.bootstrap.policy,
			workerInstanceId: delivery.bootstrap.workerInstanceId,
		};
	}

	async #postControl(
		requestBody: Readonly<Record<string, unknown>>,
	): Promise<BridgeProductControlResponse> {
		this.#controlSequence += 1;
		const request = bridgeProductControlRequestSchema.parse({
			...requestBody,
			paneSessionId: this.#paneSessionId,
			requestId: `verifier-file-request-${this.#controlSequence}`,
			requestSequence: this.#controlSequence,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: this.#workerInstanceId,
		});
		if (request.kind === 'subscription.cancel') {
			const response = bridgeProductControlResponseSchema.parse(await this.#postCommand(request));
			if (response.kind === 'request.error') {
				throw new Error(`Bridge product cancellation failed with ${response.code}.`);
			}
			return response;
		}
		const admission = bridgeProductAdmissionResponseSchema.parse(await this.#postCommand(request));
		if (admission.kind === 'request.error') {
			throw new Error(`Bridge product control admission failed with ${admission.code}.`);
		}
		const resultRequest = bridgeProductOperationResultRequestSchema.parse({
			kind: 'operation.result',
			operationId: admission.operationId,
			paneSessionId: this.#paneSessionId,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: this.#workerInstanceId,
		});
		const result = bridgeProductOperationResultResponseSchema.parse(
			await this.#postCommand(resultRequest),
		);
		try {
			if (result.operationId !== admission.operationId || result.outcome !== 'succeeded') {
				throw new Error(`Bridge product operation settled as ${result.outcome}.`);
			}
			const completed = bridgeProductControlResponseSchema.parse(result.result);
			if (
				completed.paneSessionId !== request.paneSessionId ||
				completed.requestId !== request.requestId ||
				completed.requestSequence !== request.requestSequence ||
				completed.workerInstanceId !== request.workerInstanceId
			) {
				throw new Error('Bridge product operation result did not match its admission.');
			}
			return completed;
		} finally {
			await this.#acknowledgeOperationResult(admission.operationId);
		}
	}

	async #acknowledgeOperationResult(operationId: string): Promise<void> {
		this.#controlSequence += 1;
		const acknowledgement = bridgeProductOperationResultAcknowledgementSchema.parse({
			kind: 'operation.resultAcknowledgement',
			operationId: operationId,
			paneSessionId: this.#paneSessionId,
			requestId: `verifier-file-ack-${this.#controlSequence}`,
			requestSequence: this.#controlSequence,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: this.#workerInstanceId,
		});
		const acknowledged = bridgeProductOperationResultAcknowledgedResponseSchema.parse(
			await this.#postCommand(acknowledgement),
		);
		if (
			acknowledged.operationId !== operationId ||
			acknowledged.requestSequence !== acknowledgement.requestSequence
		) {
			throw new Error('Bridge product result acknowledgement did not match its operation.');
		}
	}

	async #postCommand(body: object): Promise<unknown> {
		const response = await fetch(this.#endpoint('/__bridge-product/command'), {
			body: JSON.stringify(body),
			headers: this.#headers(),
			method: 'POST',
		});
		const responseText = await response.text();
		if (response.status !== 200) {
			throw new Error(
				`Bridge product command failed with status ${response.status}: ${responseText}`,
			);
		}
		return JSON.parse(responseText) as unknown;
	}

	async #openMetadataStream(): Promise<BridgeVerifierMetadataStream> {
		const abortController = new AbortController();
		const request = bridgeProductMetadataStreamRequestSchema.parse({
			kind: 'metadataStream.open',
			metadataStreamId: this.#metadataStreamId,
			paneSessionId: this.#paneSessionId,
			resumeFromStreamSequence: null,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: this.#workerInstanceId,
		});
		const response = await fetch(this.#endpoint('/__bridge-product/stream'), {
			body: JSON.stringify(request),
			headers: this.#headers(),
			method: 'POST',
			signal: abortController.signal,
		});
		if (response.status !== 200 || response.body === null) {
			throw new Error(
				`Bridge product metadata stream failed with status ${response.status}: ${await response.text()}`,
			);
		}
		const reader = response.body.getReader();
		return {
			close: async (): Promise<void> => {
				abortController.abort();
				await reader.cancel().catch((): void => undefined);
			},
			frames: new BridgeVerifierMetadataFrames(
				reader,
				async (frame): Promise<void> => {
					if (
						frame.kind !== 'subscription.batchBegin' &&
						frame.kind !== 'subscription.batchPart' &&
						frame.kind !== 'subscription.batchComplete'
					)
						return;
					await this.#acceptFileBatchFrame(frame);
				},
				this.#subscriptionId,
			),
		};
	}

	async #acceptFileBatchFrame(frame: BridgeProductBatchFrame): Promise<void> {
		// Retirement is local before cancel: buffered parts no longer owe credits.
		if (this.#state === 'closing' || this.#state === 'closed') return;
		const acceptance = this.#requireBatchReceiver().accept(frame);
		if (acceptance.kind === 'resnapshot') {
			throw new Error(
				`File batch ${frame.batchId} requires a resnapshot for ${acceptance.domain}.`,
			);
		}
		if (acceptance.kind === 'staged' && acceptance.receivedThroughDeliverySequence !== undefined) {
			await this.#acknowledgeFileBatchParts(acceptance.receivedThroughDeliverySequence);
		}
	}

	async #acknowledgeFileBatchParts(receivedThroughDeliverySequence: number): Promise<void> {
		const request = bridgeProductViewAcknowledgementRequestSchema.parse({
			domain: 'default',
			handle: this.#viewHandle,
			incarnation: this.#viewIncarnation,
			kind: 'subscription.acknowledge',
			paneSessionId: this.#paneSessionId,
			receivedThroughDeliverySequence,
			subscriptionId: this.#subscriptionId,
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: this.#workerInstanceId,
		});
		const response = bridgeProductViewAcknowledgedResponseSchema.parse(
			await this.#postCommand(request),
		);
		if (
			response.subscriptionId !== this.#subscriptionId ||
			response.receivedThroughDeliverySequence !== receivedThroughDeliverySequence
		) {
			throw new Error('File batch cumulative acknowledgement did not match its receipt.');
		}
	}

	async #postContentAcknowledgement(
		acknowledgement: BridgeProductFrameAcknowledgementRequest,
	): Promise<void> {
		const body = bridgeProductFrameAcknowledgementRequestSchema.parse(acknowledgement);
		const response = await fetch(this.#endpoint('/__bridge-product/command'), {
			body: JSON.stringify(body),
			headers: this.#headers(),
			method: 'POST',
		});
		const responseText = await response.text();
		if (response.status === 404) {
			let refusalBody: unknown;
			try {
				refusalBody = JSON.parse(responseText);
			} catch {
				refusalBody = null;
			}
			const refusal = bridgeProductContentAcknowledgementRefusedSchema.safeParse(refusalBody);
			if (
				refusal.success &&
				refusal.data.contentRequestId === body.contentRequestId &&
				refusal.data.leaseId === body.leaseId &&
				refusal.data.receivedThroughContentSequence === body.receivedThroughContentSequence &&
				refusal.data.paneSessionId === body.paneSessionId &&
				refusal.data.workerInstanceId === body.workerInstanceId
			)
				return;
		}
		if (response.status !== 204 || responseText.length !== 0) {
			throw new Error(
				`Bridge product content acknowledgement failed with status ${response.status}: ${responseText}`,
			);
		}
	}

	#endpoint(path: string): string {
		return `${this.#baseUrl}${path}?scenario=${encodeURIComponent(this.#scenarioName)}`;
	}

	#headers(): HeadersInit {
		return {
			'Content-Type': 'application/json',
			'X-AgentStudio-Bridge-Product-Capability': this.#capability,
		};
	}

	get #capability(): string {
		return this.#requireAuthority().capability;
	}

	get #paneSessionId(): string {
		return this.#requireAuthority().paneSessionId;
	}

	get #workerInstanceId(): string {
		return this.#requireAuthority().workerInstanceId;
	}

	#requireAuthority(): BridgeVerifierProductAuthority {
		if (this.#authority === null) {
			throw new Error('Bridge product verifier authority is not installed.');
		}
		return this.#authority;
	}

	#requireMetadataStream(): BridgeVerifierMetadataStream {
		if (this.#metadataStream === null)
			throw new Error('Bridge product metadata stream is not open.');
		return this.#metadataStream;
	}

	#requireState(expectedState: BridgeVerifierProductFileSessionState): void {
		if (this.#state !== expectedState) {
			throw new Error(
				`Expected Bridge product File session state ${expectedState}, received ${this.#state}.`,
			);
		}
	}
}

interface BridgeVerifierMetadataStream {
	readonly close: () => Promise<void>;
	readonly frames: BridgeVerifierMetadataFrames;
}
