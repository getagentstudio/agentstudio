import {
	bridgeProductSurfaceForCallKind,
	type BridgeProductCallKind,
	type BridgeProductCallRegistry,
} from './bridge-product-call-contracts.js';
import {
	bridgeProductSurfaceForContentKind,
	type BridgeProductContentKind,
	type BridgeProductContentRegistry,
} from './bridge-product-content-contracts.js';
import type {
	BridgeProductRegistryValue,
	BridgeProductSurface,
} from './bridge-product-contract-primitives.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import type {
	BridgeProductRequestExecutor,
	BridgeProductRequestRoute,
} from './bridge-product-request-executor.js';
import type { BridgeProductMetadataFrame } from './bridge-product-session-contracts.js';
import type { BridgeProductSubscriptionKind } from './bridge-product-subscription-contracts.js';
import type {
	BridgeProductCallResult,
	BridgeProductContentStream,
	BridgeProductMetadataApplicationSubscription,
	BridgeProductTransport,
} from './bridge-product-transport-contract.js';

declare const productTransport: BridgeProductTransport;
declare const productRequestExecutor: BridgeProductRequestExecutor;
declare const abortSignal: AbortSignal;
declare function acceptMetadataFrame(frame: BridgeProductMetadataFrame): void;
const requestRoute: BridgeProductRequestRoute = 'command';
void productRequestExecutor(requestRoute, { method: 'POST' });

type SyntheticCorrelationRegistry = {
	readonly first: {
		readonly descriptor: { readonly descriptorCase: 'first' };
		readonly identity: { readonly identityCase: 'first' };
		readonly request: { readonly requestCase: 'first' };
		readonly result: { readonly resultCase: 'first' };
		readonly terminal: { readonly terminalCase: 'first' };
	};
	readonly second: {
		readonly descriptor: { readonly descriptorCase: 'second' };
		readonly identity: { readonly identityCase: 'second' };
		readonly request: { readonly requestCase: 'second' };
		readonly result: { readonly resultCase: 'second' };
		readonly terminal: { readonly terminalCase: 'second' };
	};
};

type SyntheticCallCorrelation<TCase extends keyof SyntheticCorrelationRegistry> = readonly [
	request: BridgeProductRegistryValue<SyntheticCorrelationRegistry, TCase, 'request'>,
	result: BridgeProductRegistryValue<SyntheticCorrelationRegistry, TCase, 'result'>,
];

type SyntheticContentCorrelation<TCase extends keyof SyntheticCorrelationRegistry> = readonly [
	descriptor: BridgeProductRegistryValue<SyntheticCorrelationRegistry, TCase, 'descriptor'>,
	identity: BridgeProductRegistryValue<SyntheticCorrelationRegistry, TCase, 'identity'>,
	terminal: BridgeProductRegistryValue<SyntheticCorrelationRegistry, TCase, 'terminal'>,
];

const syntheticFirstCall: SyntheticCallCorrelation<'first'> = [
	{ requestCase: 'first' },
	{ resultCase: 'first' },
];
const syntheticFirstContent: SyntheticContentCorrelation<'first'> = [
	{ descriptorCase: 'first' },
	{ identityCase: 'first' },
	{ terminalCase: 'first' },
];
const syntheticSecondCall: SyntheticCallCorrelation<'second'> = [
	{ requestCase: 'second' },
	{ resultCase: 'second' },
];
const syntheticSecondContent: SyntheticContentCorrelation<'second'> = [
	{ descriptorCase: 'second' },
	{ identityCase: 'second' },
	{ terminalCase: 'second' },
];
void syntheticFirstCall;
void syntheticFirstContent;
void syntheticSecondCall;
void syntheticSecondContent;

const syntheticCrossWiredRequest: SyntheticCallCorrelation<'first'> = [
	{
		// @ts-expect-error A registry case cannot borrow another case's request.
		requestCase: 'second',
	},
	{ resultCase: 'first' },
];
const syntheticCrossWiredResult: SyntheticCallCorrelation<'first'> = [
	{ requestCase: 'first' },
	{
		// @ts-expect-error A registry case cannot borrow another case's result.
		resultCase: 'second',
	},
];
const syntheticCrossWiredDescriptor: SyntheticContentCorrelation<'first'> = [
	{
		// @ts-expect-error A registry case cannot borrow another case's descriptor.
		descriptorCase: 'second',
	},
	{ identityCase: 'first' },
	{ terminalCase: 'first' },
];
const syntheticCrossWiredIdentity: SyntheticContentCorrelation<'first'> = [
	{ descriptorCase: 'first' },
	{
		// @ts-expect-error A registry case cannot borrow another case's identity.
		identityCase: 'second',
	},
	{ terminalCase: 'first' },
];
const syntheticCrossWiredTerminal: SyntheticContentCorrelation<'first'> = [
	{ descriptorCase: 'first' },
	{ identityCase: 'first' },
	{
		// @ts-expect-error A registry case cannot borrow another case's terminal.
		terminalCase: 'second',
	},
];
void syntheticCrossWiredRequest;
void syntheticCrossWiredResult;
void syntheticCrossWiredDescriptor;
void syntheticCrossWiredIdentity;
void syntheticCrossWiredTerminal;

