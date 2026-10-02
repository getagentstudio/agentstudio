import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import invalidProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/invalid/bridge-product-session-corpus.json' with { type: 'json' };
import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import {
	bridgeProductContentHeaderSchema,
	bridgeProductContentRequestSchema,
} from './bridge-product-content-contracts.js';
import { BridgeProductContentFrameEncoder } from './bridge-product-content-frame-codec.js';
import { BridgeProductContentFrameDecoder } from './bridge-product-content-frame-decoder.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
} from './bridge-product-contract-primitives.js';
import { parseBridgeProductRegisteredControlRequest } from './bridge-product-metadata-application-registry.js';
import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from './bridge-product-metadata-frame-codec.js';
import {
	bridgePaneCommWorkerInstallSchema,
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	bridgeProductMetadataAcceptedStreamSequence,
	bridgeProductMetadataFrameSchema,
	bridgeProductMetadataStreamRequestSchema,
	bridgeProductNavigationCommandSchema,
	bridgeProductSessionBootstrapSchema,
	encodeBridgeProductCapabilityHeader,
	postBridgePaneCommWorkerInstall,
} from './bridge-product-session-contracts.js';
import { parseBridgeProductStrictJSON } from './bridge-product-strict-json.js';

describe('Bridge product session contracts', () => {
	test('admits only the intrinsic shared navigation command matrix', () => {
		const activateContext = {
			bindingRevision: 4,
			commandId: 'navigation-context-review',
			commandKind: 'activateContext',
			surface: 'review',
		};
		const activateFileTarget = {
			bindingRevision: 5,
			commandId: 'navigation-file-readme',
			commandKind: 'activateTarget',
			source: {
				sourceId: 'accepted-file-source',
				sourceKind: 'file',
				subscriptionGeneration: 9,
			},
			surface: 'file',
			target: { path: 'README.md', targetKind: 'file', version: 'current' },
		};
		const activateReviewTarget = {
			bindingRevision: 6,
			commandId: 'navigation-review-item',
			commandKind: 'activateTarget',
			source: {
				generation: 11,
				metadataSourceId: 'accepted-review-source',
				packageId: 'accepted-review-package',
				sourceKind: 'review',
			},
			surface: 'review',
			target: { reviewItemId: 'review-item-7', targetKind: 'review' },
		};

		expect(bridgeProductNavigationCommandSchema.parse(activateContext)).toEqual(activateContext);
		expect(bridgeProductNavigationCommandSchema.parse(activateFileTarget)).toEqual(
			activateFileTarget,
		);
		expect(bridgeProductNavigationCommandSchema.parse(activateReviewTarget)).toEqual(
			activateReviewTarget,
		);
		for (const malformed of [
			{ ...activateContext, restoreMemory: true },
			{ ...activateContext, commandKind: 'initialize' },
			{ ...activateContext, source: activateReviewTarget.source },
			{ ...activateFileTarget, source: activateReviewTarget.source },
			{ ...activateReviewTarget, target: activateFileTarget.target },
			{
				...activateReviewTarget,
				source: { ...activateReviewTarget.source, publicationId: 'not-navigation-identity' },
			},
		]) {
			expect(bridgeProductNavigationCommandSchema.safeParse(malformed).success).toBe(false);
		}
	});

	test('dispatches top-level control and metadata envelopes by kind', () => {
		expect(bridgeProductControlRequestSchema).toBeInstanceOf(z.ZodDiscriminatedUnion);
		expect(bridgeProductMetadataFrameSchema).toBeInstanceOf(z.ZodDiscriminatedUnion);
	});

	test('keeps the Swift and TypeScript corpora byte-identical at frozen hashes', () => {
		const fixturePairs = [
			{
				expectedHash: 'd4d1d6e1c588b378d3ee6d31ca99aa77c82cdbe440ddb0e3a34b829dd9ba46f7',
				kind: 'valid',
			},
			{
				expectedHash: '2b814082676fad29bbfe6d33531fa2434d1066f2d1ab7900aeef460f0bbe780d',
				kind: 'invalid',
			},
		] as const;

		for (const fixturePair of fixturePairs) {
			const relativeFixturePath = `${fixturePair.kind}/bridge-product-session-corpus.json`;
			const typeScriptBytes = readFileSync(
				new URL(
					`../../test-fixtures/bridge-contract-fixtures/${relativeFixturePath}`,
					import.meta.url,
				),
			);
			const swiftBytes = readFileSync(
				new URL(`../../../../Tests/BridgeContractFixtures/${relativeFixturePath}`, import.meta.url),
			);

			expect(swiftBytes.equals(typeScriptBytes)).toBe(true);
			expect(createHash('sha256').update(typeScriptBytes).digest('hex')).toBe(
				fixturePair.expectedHash,
			);
		}
	});

	test('accepts the nonsecret bootstrap and canonical capability header', () => {
		expect(bridgeProductSessionBootstrapSchema.parse(validProductSessionCorpus.bootstrap)).toEqual(
			validProductSessionCorpus.bootstrap,
		);
		const policyWithoutBatchDeadline = Object.fromEntries(
			Object.entries(validProductSessionCorpus.bootstrap.policy).filter(
				([key]): boolean => key !== 'viewBatchProgressDeadlineMilliseconds',
			),
		);
		expect(
			bridgeProductSessionBootstrapSchema.safeParse({
				...validProductSessionCorpus.bootstrap,
				policy: policyWithoutBatchDeadline,
			}).success,
		).toBe(false);
		expect(validProductSessionCorpus.bootstrap).not.toHaveProperty('initialSurface');
		expect(validProductSessionCorpus.bootstrap.policy.streamKeepaliveIntervalMilliseconds).toBe(
			350,
		);
		expect(validProductSessionCorpus.bootstrap).not.toHaveProperty('productCapabilityBytes');
		expect(validProductSessionCorpus.bootstrap).not.toHaveProperty('routes');
		expect(BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES).toBe(256 * 1024);
		expect(validProductSessionCorpus.bootstrap.policy.maximumRequestBodyBytes).toBe(
			BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
		);
		for (const capabilityCase of validProductSessionCorpus.capabilityHeaderCases) {
			expect(encodeBridgeProductCapabilityHeader(capabilityCase.bytes)).toBe(
				capabilityCase.encoded,
			);
			expect(
				encodeBridgeProductCapabilityHeader(Uint8Array.from(capabilityCase.bytes).buffer),
			).toBe(capabilityCase.encoded);
			expect(capabilityCase.encoded).not.toMatch(/[+/=]/u);
		}
	});

	test('rejects every feature-shaped authority from the session bootstrap', () => {
		// Arrange
		const forbiddenBootstrapFields = [
			'rows',
			'descriptors',
			'contentMetadata',
			'renderSemantics',
			'telemetryConfiguration',
			'reviewSourceUpdate',
			'fileViewSourceUpdate',
		] as const;

		// Act
		const acceptanceByField = forbiddenBootstrapFields.map((field) => ({
			accepted: bridgeProductSessionBootstrapSchema.safeParse({
				...validProductSessionCorpus.bootstrap,
				[field]: {},
			}).success,
			field,
		}));

		// Assert
		expect(acceptanceByField).toEqual(
			forbiddenBootstrapFields.map((field) => ({ accepted: false, field })),
		);
	});

	test('accepts every closed request, response, metadata, and content variant', () => {
		const resetFrame = {
			kind: 'subscription.reset',
			metadataStreamId: 'metadata-stream-1',
			paneSessionId: 'pane-session-1',
			reason: 'sequence_gap',
			streamSequence: 14,
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
			subscriptionSequence: 1,
			wireVersion: 2,
			workerDerivationEpoch: 7,
			workerInstanceId: 'worker-instance-1',
		} as const;
		const metadataFrames = [
			...validProductSessionCorpus.metadataFrames.map((frame) =>
				bridgeProductMetadataFrameSchema.parse(frame),
			),
			bridgeProductMetadataFrameSchema.parse(resetFrame),
		];
		const contentRequests = validProductSessionCorpus.contentRequests;
		const contentHeaders = validProductSessionCorpus.contentHeaders;
		expect(
			new Set(validProductSessionCorpus.controlRequests.map((request) => request.kind)),
		).toEqual(
			new Set([
				'workerSession.open',
				'product.call',
				'subscription.open',
				'subscription.cancel',
				'workerSession.resync',
			]),
		);
		expect(
			new Set(validProductSessionCorpus.controlResponses.map((response) => response.kind)),
		).toEqual(
			new Set([
				'workerSession.accepted',
				'call.completed',
				'subscription.openAccepted',
				'subscription.cancelAccepted',
				'resync.accepted',
				'request.error',
			]),
		);
		expect(new Set(metadataFrames.map((frame) => frame.kind))).toEqual(
			new Set([
				'metadataStream.accepted',
				'pane.presentation',
				'subscription.accepted',
				'subscription.reset',
				'subscription.end',
				'subscription.cancelled',
				'content.cancelled',
				'metadataStream.error',
			]),
		);
		expect(new Set(validProductSessionCorpus.contentHeaders.map((header) => header.kind))).toEqual(
			new Set([
				'content.accepted',
				'content.data',
				'content.end',
				'content.error',
				'content.reset',
			]),
		);
		for (const request of validProductSessionCorpus.controlRequests) {
			expect(bridgeProductControlRequestSchema.parse(request)).toEqual(request);
		}
		for (const response of validProductSessionCorpus.controlResponses) {
			expect(bridgeProductControlResponseSchema.parse(response)).toEqual(response);
		}
		for (const request of validProductSessionCorpus.metadataStreamRequests) {
			expect(bridgeProductMetadataStreamRequestSchema.parse(request)).toEqual(request);
		}
		for (const frame of metadataFrames) {
			expect(bridgeProductMetadataFrameSchema.parse(frame)).toEqual(frame);
		}
		const panePresentations = validProductSessionCorpus.metadataFrames.filter(
			(frame) => frame.kind === 'pane.presentation',
		);
		expect(panePresentations.map((presentation) => presentation.presentationRevision)).toEqual([
			1, 2, 3, 4,
		]);
		expect(panePresentations.map((presentation) => presentation.nativeActivity)).toEqual([
			'foreground',
			'loadedHidden',
			'dormant',
			'closed',
		]);
		expect(panePresentations.map((presentation) => presentation.refreshingLanes)).toEqual([
			['file', 'review'],
			[],
			[],
			[],
		]);
		for (const request of contentRequests) {
			expect(bridgeProductContentRequestSchema.parse(request)).toEqual(request);
		}
		for (const header of contentHeaders) {
			expect(bridgeProductContentHeaderSchema.parse(header)).toEqual(header);
		}
	});

	test('keeps pane-session contracts free of every derivation epoch', () => {
		const workerSessionOpen = validProductSessionCorpus.controlRequests.find(
			(request) => request.kind === 'workerSession.open',
		);
		if (workerSessionOpen === undefined) {
			throw new Error('Shared corpus is missing workerSession.open.');
		}
		const paneScopedCases = [
			{
				name: 'product session bootstrap',
				schema: bridgeProductSessionBootstrapSchema,
				value: validProductSessionCorpus.bootstrap,
			},
			{
				name: 'worker session open',
				schema: bridgeProductControlRequestSchema,
				value: workerSessionOpen,
			},
			...validProductSessionCorpus.controlResponses.map((response) => ({
				name: response.kind,
				schema: bridgeProductControlResponseSchema,
				value: bridgeProductControlResponseSchema.parse(response),
			})),
			...validProductSessionCorpus.metadataStreamRequests.map((request) => ({
				name: request.kind,
				schema: bridgeProductMetadataStreamRequestSchema,
				value: request,
			})),
			...validProductSessionCorpus.metadataFrames
				.filter(
					(frame) =>
						frame.kind === 'metadataStream.accepted' ||
						frame.kind === 'metadataStream.error' ||
						frame.kind === 'pane.presentation',
				)
				.map((frame) => ({
					name: frame.kind,
					schema: bridgeProductMetadataFrameSchema,
					value: bridgeProductMetadataFrameSchema.parse(frame),
				})),
		];

		for (const paneScopedCase of paneScopedCases) {
			expect(
				paneScopedCase.schema.safeParse(paneScopedCase.value).success,
				paneScopedCase.name,
			).toBe(true);
			expect(
				paneScopedCase.schema.safeParse({ ...paneScopedCase.value, workerEpoch: 3 }).success,
				`${paneScopedCase.name} rejects workerEpoch`,
			).toBe(false);
			expect(
				paneScopedCase.schema.safeParse({
					...paneScopedCase.value,
					workerDerivationEpoch: 3,
				}).success,
				`${paneScopedCase.name} rejects workerDerivationEpoch`,
			).toBe(false);
		}
	});

	test('requires a derivation epoch only on surface-scoped admission and push variants', () => {
		const surfaceScopedCases = [
			...validProductSessionCorpus.controlRequests
				.filter(
					(request) =>
						request.kind !== 'workerSession.open' && request.kind !== 'workerSession.resync',
				)
				.map((request) => ({
					name: request.kind,
					schema: bridgeProductControlRequestSchema,
					value: request,
				})),
			...validProductSessionCorpus.metadataFrames
				.filter(
					(frame) =>
						frame.kind !== 'metadataStream.accepted' &&
						frame.kind !== 'metadataStream.error' &&
						frame.kind !== 'pane.presentation',
				)
				.map((frame) => ({
					name: frame.kind,
					schema: bridgeProductMetadataFrameSchema,
					value: bridgeProductMetadataFrameSchema.parse(frame),
				})),
			...validProductSessionCorpus.contentRequests.map((request) => ({
				name: request.kind,
				schema: bridgeProductContentRequestSchema,
				value: bridgeProductContentRequestSchema.parse(request),
			})),
			...validProductSessionCorpus.contentHeaders
				.filter((header) => header.kind === 'content.accepted')
				.map((header) => ({
					name: header.kind,
					schema: bridgeProductContentHeaderSchema,
					value: bridgeProductContentHeaderSchema.parse(header),
				})),
		];

		for (const surfaceScopedCase of surfaceScopedCases) {
			expect(
				surfaceScopedCase.schema.safeParse(surfaceScopedCase.value).success,
				surfaceScopedCase.name,
			).toBe(true);
			expect(
				surfaceScopedCase.schema.safeParse(withoutWorkerDerivationEpoch(surfaceScopedCase.value))
					.success,
				`${surfaceScopedCase.name} requires workerDerivationEpoch`,
			).toBe(false);
			expect(
				surfaceScopedCase.schema.safeParse(
					withWorkerEpoch(withoutWorkerDerivationEpoch(surfaceScopedCase.value)),
				).success,
				`${surfaceScopedCase.name} rejects workerEpoch`,
			).toBe(false);
			expect(
				surfaceScopedCase.schema.safeParse({ ...surfaceScopedCase.value, surface: 'review' })
					.success,
				`${surfaceScopedCase.name} derives rather than repeats surface`,
			).toBe(false);
		}
	});

	test('derives active viewer call surface from the closed method without repeated surface fields', () => {
		const identity = {
			kind: 'product.call',
			paneSessionId: 'pane-session-1',
			requestId: 'active-mode-call-1',
			requestSequence: 2,
			wireVersion: 2,
			workerDerivationEpoch: 4,
			workerInstanceId: 'worker-instance-1',
		};
		const reviewCall = {
			...identity,
			call: {
				method: 'review.activeViewerMode.update',
				request: {
					activeSource: { generation: 3, streamId: 'review-stream-1' },
					nativeSelectionRequestId: 'native-selection-review',
					sequence: 7,
					sessionId: 'viewer-session-1',
				},
			},
		};
		const fileCall = {
			...identity,
			call: {
				method: 'file.activeViewerMode.update',
				request: {
					activeSource: { generation: 5, streamId: 'file-stream-1' },
					nativeSelectionRequestId: null,
					sequence: 8,
					sessionId: 'viewer-session-1',
				},
			},
			requestId: 'active-mode-call-2',
			requestSequence: 3,
		};

		expect(bridgeProductControlRequestSchema.parse(reviewCall)).toEqual(reviewCall);
		expect(bridgeProductControlRequestSchema.parse(fileCall)).toEqual(fileCall);
		for (const repeatedField of [
			{ mode: 'review' },
			{ protocol: 'review' },
			{ surface: 'review' },
		]) {
			expect(
				bridgeProductControlRequestSchema.safeParse({
					...reviewCall,
					call: {
						...reviewCall.call,
						request: { ...reviewCall.call.request, ...repeatedField },
					},
				}).success,
			).toBe(false);
		}
	});

	test('reserves accepted and terminal successors for every resumable stream cursor', () => {
		const resyncRequest = validProductSessionCorpus.controlRequests.find(
			(request) => request.kind === 'workerSession.resync',
		);
		const resyncAccepted = validProductSessionCorpus.controlResponses.find(
			(response) => response.kind === 'resync.accepted',
		);
		const metadataStreamRequest = validProductSessionCorpus.metadataStreamRequests[0];
		if (
			resyncRequest === undefined ||
			resyncAccepted === undefined ||
			metadataStreamRequest === undefined
		) {
			throw new Error('Shared corpus is missing a resumable stream contract.');
		}
		const firstNonresumableSequence = BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE + 1;
		const finalAdmissibleResyncPredecessor = BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE - 1;

		expect(
			bridgeProductControlRequestSchema.safeParse({
				...resyncRequest,
				lastAcceptedRequestSequence: finalAdmissibleResyncPredecessor,
				requestSequence: BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
			}).success,
		).toBe(true);
		expect(
			bridgeProductControlRequestSchema.safeParse({
				...resyncRequest,
				lastAcceptedRequestSequence: BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
				requestSequence: Number.MAX_SAFE_INTEGER,
			}).success,
		).toBe(false);

		expect(
			bridgeProductControlRequestSchema.safeParse({
				...resyncRequest,
				lastAcceptedStreamSequence: BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
			}).success,
		).toBe(true);
		expect(
			bridgeProductControlRequestSchema.safeParse({
				...resyncRequest,
				lastAcceptedStreamSequence: firstNonresumableSequence,
			}).success,
		).toBe(false);

		expect(
			bridgeProductControlResponseSchema.safeParse({
				...resyncAccepted,
				metadataStreamSequenceBarrier: BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
			}).success,
		).toBe(true);
		expect(
			bridgeProductControlResponseSchema.safeParse({
				...resyncAccepted,
				metadataStreamSequenceBarrier: firstNonresumableSequence,
			}).success,
		).toBe(false);

		expect(
			bridgeProductMetadataStreamRequestSchema.safeParse({
				...metadataStreamRequest,
				resumeFromStreamSequence: BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
			}).success,
		).toBe(true);
		expect(
			bridgeProductMetadataStreamRequestSchema.safeParse({
				...metadataStreamRequest,
				resumeFromStreamSequence: firstNonresumableSequence,
			}).success,
		).toBe(false);
	});

	test('resumed and snapshot-required acceptance consume the next physical sequence', () => {
		const freshAccepted = bridgeProductMetadataFrameSchema.parse(
			validProductSessionCorpus.metadataFrames.find(
				(frame) => frame.kind === 'metadataStream.accepted',
			),
		);
		if (freshAccepted.kind !== 'metadataStream.accepted') {
			throw new Error('Shared corpus did not decode metadataStream.accepted.');
		}
		const freshRequest = bridgeProductMetadataStreamRequestSchema.parse(
			validProductSessionCorpus.metadataStreamRequests.find(
				(request) => request.resumeFromStreamSequence === null,
			),
		);
		const resumedRequest = bridgeProductMetadataStreamRequestSchema.parse({
			...freshRequest,
			resumeFromStreamSequence: 6,
		});
		const resumedAccepted = {
			...freshAccepted,
			resumeDisposition: 'resumed',
			streamSequence: 7,
		} as const;
		const snapshotRequiredAccepted = {
			...freshAccepted,
			resumeDisposition: 'snapshot_required',
			streamSequence: 7,
		} as const;

		expect(bridgeProductMetadataFrameSchema.safeParse(freshAccepted).success).toBe(true);
		expect(bridgeProductMetadataFrameSchema.safeParse(resumedAccepted).success).toBe(true);
		expect(bridgeProductMetadataFrameSchema.safeParse(snapshotRequiredAccepted).success).toBe(true);
		expect(bridgeProductMetadataAcceptedStreamSequence(freshRequest)).toBe(0);
		expect(bridgeProductMetadataAcceptedStreamSequence(resumedRequest)).toBe(7);
	});

	test('rejects every hostile shared-corpus case at its receiving boundary', () => {
		for (const hostileCase of invalidProductSessionCorpus.cases) {
			expect(
				hostileContractRejects(hostileCase.contract, hostileCase.value),
				hostileCase.name,
			).toBe(true);
		}
	});

	test("view scope owns each metadata kind's admitted demand", () => {
		const requests = validProductSessionCorpus.transportV2.viewScopeRequests;
		const fileRequest = requests.find((request) => request.subscriptionKind === 'file.metadata');
		const reviewRequest = requests.find(
			(request) => request.subscriptionKind === 'review.metadata',
		);
		if (fileRequest === undefined || reviewRequest === undefined)
			throw new Error('File and Review scope fixtures are required.');
		expect(bridgeProductControlRequestSchema.safeParse(fileRequest).success).toBe(true);
		expect(bridgeProductControlRequestSchema.safeParse(reviewRequest).success).toBe(true);
		for (const scope of [
			{ kind: 'file', changeFilter: { kind: 'none' }, pathScope: [] },
			{ kind: 'file', changeFilter: { kind: 'none' }, interests: [] },
			{ kind: 'review' },
		]) {
			const request = scope.kind === 'review' ? reviewRequest : fileRequest;
			expect(bridgeProductControlRequestSchema.safeParse({ ...request, scope }).success).toBe(
				false,
			);
		}
		expect(
			bridgeProductControlRequestSchema.safeParse({
				...fileRequest,
				scope: { kind: 'review', interests: [] },
			}).success,
		).toBe(false);
	});

	test('rejects the obsolete generic payload and resource GET corridors', () => {
		expect(
			bridgeProductControlRequestSchema.safeParse({
				kind: 'product.command',
				wireVersion: 2,
				paneSessionId: 'pane-session-1',
				workerInstanceId: 'worker-instance-1',
				requestId: 'request-generic-1',
				requestSequence: 1,
				command: { name: 'review.refresh', payload: { arbitrary: true } },
			}).success,
		).toBe(false);
		expect(
			bridgeProductSessionBootstrapSchema.safeParse({
				...validProductSessionCorpus.bootstrap,
				routes: {
					command: { method: 'POST', url: 'agentstudio://rpc/command' },
					resource: { method: 'GET', urlPrefix: 'agentstudio://resource/' },
					stream: { method: 'POST', url: 'agentstudio://rpc/stream' },
				},
			}).success,
		).toBe(false);
	});

	test('rejects exact Kelvin-sign key lookalikes before typed handler admission', () => {
		const hostileRawBodies = [
			'{"\\u212Aind":"content.data","contentSequence":1,"offsetBytes":0}',
			'{"kind":"content.data","\\u212Aind":"content.data","contentSequence":1,"offsetBytes":0}',
		];

		for (const hostileRawBody of hostileRawBodies) {
			const parsedBody = parseBridgeProductStrictJSON(new TextEncoder().encode(hostileRawBody));
			expect(bridgeProductContentHeaderSchema.safeParse(parsedBody).success).toBe(false);
		}
	});

	test('requires one exact 32-byte product capability in the install message', () => {
		const productChannel = new MessageChannel();
		const validCapability = new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);
		const shortCapability = new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH - 1);

		expect(
			bridgePaneCommWorkerInstallSchema.safeParse({
				bootstrap: validProductSessionCorpus.bootstrap,
				kind: 'bridgePaneCommWorker.install',
				productCapability: validCapability,
				productPort: productChannel.port1,
			}).success,
		).toBe(true);
		expect(
			bridgePaneCommWorkerInstallSchema.safeParse({
				bootstrap: validProductSessionCorpus.bootstrap,
				kind: 'bridgePaneCommWorker.install',
				productCapability: shortCapability,
				productPort: productChannel.port1,
			}).success,
		).toBe(false);

		productChannel.port1.close();
		productChannel.port2.close();
	});

	test('transfers the install port and capability and proves sender detachment', async () => {
		const bootstrapChannel = new MessageChannel();
		const productChannel = new MessageChannel();
		const productCapability = new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);
		const receivedInstall = new Promise<unknown>((resolve) => {
			bootstrapChannel.port2.addEventListener(
				'message',
				(event): void => {
					resolve(event.data);
				},
				{ once: true },
			);
			bootstrapChannel.port2.start();
		});

		postBridgePaneCommWorkerInstall(bootstrapChannel.port1, {
			bootstrap: bridgeProductSessionBootstrapSchema.parse(validProductSessionCorpus.bootstrap),
			kind: 'bridgePaneCommWorker.install',
			productCapability,
			productPort: productChannel.port1,
		});

		expect(productCapability.byteLength).toBe(0);
		const install = bridgePaneCommWorkerInstallSchema.parse(await receivedInstall);
		expect(install.productCapability.byteLength).toBe(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH);

		install.productPort.close();
		productChannel.port2.close();
		bootstrapChannel.port1.close();
		bootstrapChannel.port2.close();
	});

	test('incrementally decodes one physical metadata stream across Review and File', () => {
		const encodedFrames = validProductSessionCorpus.metadataFrames
			.filter((frame) => frame.metadataStreamId === 'metadata-stream-1')
			.slice(0, 5)
			.map((frame) =>
				encodeBridgeProductMetadataFrame(bridgeProductMetadataFrameSchema.parse(frame)),
			);
		const wireBytes = concatenateBytes(...encodedFrames);
		const decoder = new BridgeProductMetadataFrameDecoder();

		const first = decoder.push(wireBytes.subarray(0, 2));
		const middle = decoder.push(wireBytes.subarray(2, encodedFrames[0]?.byteLength ?? 2));
		const rest = decoder.push(wireBytes.subarray(encodedFrames[0]?.byteLength ?? 2));
		decoder.finish();
		const oneByteDecoder = new BridgeProductMetadataFrameDecoder();
		let oneByteDecodedFrameCount = 0;
		for (let offset = 0; offset < wireBytes.byteLength; offset += 1) {
			oneByteDecodedFrameCount += oneByteDecoder.push(
				wireBytes.subarray(offset, offset + 1),
			).length;
		}
		oneByteDecoder.finish();

		expect(first).toEqual([]);
		expect(middle.map((frame) => frame.kind)).toEqual(['metadataStream.accepted']);
		expect(rest.map((frame) => frame.kind)).toEqual([
			'subscription.accepted',
			'subscription.accepted',
			'subscription.accepted',
			'subscription.accepted',
		]);
		expect(rest.map((frame) => frame.streamSequence)).toEqual([1, 2, 3, 4]);
		expect(oneByteDecodedFrameCount).toBe(encodedFrames.length);
		expect(oneByteDecoder.diagnostics).toMatchObject({
			consumedByteCount: wireBytes.byteLength,
			copiedByteCount: wireBytes.byteLength,
			discardedTailByteCount: 0,
			emittedFrameCount: encodedFrames.length,
			failureCode: null,
			receivedByteCount: wireBytes.byteLength,
			retainedByteCount: 0,
			state: 'finished',
		});
	});

	test('poisons metadata framing after a fatal push or finish failure', () => {
		const validFrame = encodeBridgeProductMetadataFrame(
			bridgeProductMetadataFrameSchema.parse(validProductSessionCorpus.metadataFrames[0]),
		);
		const invalidLength = Uint8Array.of(0, 0, 0, 0);
		const invalidDecoder = new BridgeProductMetadataFrameDecoder();

		expect(() => invalidDecoder.push(invalidLength)).toThrow(/length/iu);
		expect(() => invalidDecoder.push(validFrame)).toThrow(/poisoned/iu);

		const truncatedDecoder = new BridgeProductMetadataFrameDecoder();
		truncatedDecoder.push(validFrame.subarray(0, validFrame.byteLength - 1));
		expect(() => truncatedDecoder.finish()).toThrow(/truncated/iu);
		expect(() => truncatedDecoder.push(validFrame)).toThrow(/poisoned/iu);
	});

	test('matches the shared literal metadata and binary content wire vectors', () => {
		const metadataFrame = bridgeProductMetadataFrameSchema.parse(
			validProductSessionCorpus.metadataFrames[0],
		);
		const encodedMetadata = encodeBridgeProductMetadataFrame(metadataFrame);
		expect(Buffer.from(encodedMetadata).toString('base64')).toBe(
			validProductSessionCorpus.wireVectors.metadataAccepted.encodedBase64,
		);
		const metadataDecoder = new BridgeProductMetadataFrameDecoder();
		expect(
			metadataDecoder.push(
				Uint8Array.from(
					Buffer.from(
						validProductSessionCorpus.wireVectors.metadataAccepted.encodedBase64,
						'base64',
					),
				),
			),
		).toEqual([metadataFrame]);
		metadataDecoder.finish();

		const contentRequest = bridgeProductContentRequestSchema.parse(
			validProductSessionCorpus.contentRequests[0],
		);
		const contentAcceptedHeader = bridgeProductContentHeaderSchema.parse(
			validProductSessionCorpus.contentHeaders.find((header) => header.kind === 'content.accepted'),
		);
		const contentHeader = bridgeProductContentHeaderSchema.parse(
			validProductSessionCorpus.contentHeaders.find((header) => header.kind === 'content.data'),
		);
		const contentEndHeader = bridgeProductContentHeaderSchema.parse(
			validProductSessionCorpus.contentHeaders.find((header) => header.kind === 'content.end'),
		);
		const contentPayload = Uint8Array.from(
			Buffer.from(validProductSessionCorpus.wireVectors.contentData.payloadBase64, 'base64'),
		);
		const contentEncoder = new BridgeProductContentFrameEncoder(contentRequest);
		const encodedAccepted = contentEncoder.encode({
			header: contentAcceptedHeader,
			payload: new Uint8Array(),
		});
		const encodedContent = contentEncoder.encode({
			header: contentHeader,
			payload: contentPayload,
		});
		const encodedEnd = contentEncoder.encode({
			header: contentEndHeader,
			payload: new Uint8Array(),
		});
		contentEncoder.finish();
		expect(Buffer.from(encodedContent).toString('base64')).toBe(
			validProductSessionCorpus.wireVectors.contentData.encodedBase64,
		);
		expect(Buffer.from(encodedContent).toString('hex')).toBe(
			validProductSessionCorpus.wireVectors.contentData.encodedHex,
		);
		expect(new TextDecoder().decode(encodedAccepted.subarray(9))).toBe(
			validProductSessionCorpus.wireVectors.contentStream.acceptedBodyJSON,
		);
		expect(new TextDecoder().decode(encodedEnd.subarray(9))).toBe(
			validProductSessionCorpus.wireVectors.contentStream.endBodyJSON,
		);
		const encodedContentStream = Buffer.concat([encodedAccepted, encodedContent, encodedEnd]);
		expect(encodedContentStream.byteLength).toBe(
			validProductSessionCorpus.wireVectors.contentStream.encodedByteLength,
		);
		expect(encodedContentStream.toString('base64')).toBe(
			validProductSessionCorpus.wireVectors.contentStream.encodedBase64,
		);
		const contentDecoder = new BridgeProductContentFrameDecoder();
		const decodedContentFrames = contentDecoder.push(
			Uint8Array.from(
				Buffer.from(validProductSessionCorpus.wireVectors.contentStream.encodedBase64, 'base64'),
			),
		);
		expect(decodedContentFrames).toEqual([
			{ header: contentAcceptedHeader, payload: new Uint8Array() },
			{ header: contentHeader, payload: contentPayload },
			{ header: contentEndHeader, payload: new Uint8Array() },
		]);
		expect(decodedContentFrames).toHaveLength(
			validProductSessionCorpus.wireVectors.contentStream.frameCount,
		);
		contentDecoder.finish();
	});
});

