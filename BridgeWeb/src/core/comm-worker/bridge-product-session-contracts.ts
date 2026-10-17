import { z } from 'zod';

import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductCallRequestSchema,
	bridgeProductCallResultSchema,
} from './bridge-product-call-contracts.js';
import { bridgeProductContentIdentitySchema } from './bridge-product-content-contracts.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_ACTIVE_SUBSCRIPTION_COUNT,
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
	bridgeProductDisplayPathSchema,
	bridgeProductIdentifierSchema,
	bridgeProductNonnegativeSequenceSchema,
	bridgeProductPositiveSequenceSchema,
	bridgeProductRequestErrorCodeSchema,
	bridgeProductResetReasonSchema,
	bridgeProductSafeMessageSchema,
	bridgeProductSha256Schema,
	bridgeProductSurfaceSchema,
} from './bridge-product-contract-primitives.js';
import { bridgeProductMetadataApplicationKindSchema } from './bridge-product-metadata-application-protocol.js';
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import {
	bridgeProductViewAcceptedResponseSchema,
	bridgeProductViewResnapshotRequestSchema,
	bridgeProductViewScopeRequestSchema,
} from './bridge-product-view-control-wire-contracts.js';

export { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';

const bridgeProductControlIdentityShape = {
	paneSessionId: bridgeProductIdentifierSchema,
	requestId: bridgeProductIdentifierSchema,
	requestSequence: bridgeProductPositiveSequenceSchema.max(
		BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE,
	),
	wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
	workerInstanceId: bridgeProductIdentifierSchema,
} as const;

const bridgeProductSurfaceRequestIdentityShape = {
	...bridgeProductControlIdentityShape,
	workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
} as const;

const bridgeProductSubscriptionControlIdentityShape = {
	subscriptionId: bridgeProductIdentifierSchema,
	subscriptionKind: bridgeProductMetadataApplicationKindSchema,
} as const;

const bridgeProductSubscriptionOpenAcceptedSchema = z.discriminatedUnion('subscriptionKind', [
	z
		.object({
			...bridgeProductControlIdentityShape,
			...bridgeProductSubscriptionControlIdentityShape,
			kind: z.literal('subscription.openAccepted'),
			subscriptionKind: z.enum(['file.annotations', 'review.annotations']),
			worktreeId: bridgeProductIdentifierSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductControlIdentityShape,
			...bridgeProductSubscriptionControlIdentityShape,
			kind: z.literal('subscription.openAccepted'),
			subscriptionKind: z.enum(['file.metadata', 'review.metadata']),
		})
		.strict(),
]);

const bridgeProductNavigationFileSourceSchema = z
	.object({
		sourceId: bridgeProductIdentifierSchema,
		sourceKind: z.literal('file'),
		subscriptionGeneration: bridgeProductNonnegativeSequenceSchema,
	})
	.strict();

const bridgeProductNavigationReviewSourceSchema = z
	.object({
		generation: bridgeProductNonnegativeSequenceSchema,
		metadataSourceId: bridgeProductIdentifierSchema,
		packageId: bridgeProductIdentifierSchema,
		sourceKind: z.literal('review'),
	})
	.strict();

const bridgeProductNavigationFileTargetSchema = z
	.object({
		path: bridgeProductDisplayPathSchema,
		targetKind: z.literal('file'),
		version: z.enum(['base', 'head', 'current']),
	})
	.strict();

const bridgeProductNavigationReviewTargetSchema = z
	.object({
		path: bridgeProductDisplayPathSchema.optional(),
		reviewItemId: bridgeProductIdentifierSchema.optional(),
		targetKind: z.literal('review'),
		version: z.enum(['base', 'head', 'current']).optional(),
	})
	.strict()
	.superRefine((target, context): void => {
		if (target.path === undefined && target.reviewItemId === undefined) {
			context.addIssue({
				code: 'custom',
				message: 'Review navigation target requires an item or file path.',
			});
		}
		if ((target.path === undefined) !== (target.version === undefined)) {
			context.addIssue({
				code: 'custom',
				message: 'Review navigation file path and version must be supplied together.',
			});
		}
	});

const bridgeProductNavigationCommandIdentityShape = {
	bindingRevision: bridgeProductPositiveSequenceSchema,
	commandId: bridgeProductIdentifierSchema,
} as const;

export const bridgeProductNavigationCommandSchema = z.discriminatedUnion('commandKind', [
	z
		.object({
			...bridgeProductNavigationCommandIdentityShape,
			commandKind: z.literal('activateContext'),
			surface: bridgeProductSurfaceSchema,
		})
		.strict(),
	z.discriminatedUnion('surface', [
		z
			.object({
				...bridgeProductNavigationCommandIdentityShape,
				commandKind: z.literal('activateTarget'),
				source: bridgeProductNavigationFileSourceSchema,
				surface: z.literal('file'),
				target: bridgeProductNavigationFileTargetSchema,
			})
			.strict(),
		z
			.object({
				...bridgeProductNavigationCommandIdentityShape,
				commandKind: z.literal('activateTarget'),
				source: bridgeProductNavigationReviewSourceSchema,
				surface: z.literal('review'),
				target: bridgeProductNavigationReviewTargetSchema,
			})
			.strict(),
	]),
]);

export type BridgeProductNavigationCommand = z.infer<typeof bridgeProductNavigationCommandSchema>;

const bridgeProductActiveSubscriptionSchema = z
	.object({
		...bridgeProductSubscriptionControlIdentityShape,
		workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
	})
	.strict();

const bridgeProductResyncReconciliationCommonShape = {
	subscriptionId: bridgeProductIdentifierSchema,
	subscriptionKind: bridgeProductMetadataApplicationKindSchema,
} as const;

export const bridgeProductResyncReconciliationOutcomeSchema = z.discriminatedUnion('disposition', [
	z
		.object({
			...bridgeProductResyncReconciliationCommonShape,
			disposition: z.literal('retained'),
			workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductResyncReconciliationCommonShape,
			disposition: z.literal('cancelled'),
			priorWorkerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
			reason: z.enum(['native_revoked', 'source_unavailable']),
		})
		.strict(),
	z
		.object({
			...bridgeProductResyncReconciliationCommonShape,
			disposition: z.literal('reopenRequired'),
			reason: z.enum([
				'epoch_advanced',
				'identity_mismatch',
				'native_missing',
				'snapshot_required',
			]),
			requiredWorkerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
		})
		.strict(),
]);

const bridgeProductRawApplicationObjectSchema = z
	.object({ subscriptionKind: bridgeProductMetadataApplicationKindSchema })
	.catchall(z.unknown());

export const bridgeProductControlRequestSchema = z.discriminatedUnion('kind', [
	z
		.object({
			...bridgeProductControlIdentityShape,
			kind: z.literal('workerSession.open'),
			request: z.null(),
		})
		.strict(),
	z
		.object({
			...bridgeProductSurfaceRequestIdentityShape,
			call: bridgeProductCallRequestSchema,
			kind: z.literal('product.call'),
		})
		.strict(),
	z
		.object({
			...bridgeProductSurfaceRequestIdentityShape,
			kind: z.literal('subscription.open'),
			subscription: bridgeProductRawApplicationObjectSchema,
			subscriptionId: bridgeProductIdentifierSchema,
		})
		.strict(),
	bridgeProductViewScopeRequestSchema,
	bridgeProductViewResnapshotRequestSchema,
	z
		.object({
			...bridgeProductSurfaceRequestIdentityShape,
			...bridgeProductSubscriptionControlIdentityShape,
			kind: z.literal('subscription.cancel'),
		})
		.strict(),
	z
		.object({
			...bridgeProductControlIdentityShape,
			activeSubscriptions: z
				.array(bridgeProductActiveSubscriptionSchema)
				.max(BRIDGE_PRODUCT_MAXIMUM_ACTIVE_SUBSCRIPTION_COUNT)
				.refine(
					(subscriptions) =>
						new Set(subscriptions.map((subscription) => subscription.subscriptionId)).size ===
						subscriptions.length,
					'Duplicate active Bridge product subscription id.',
				)
				.readonly(),
			kind: z.literal('workerSession.resync'),
			lastAcceptedRequestSequence: bridgeProductNonnegativeSequenceSchema.max(
				BRIDGE_PRODUCT_MAXIMUM_CONTROL_REQUEST_SEQUENCE - 1,
			),
			lastAcceptedStreamSequence: bridgeProductNonnegativeSequenceSchema.max(
				BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
			),
		})
		.strict(),
]);

export const bridgeProductControlResponseSchema = z.discriminatedUnion('kind', [
	...bridgeProductViewAcceptedResponseSchema.options,
	z
		.object({
			...bridgeProductControlIdentityShape,
			kind: z.literal('workerSession.accepted'),
			result: z.null(),
		})
		.strict(),
	z
		.object({
			...bridgeProductControlIdentityShape,
			call: bridgeProductCallResultSchema,
			kind: z.literal('call.completed'),
		})
		.strict(),
	bridgeProductSubscriptionOpenAcceptedSchema,
	z
		.object({
			...bridgeProductControlIdentityShape,
			...bridgeProductSubscriptionControlIdentityShape,
			kind: z.literal('subscription.cancelAccepted'),
		})
		.strict(),
	z
		.object({
			...bridgeProductControlIdentityShape,
			kind: z.literal('resync.accepted'),
			metadataStreamSequenceBarrier: bridgeProductNonnegativeSequenceSchema.max(
				BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE,
			),
			nextExpectedRequestSequence: bridgeProductPositiveSequenceSchema,
			reconciliation: z
				.array(bridgeProductResyncReconciliationOutcomeSchema)
				.max(BRIDGE_PRODUCT_MAXIMUM_ACTIVE_SUBSCRIPTION_COUNT)
				.readonly(),
		})
		.strict(),
	z
		.object({
			...bridgeProductControlIdentityShape,
			code: bridgeProductRequestErrorCodeSchema,
			kind: z.literal('request.error'),
			nextExpectedRequestSequence: bridgeProductPositiveSequenceSchema.nullable(),
			retryAfterMilliseconds: bridgeProductNonnegativeSequenceSchema.nullable(),
			retryable: z.boolean(),
			safeMessage: bridgeProductSafeMessageSchema.nullable(),
		})
		.strict(),
]);

export const bridgeProductMetadataStreamRequestSchema = z
	.object({
		kind: z.literal('metadataStream.open'),
		metadataStreamId: bridgeProductIdentifierSchema,
		paneSessionId: bridgeProductIdentifierSchema,
		resumeFromStreamSequence: bridgeProductNonnegativeSequenceSchema
			.max(BRIDGE_PRODUCT_MAXIMUM_RESUMABLE_STREAM_SEQUENCE)
			.nullable(),
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

const bridgeProductMetadataFrameIdentityShape = {
	metadataStreamId: bridgeProductIdentifierSchema,
	paneSessionId: bridgeProductIdentifierSchema,
	streamSequence: bridgeProductNonnegativeSequenceSchema,
	wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
	workerInstanceId: bridgeProductIdentifierSchema,
} as const;

export const bridgeProductFileRefreshFailureSchema = z.discriminatedUnion('failureKind', [
	z.object({ failureKind: z.literal('missingRoot'), retryable: z.literal(true) }).strict(),
	z.object({ failureKind: z.literal('unreadableRoot'), retryable: z.literal(true) }).strict(),
	z.object({ failureKind: z.literal('fileRefreshFailed'), retryable: z.literal(false) }).strict(),
	z
		.object({ failureKind: z.literal('fileSourceUnavailable'), retryable: z.literal(true) })
		.strict(),
	z.object({ failureKind: z.literal('producerRejected'), retryable: z.literal(false) }).strict(),
]);

const bridgeProductSubscriptionFrameIdentityShape = {
	subscriptionId: bridgeProductIdentifierSchema,
	subscriptionKind: bridgeProductMetadataApplicationKindSchema,
	subscriptionSequence: bridgeProductNonnegativeSequenceSchema,
	workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
} as const;

const bridgeProductMetadataFrameStructuralSchema = z.discriminatedUnion('kind', [
	...bridgeProductBatchFrameSchema.options,
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			kind: z.literal('stream.keepalive'),
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			kind: z.literal('metadataStream.accepted'),
			resumeDisposition: z.enum(['resumed', 'snapshot_required']),
			streamSequence: bridgeProductNonnegativeSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			fileRefreshFailure: bridgeProductFileRefreshFailureSchema.nullable(),
			kind: z.literal('pane.presentation'),
			operationCorrelationId: bridgeProductSha256Schema.nullable(),
			nativeActivity: z.enum(['foreground', 'loadedHidden', 'dormant', 'closed']),
			presentationRevision: bridgeProductPositiveSequenceSchema,
			refreshingLanes: z
				.array(z.enum(['file', 'review']))
				.max(2)
				.refine(
					(lanes): boolean => {
						if (new Set(lanes).size !== lanes.length) return false;
						return lanes.every((lane, index): boolean => {
							if (index === 0) return true;
							const precedingLane = lanes[index - 1];
							return precedingLane !== undefined && precedingLane < lane;
						});
					},
					{ message: 'Bridge pane refreshing lanes must be unique and canonical.' },
				),
			reviewComparison: bridgeProductReviewComparisonPresentationSchema.nullable(),
			streamSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			kind: z.literal('pane.surfaceSelectionRequested'),
			navigationCommand: bridgeProductNavigationCommandSchema,
			streamSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			...bridgeProductSubscriptionFrameIdentityShape,
			kind: z.literal('subscription.accepted'),
			streamSequence: bridgeProductPositiveSequenceSchema,
			subscriptionSequence: z.literal(0),
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			...bridgeProductSubscriptionFrameIdentityShape,
			kind: z.literal('subscription.reset'),
			reason: bridgeProductResetReasonSchema,
			streamSequence: bridgeProductPositiveSequenceSchema,
			subscriptionSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			...bridgeProductSubscriptionFrameIdentityShape,
			kind: z.literal('subscription.end'),
			streamSequence: bridgeProductPositiveSequenceSchema,
			subscriptionSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			...bridgeProductSubscriptionFrameIdentityShape,
			kind: z.literal('subscription.cancelled'),
			streamSequence: bridgeProductPositiveSequenceSchema,
			subscriptionSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			contentRequestId: bridgeProductIdentifierSchema,
			disposition: z.enum(['stopped', 'already_terminal']),
			identity: bridgeProductContentIdentitySchema,
			kind: z.literal('content.cancelled'),
			leaseId: bridgeProductIdentifierSchema,
			operationCorrelationId: bridgeProductSha256Schema.nullable(),
			streamSequence: bridgeProductPositiveSequenceSchema,
			workerDerivationEpoch: bridgeProductNonnegativeSequenceSchema,
		})
		.strict(),
	z
		.object({
			...bridgeProductMetadataFrameIdentityShape,
			code: bridgeProductRequestErrorCodeSchema,
			kind: z.literal('metadataStream.error'),
			retryable: z.boolean(),
			safeMessage: bridgeProductSafeMessageSchema.nullable(),
			streamSequence: bridgeProductPositiveSequenceSchema,
		})
		.strict(),
]);

const bridgeProductMetadataFrameEncoder = new TextEncoder();

export const bridgeProductMetadataFrameSchema =
	bridgeProductMetadataFrameStructuralSchema.superRefine((frame, context): void => {
		if (
			bridgeProductMetadataFrameEncoder.encode(JSON.stringify(frame)).byteLength >
			BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES
		) {
			context.addIssue({
				code: 'custom',
				message: 'Bridge product metadata frame exceeds its body ceiling.',
			});
		}
	});

const bridgeProductCapabilityBytesSchema = z
	.array(z.number().int().min(0).max(255))
	.length(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH)
	.readonly();

export const bridgeProductBootstrapPolicySchema = z
	.object({
		admissionRetryCount: bridgeProductNonnegativeSequenceSchema,
		contentProgressDeadlineMilliseconds: bridgeProductPositiveSequenceSchema,
		contentAcknowledgementDeadlineMilliseconds: bridgeProductPositiveSequenceSchema,
		viewBatchProgressDeadlineMilliseconds: bridgeProductPositiveSequenceSchema,
		maximumContentBytes: z
			.number()
			.int()
			.positive()
			.max(BRIDGE_PRODUCT_MAXIMUM_CONTENT_STREAM_BYTES),
		maximumRequestBodyBytes: z
			.number()
			.int()
			.positive()
			.max(BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES),
		maximumMetadataFrameBytes: z
			.number()
			.int()
			.positive()
			.max(BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES),
		maximumQueuedStreamBytes: z
			.number()
			.int()
			.positive()
			.max(BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES),
		maximumQueuedStreamFrames: z
			.number()
			.int()
			.positive()
			.max(BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES),
		terminalFrameReserve: z.literal(BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE),
		streamKeepaliveIntervalMilliseconds: bridgeProductPositiveSequenceSchema,
		telemetryPreReadyBufferMaxBytes: bridgeProductPositiveSequenceSchema,
		telemetryPreReadyBufferMaxSamples: bridgeProductPositiveSequenceSchema,
		viewAcknowledgementDeadlineMilliseconds: bridgeProductPositiveSequenceSchema,
		viewCreditBytes: bridgeProductPositiveSequenceSchema,
		viewCreditParts: bridgeProductPositiveSequenceSchema,
		viewMaximumConsecutiveResnapshots: bridgeProductPositiveSequenceSchema,
		viewMaximumDirtyKeys: bridgeProductPositiveSequenceSchema,
		workerSettlementDeadlineMilliseconds: bridgeProductPositiveSequenceSchema,
	})
	.strict();

export const bridgeProductSessionBootstrapSchema = z
	.object({
		kind: z.literal('productSession.bootstrap'),
		paneSessionId: bridgeProductIdentifierSchema,
		policy: bridgeProductBootstrapPolicySchema,
		wireVersion: z.literal(BRIDGE_PRODUCT_WIRE_VERSION),
		workerInstanceId: bridgeProductIdentifierSchema,
	})
	.strict();

const bridgeProductCapabilitySchema = z.custom<ArrayBuffer>(
	(value) =>
		value instanceof ArrayBuffer && value.byteLength === BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	'Bridge product capability must be one 32-byte ArrayBuffer.',
);
const bridgeProductMessagePortSchema = z.custom<MessagePort>(
	(value) =>
		typeof value === 'object' &&
		value !== null &&
		'addEventListener' in value &&
		typeof value.addEventListener === 'function' &&
		'postMessage' in value &&
		typeof value.postMessage === 'function' &&
		'close' in value &&
		typeof value.close === 'function' &&
		'start' in value &&
		typeof value.start === 'function',
	'Bridge pane comm-worker install requires a transferable MessagePort.',
);

export const bridgePaneCommWorkerInstallSchema = z
	.object({
		bootstrap: bridgeProductSessionBootstrapSchema,
		kind: z.literal('bridgePaneCommWorker.install'),
		productCapability: bridgeProductCapabilitySchema,
		productPort: bridgeProductMessagePortSchema,
	})
	.strict();

export type BridgeProductControlRequest = z.infer<typeof bridgeProductControlRequestSchema>;
export type BridgeProductControlResponse = z.infer<typeof bridgeProductControlResponseSchema>;
export type BridgeProductResyncReconciliationOutcome = z.infer<
	typeof bridgeProductResyncReconciliationOutcomeSchema
>;

export function assertBridgeProductResyncReconciliationMatchesRequest(props: {
	readonly request: BridgeProductControlRequest;
	readonly response: BridgeProductControlResponse;
}): void {
	if (props.request.kind !== 'workerSession.resync' || props.response.kind !== 'resync.accepted') {
		throw new Error('Bridge product reconciliation requires a resync request and response.');
	}
	if (props.request.activeSubscriptions.length !== props.response.reconciliation.length) {
		throw new Error('Bridge product reconciliation count does not match its request.');
	}
	for (const [index, activeSubscription] of props.request.activeSubscriptions.entries()) {
		const outcome = props.response.reconciliation[index];
		if (
			outcome === undefined ||
			outcome.subscriptionId !== activeSubscription.subscriptionId ||
			outcome.subscriptionKind !== activeSubscription.subscriptionKind
		) {
			throw new Error(
				'Bridge product reconciliation order or identity does not match its request.',
			);
		}
		switch (outcome.disposition) {
			case 'retained':
				if (outcome.workerDerivationEpoch !== activeSubscription.workerDerivationEpoch) {
					throw new Error(
						'Bridge product retained reconciliation epoch does not match its request.',
					);
				}
				break;
			case 'cancelled':
				if (outcome.priorWorkerDerivationEpoch !== activeSubscription.workerDerivationEpoch) {
					throw new Error(
						'Bridge product cancelled reconciliation epoch does not match its request.',
					);
				}
				break;
			case 'reopenRequired':
				if (outcome.requiredWorkerDerivationEpoch !== activeSubscription.workerDerivationEpoch) {
					throw new Error('Bridge product reopen reconciliation epoch does not match its request.');
				}
				break;
		}
	}
}
export type BridgeProductMetadataStreamRequest = z.infer<
	typeof bridgeProductMetadataStreamRequestSchema
>;
export type BridgeProductMetadataFrame = z.infer<typeof bridgeProductMetadataFrameSchema>;
export type BridgeProductSessionBootstrap = z.infer<typeof bridgeProductSessionBootstrapSchema>;
export type BridgePaneCommWorkerInstall = z.infer<typeof bridgePaneCommWorkerInstallSchema>;

export type BridgePaneCommWorkerInstallTarget = {
	postMessage(message: BridgePaneCommWorkerInstall, transferList: readonly Transferable[]): void;
};

export function postBridgePaneCommWorkerInstall(
	target: BridgePaneCommWorkerInstallTarget,
	install: BridgePaneCommWorkerInstall,
): void {
	const validatedInstall = bridgePaneCommWorkerInstallSchema.parse(install);
	target.postMessage(validatedInstall, [
		validatedInstall.productPort,
		validatedInstall.productCapability,
	]);
	if (validatedInstall.productCapability.byteLength !== 0) {
		throw new Error('Bridge product capability did not detach after pane-worker install.');
	}
}

export function bridgeProductMetadataAcceptedStreamSequence(
	request: BridgeProductMetadataStreamRequest,
): number {
	const validatedRequest = bridgeProductMetadataStreamRequestSchema.parse(request);
	return validatedRequest.resumeFromStreamSequence === null
		? 0
		: validatedRequest.resumeFromStreamSequence + 1;
}

export function encodeBridgeProductCapabilityHeader(
	capability: ArrayBuffer | ArrayBufferView | readonly number[],
): string {
	const capabilityBytes =
		capability instanceof ArrayBuffer
			? new Uint8Array(capability)
			: ArrayBuffer.isView(capability)
				? new Uint8Array(capability.buffer, capability.byteOffset, capability.byteLength)
				: capability;
	const validatedBytes = bridgeProductCapabilityBytesSchema.parse([...capabilityBytes]);
	let binaryValue = '';
	for (const byte of validatedBytes) {
		binaryValue += String.fromCharCode(byte);
	}
	return globalThis.btoa(binaryValue).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
}