const surfaceByCallKind = {
	'file.annotations.command': 'file',
	'file.annotations.output.inspect': 'file',
	'file.annotations.projection.query': 'file',
	'file.activeViewerMode.update': 'file',
	'file.source.current': 'file',
	'file.refresh.retry': 'file',
	'review.activeViewerMode.update': 'review',
	'review.comparison.update': 'review',
	'review.comparisonTargets.query': 'review',
	'review.intake.ready': 'review',
	'review.markFileViewed': 'review',
	'review.publication.applied': 'review',
	'review.publication.install.admit': 'review',
	'review.annotations.command': 'review',
	'review.annotations.output.inspect': 'review',
	'review.annotations.projection.query': 'review',
} as const satisfies {
	readonly [TCallKind in BridgeProductCallKind]: BridgeProductCallRegistry[TCallKind]['surface'];
};
const surfaceBySubscriptionKind = {
	'file.annotations': 'file',
	'file.metadata': 'file',
	'review.annotations': 'review',
	'review.metadata': 'review',
} as const satisfies {
	readonly [TSubscriptionKind in BridgeProductSubscriptionKind]: BridgeProductSurface;
};
const surfaceByContentKind = {
	'annotation.output': 'file',
	'annotation.projection': 'review',
	'file.content': 'file',
	'review.content': 'review',
	'review.comparisonTargets': 'review',
} as const satisfies {
	readonly [TContentKind in BridgeProductContentKind]: BridgeProductContentRegistry[TContentKind]['surface'];
};

const reviewAnnotationProjectionDescriptor = {
	contentKind: 'annotation.projection',
	descriptorId: 'annotation-projection-descriptor-1',
	maximumBytes: 128 * 1024,
	page: {
		aggregateSha256: 'a'.repeat(64),
		expectedMessageCount: 2,
		expectedPageCount: 1,
		expectedSessionCount: 1,
		expectedThreadCount: 1,
		isLastPage: true,
		nextCursor: null,
		operationCorrelationId: 'a'.repeat(64),
		pageOrdinal: 0,
		projectionRevision: 11,
		snapshotId: '00000000-0000-7000-8000-000000000018',
		sourceGeneration: 7,
	},
	surface: 'review',
} as const satisfies BridgeProductContentRegistry['annotation.projection']['descriptor'];

const reviewCallSurface: 'review' = bridgeProductSurfaceForCallKind('review.markFileViewed');
const reviewIntakeReadyCallSurface: 'review' =
	bridgeProductSurfaceForCallKind('review.intake.ready');
const reviewComparisonUpdateCallSurface: 'review' = bridgeProductSurfaceForCallKind(
	'review.comparison.update',
);
const reviewComparisonTargetsQueryCallSurface: 'review' = bridgeProductSurfaceForCallKind(
	'review.comparisonTargets.query',
);
const reviewPublicationAppliedCallSurface: 'review' = bridgeProductSurfaceForCallKind(
	'review.publication.applied',
);
const reviewPublicationInstallAdmissionCallSurface: 'review' = bridgeProductSurfaceForCallKind(
	'review.publication.install.admit',
);
const reviewActiveModeCallSurface: 'review' = bridgeProductSurfaceForCallKind(
	'review.activeViewerMode.update',
);
const fileActiveModeCallSurface: 'file' = bridgeProductSurfaceForCallKind(
	'file.activeViewerMode.update',
);
const fileSourceCurrentCallSurface: 'file' = bridgeProductSurfaceForCallKind('file.source.current');
const reviewSubscriptionSurface: 'review' = bridgeProductReviewMetadataApplicationProtocol.surface;
const fileSubscriptionSurface: 'file' = bridgeProductFileMetadataApplicationProtocol.surface;
const fileContentSurface: 'file' = bridgeProductSurfaceForContentKind('file.content');
const reviewContentSurface: 'review' = bridgeProductSurfaceForContentKind('review.content');
const reviewComparisonTargetsContentSurface: 'review' = bridgeProductSurfaceForContentKind(
	'review.comparisonTargets',
);
const reviewAnnotationProjectionContentSurface: 'file' | 'review' =
	bridgeProductSurfaceForContentKind('annotation.projection', reviewAnnotationProjectionDescriptor);