function hostileContractRejects(contract: string, value: unknown): boolean {
	switch (contract) {
		case 'bootstrap':
			return !bridgeProductSessionBootstrapSchema.safeParse(value).success;
		case 'contentHeader':
			return !bridgeProductContentHeaderSchema.safeParse(value).success;
		case 'contentRequest':
			return !bridgeProductContentRequestSchema.safeParse(value).success;
		case 'controlRequest':
			return registeredControlRequestRejects(value);
		case 'controlResponse':
			return !bridgeProductControlResponseSchema.safeParse(value).success;
		case 'metadataFrame':
			return !bridgeProductMetadataFrameSchema.safeParse(value).success;
		case 'metadataStreamRequest':
			return !bridgeProductMetadataStreamRequestSchema.safeParse(value).success;
		default:
			throw new Error(`Unknown hostile Bridge product contract: ${contract}`);
	}
}

function registeredControlRequestRejects(value: unknown): boolean {
	try {
		parseBridgeProductRegisteredControlRequest(value);
		return false;
	} catch {
		return true;
	}
}

function concatenateBytes(...parts: readonly Uint8Array[]): Uint8Array {
	const result = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0));
	let offset = 0;
	for (const part of parts) {
		result.set(part, offset);
		offset += part.byteLength;
	}
	return result;
}

function withoutWorkerDerivationEpoch(value: unknown): unknown {
	if (!isRecord(value)) return value;
	const { workerDerivationEpoch: _workerDerivationEpoch, ...withoutEpoch } = value;
	return withoutEpoch;
}

function withWorkerEpoch(value: unknown): unknown {
	return isRecord(value) ? { ...value, workerEpoch: 3 } : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