const allMappedSurfaces: readonly BridgeProductSurface[] = [
	...Object.values(surfaceByCallKind),
	...Object.values(surfaceBySubscriptionKind),
	...Object.values(surfaceByContentKind),
];
void reviewCallSurface;
void reviewIntakeReadyCallSurface;
void reviewComparisonUpdateCallSurface;
void reviewComparisonTargetsQueryCallSurface;
void reviewPublicationAppliedCallSurface;
void reviewPublicationInstallAdmissionCallSurface;
void reviewActiveModeCallSurface;
void fileActiveModeCallSurface;
void fileSourceCurrentCallSurface;
void reviewSubscriptionSurface;
void fileSubscriptionSurface;
void fileContentSurface;
void reviewContentSurface;
void reviewComparisonTargetsContentSurface;
void reviewAnnotationProjectionContentSurface;
void allMappedSurfaces;

// @ts-expect-error A closed call mapper cannot infer a surface from a string prefix.
void bridgeProductSurfaceForCallKind('file.arbitrary');
// @ts-expect-error A closed content mapper cannot infer a surface from a string prefix.
void bridgeProductSurfaceForContentKind('file.arbitrary');

// @ts-expect-error The executor accepts only the closed product-route identity.
void productRequestExecutor('arbitrary', { method: 'POST' });

const markViewedResult: Promise<null> = productTransport.call('review.markFileViewed', {
	itemId: 'review-item-1',
});
void markViewedResult;

const emptyMarkViewedResult: BridgeProductCallResult<'review.markFileViewed'> = null;
void emptyMarkViewedResult;
const intakeReadyResult: Promise<null> = productTransport.call('review.intake.ready', {
	reason: null,
	streamId: 'review-stream-1',
});
void intakeReadyResult;
const reviewComparisonUpdateResult: Promise<null> = productTransport.call(
	'review.comparison.update',
	{ target: { basis: 'commonCommit', kind: 'branch', name: 'feature/review' } },
);
void reviewComparisonUpdateResult;
const reviewPublicationAppliedResult: Promise<null> = productTransport.call(
	'review.publication.applied',
	{ publicationId: '00000000-0000-7000-8000-000000000017' },
);
void reviewPublicationAppliedResult;
const reviewPublicationInstallAdmissionResult: Promise<{ status: 'admitted' | 'rejected' }> =
	productTransport.call('review.publication.install.admit', {
		candidatePublicationId: '00000000-0000-7000-8000-000000000018',
		expectedDisplayedPublicationId: '00000000-0000-7000-8000-000000000017',
	});
void reviewPublicationInstallAdmissionResult;
const reviewAnnotationProjectionQueryResult: Promise<
	BridgeProductCallResult<'review.annotations.projection.query'>
> = productTransport.call('review.annotations.projection.query', {
	cursor: null,
	operationCorrelationId: 'a'.repeat(64),
	sessionIds: ['00000000-0000-7000-8000-000000000019'],
	sourceGeneration: 7,
	surface: 'review',
});
void reviewAnnotationProjectionQueryResult;

const currentFileSourceResult = productTransport.call('file.source.current', {});
const availableCurrentFileSourceResult: BridgeProductCallResult<'file.source.current'> = {
	source: {
		cwdScope: null,
		freshness: 'live',
		includeStatuses: true,
		repoId: '00000000-0000-4000-8000-000000000001',
		rootPathToken: 'root-token-1',
		worktreeId: '00000000-0000-4000-8000-000000000002',
	},
	status: 'available',
};
const unavailableCurrentFileSourceResult: BridgeProductCallResult<'file.source.current'> = {
	reason: 'no-file-source-authority',
	status: 'unavailable',
};
void currentFileSourceResult;
void availableCurrentFileSourceResult;
void unavailableCurrentFileSourceResult;

const reviewSubscription: BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductReviewMetadataApplicationProtocol
> = productTransport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
const reviewLifecycleEvents: AsyncIterable<never> = reviewSubscription.events;
void reviewLifecycleEvents;

// @ts-expect-error Subscription data updates are removed from the transport API.
void reviewSubscription.update({});

const fileSubscription: BridgeProductMetadataApplicationSubscription<
	typeof bridgeProductFileMetadataApplicationProtocol
> = productTransport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
	source: {
		cwdScope: null,
		freshness: 'live',
		includeStatuses: true,
		repoId: '00000000-0000-4000-8000-000000000001',
		rootPathToken: 'root-token-1',
		worktreeId: '00000000-0000-4000-8000-000000000002',
	},
});
void fileSubscription;

// @ts-expect-error Metadata subscriptions reject the retired interest options.
void productTransport.subscribe(bridgeProductReviewMetadataApplicationProtocol, { interests: [] });

// @ts-expect-error Subscription strings are retired; callers retain the registered protocol.
void productTransport.subscribe('review.metadata', {});

const fileContent: BridgeProductContentStream<'file.content'> = productTransport.openContent(
	{
		contentKind: 'file.content',
		declaredByteLength: 12,
		descriptorId: 'file-descriptor-1',
		encoding: 'utf-8',
		expectedSha256: 'a'.repeat(64),
		fileId: 'file-1',
		maximumBytes: 2 * 1024 * 1024,
		source: {
			repoId: '00000000-0000-4000-8000-000000000001',
			rootRevisionToken: null,
			sourceCursor: 'source-cursor-1',
			sourceId: 'source-1',
			subscriptionGeneration: 11,
			worktreeId: '00000000-0000-4000-8000-000000000002',
		},
		window: {
			kind: 'prefix',
			maximumBytes: 2 * 1024 * 1024,
			maximumLines: 10_000,
			startByte: 0,
		},
	},
	abortSignal,
);
void fileContent;

const reviewContent: BridgeProductContentStream<'review.content'> = productTransport.openContent(
	{
		contentDigest: {
			algorithm: 'git-oid',
			authority: 'provisional',
			value: '0123456789abcdef0123456789abcdef01234567',
		},
		contentKind: 'review.content',
		declaredByteLength: null,
		descriptorId: 'review-descriptor-1',
		encoding: 'utf-8',
		endpointId: 'review-endpoint-1',
		expectedSha256: null,
		handleId: 'review-handle-1',
		isBinary: false,
		itemId: 'review-item-1',
		language: 'typescript',
		maximumBytes: 512 * 1024,
		mimeType: 'text/plain',
		packageId: 'review-package-1',
		reviewGeneration: 7,
		role: 'head',
		sourceIdentity: 'review-query-1',
		wholeByteLength: 2_400_000,
		window: {
			kind: 'byteRange',
			maximumBytes: 512 * 1024,
			startByte: 0,
		},
	},
	abortSignal,
);
void reviewContent;
const reviewAnnotationProjectionContent: BridgeProductContentStream<'annotation.projection'> =
	productTransport.openContent(reviewAnnotationProjectionDescriptor, abortSignal);
void reviewAnnotationProjectionContent;
// @ts-expect-error Review content streams cannot cross-wire into File content results.
const invalidFileContent: BridgeProductContentStream<'file.content'> = reviewContent;
void invalidFileContent;

// @ts-expect-error Unknown calls cannot enter the closed registry.
void productTransport.call('review.arbitrary', null);

// @ts-expect-error The mark-viewed call requires its exact request.
void productTransport.call('review.markFileViewed', null);

// @ts-expect-error File source discovery accepts only its strict empty request.
void productTransport.call('file.source.current', { retry: true });

// @ts-expect-error Empty results use null, never an empty object.
const invalidMarkViewedResult: BridgeProductCallResult<'review.markFileViewed'> = {};
void invalidMarkViewedResult;

// @ts-expect-error Review subscriptions accept no retired interest options.
void productTransport.subscribe(bridgeProductReviewMetadataApplicationProtocol, { interests: [] });

// @ts-expect-error Review content opens require the complete strict source and range descriptor.
void productTransport.openContent({ contentKind: 'review.content' }, abortSignal);

// @ts-expect-error Content opens always require a caller-owned AbortSignal.
void productTransport.openContent({
	contentKind: 'file.content',
	declaredByteLength: 12,
	descriptorId: 'file-descriptor-1',
	encoding: 'utf-8',
	expectedSha256: 'a'.repeat(64),
	fileId: 'file-1',
	maximumBytes: 2 * 1024 * 1024,
	source: {
		repoId: '00000000-0000-4000-8000-000000000001',
		rootRevisionToken: null,
		sourceCursor: 'source-cursor-1',
		sourceId: 'source-1',
		subscriptionGeneration: 11,
		worktreeId: '00000000-0000-4000-8000-000000000002',
	},
	window: {
		kind: 'prefix',
		maximumBytes: 2 * 1024 * 1024,
		maximumLines: 10_000,
		startByte: 0,
	},
});

// Lifecycle frames are the only subscription frames in the metadata transport.
acceptMetadataFrame({
	kind: 'subscription.accepted',
	metadataStreamId: 'metadata-stream-1',
	paneSessionId: 'pane-session-1',
	streamSequence: 1,
	subscriptionId: 'review-subscription-1',
	subscriptionKind: 'review.metadata',
	subscriptionSequence: 0,
	wireVersion: 2,
	workerDerivationEpoch: 3,
	workerInstanceId: 'worker-instance-1',
});
