import {
	parseDiffFromFile,
	type CodeViewDiffItem,
	type CodeViewOptions,
	type PostRenderPhase,
} from '@pierre/diffs';
import type { CodeView, CodeViewItem } from '@pierre/diffs';
import { act } from 'react';
import { expect } from 'vitest';

import type { BridgeMainRenderPublicationItem } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import { bridgeWorkerTestReviewPublicationIdentity } from '../../core/comm-worker/bridge-main-render-fulfillment-coordinator.test-support.js';
import {
	bridgeWorkerReviewPierreRenderJobEventSchema,
	type BridgeWorkerReviewPierreRenderJobEvent,
} from '../../core/comm-worker/bridge-worker-contracts.js';
import { buildBridgeWorkerPierreRenderJob } from '../../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../../core/comm-worker/bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from '../../core/comm-worker/bridge-worker-render-fulfillment.test-support.js';
import { BridgeProductTestFactRecorder } from '../../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import { bridgePierreOptionalHighlightLanguage } from '../workers/pierre/bridge-pierre-language-normalization.js';

export interface CurrentRenderedReviewRows {
	readonly baseLines: readonly HTMLElement[];
	readonly clearHeadText: () => void;
	readonly element: HTMLElement;
	readonly headLines: readonly HTMLElement[];
	readonly shadowRoot: ShadowRoot;
}

export interface ExactItemReceiptLog<TItem, TReceipt extends { readonly contextItem: TItem }> {
	readonly receipts: TReceipt[];
	readonly record: (receipt: TReceipt) => void;
	readonly waitForItem: (item: TItem) => Promise<void>;
	readonly close: (error: Error) => void;
}

export function createExactItemReceiptLog<
	TItem,
	TReceipt extends { readonly contextItem: TItem },
>(): ExactItemReceiptLog<TItem, TReceipt> {
	const receipts: TReceipt[] = [];
	const facts = new BridgeProductTestFactRecorder<TReceipt>();
	let isClosed = false;
	return {
		receipts,
		record: (receipt): void => {
			if (isClosed) return;
			receipts.push(receipt);
			facts.record(receipt);
		},
		waitForItem: async (item): Promise<void> => {
			await facts.waitFor((receipt): boolean => receipt.contextItem === item);
		},
		close: (error): void => {
			isClosed = true;
			facts.close(error);
		},
	};
}

export async function observeReviewHeaderMetadata(signal: AbortSignal): Promise<HTMLElement> {
	const facts = new BridgeProductTestFactRecorder<HTMLElement>();
	let isClosed = false;
	const inspectMetadata = (): void => {
		if (isClosed) return;
		const metadata = document.querySelector('[data-testid="bridge-code-view-header-metadata"]');
		if (metadata instanceof HTMLElement) facts.record(metadata);
	};
	const observer = new MutationObserver(inspectMetadata);
	const onAbort = (): void => {
		isClosed = true;
		facts.close(new Error('Review header metadata observation aborted.'));
	};
	observer.observe(document.body, { childList: true, subtree: true });
	signal.addEventListener('abort', onAbort, { once: true });
	try {
		if (signal.aborted) onAbort();
		else inspectMetadata();
		return await facts.waitFor();
	} finally {
		isClosed = true;
		observer.disconnect();
		signal.removeEventListener('abort', onAbort);
		facts.close(new Error('Review header metadata observation closed.'));
	}
}

export function paintedSourceCorrelations(element: Element): string | null {
	return element.getAttribute('data-bridge-painted-source-correlations');
}

export function assertBridgeCodeViewHeaderGeometry(props: {
	readonly metadata: HTMLElement;
	readonly pierreHeaderTitle: HTMLElement;
}): void {
	const pierreHeader = props.pierreHeaderTitle.closest('[data-diffs-header]');
	if (!(pierreHeader instanceof HTMLElement)) {
		throw new Error('Expected the surrounding Pierre file header.');
	}
	expect(Math.round(pierreHeader.getBoundingClientRect().height)).toBe(40);
	const openFileButton = props.metadata.querySelector(
		'[data-testid="bridge-code-view-open-file-button"]',
	);
	if (!(openFileButton instanceof HTMLElement)) {
		throw new Error('Expected the shadcn open-file button inside the Pierre file header.');
	}
	const openFileButtonBox = openFileButton.getBoundingClientRect();
	expect(Math.round(openFileButtonBox.width)).toBe(24);
	expect(Math.round(openFileButtonBox.height)).toBe(24);
	const pierreHeaderBox = pierreHeader.getBoundingClientRect();
	expect(
		Math.abs(
			openFileButtonBox.y +
				openFileButtonBox.height / 2 -
				(pierreHeaderBox.y + pierreHeaderBox.height / 2),
		),
	).toBeLessThanOrEqual(1);
}

export function requireCurrentRenderedReviewRows(
	codeView: CodeView,
	item: CodeViewItem,
): CurrentRenderedReviewRows {
	const renderedItem = codeView
		.getRenderedItems()
		.find(
			(candidate): boolean =>
				candidate.id === item.id && candidate.item === item && candidate.element.isConnected,
		);
	if (renderedItem === undefined) {
		throw new Error('Expected exact current connected Pierre Review item.');
	}
	const shadowRoot = renderedItem.element.shadowRoot;
	if (shadowRoot === null) throw new Error('Expected real Pierre shadow root.');
	return {
		baseLines: [
			...shadowRoot.querySelectorAll<HTMLElement>('[data-deletions] [data-line][data-line-index]'),
		],
		clearHeadText: (): void => {
			for (const headLine of shadowRoot.querySelectorAll<HTMLElement>(
				'[data-additions] [data-line]',
			))
				headLine.textContent = '';
		},
		element: renderedItem.element,
		headLines: [
			...shadowRoot.querySelectorAll<HTMLElement>('[data-additions] [data-line][data-line-index]'),
		],
		shadowRoot,
	};
}

export function requireMountedCodeView(codeView: CodeView | null): CodeView {
	if (codeView === null) {
		throw new Error('Expected production BridgeCodeViewPanel to mount a public Pierre CodeView.');
	}
	return codeView;
}

type ExactReviewPierreDiffItem = Extract<
	BridgeMainRenderPublicationItem,
	{ readonly type: 'diff' }
> &
	CodeViewDiffItem;

export interface CapturedBridgeCodeViewPostRender {
	readonly contextItem: CodeViewItem;
	readonly invoke: (props: {
		readonly contextItem?: CodeViewItem;
		readonly phase: PostRenderPhase;
	}) => void;
}

export function makeReviewPublication(props: {
	readonly contentRole?: 'base' | 'head';
	readonly contentsMarker: string;
	readonly publicationSequence: number;
	readonly version: number;
}): BridgeWorkerReviewPierreRenderJobEvent {
	const itemId = 'item-source';
	const baseCacheKey = `base-${props.contentsMarker}`;
	const headCacheKey = `head-${props.contentsMarker}`;
	const contentCacheKey = `${baseCacheKey}|${headCacheKey}`;
	const contentRoles =
		props.contentRole === undefined ? (['base', 'head'] as const) : [props.contentRole];
	const baseSource = `\tlet primaryValue = "base-${props.contentsMarker}"\n\tlet secondaryValue = "base-secondary-${props.contentsMarker}"\n`;
	const headSource = `\tlet primaryValue = "head-${props.contentsMarker}"\n\tlet secondaryValue = "head-secondary-${props.contentsMarker}"\n`;
	const baseContents = props.contentRole === 'head' ? '' : baseSource;
	const headContents = props.contentRole === 'base' ? '' : headSource;
	const lineCount = contentRoles.length * 2;
	const job = buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank: { lane: 'selected', priority: props.publicationSequence },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		contentCacheKey,
		contentHash: `sha256:${props.contentsMarker}`,
		itemId,
		language: 'swift',
		payload: {
			item: {
				bridgeMetadata: {
					cacheKey: contentCacheKey,
					contentRoles,
					contentState: 'hydrated',
					displayPath: 'Sources/App/View.swift',
					itemId,
					lineCount,
				},
				fileDiff: parseDiffFromFile(
					{
						cacheKey: baseCacheKey,
						contents: baseContents,
						name: 'Sources/App/View.swift',
					},
					{
						cacheKey: headCacheKey,
						contents: headContents,
						name: 'Sources/App/View.swift',
					},
				),
				id: itemId,
				type: 'diff',
				version: props.version,
			},
			kind: 'codeViewDiffItem',
		},
		renderKind: 'reviewDiff',
		sourceCorrelations: contentRoles.map((role) => ({
			descriptorId: `descriptor-${props.contentsMarker}-${role}`,
			itemId,
			observedSha256: (role === 'base' ? 'b' : 'c').repeat(64),
			position: 'whole',
			requestId: `request-${props.contentsMarker}-${role}`,
			role,
			sourceGeneration: props.publicationSequence,
			sourceIdentity: `source-${props.contentsMarker}-${role}`,
		})),
		window: { endLine: lineCount, startLine: 1, totalLineCount: lineCount },
	});
	return {
		direction: 'serverWorkerToMain',
		job,
		kind: 'reviewPierreRenderJob',
		reviewPublicationIdentity: bridgeWorkerTestReviewPublicationIdentity,
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId,
			publicationSequence: props.publicationSequence,
			surface: 'review',
			workerDerivationEpoch: 1,
		}),
		surface: 'review',
		transferDescriptors: [
			{
				byteLength: job.payloadByteLength,
				fieldPath: ['job', 'payload'],
				messageKind: 'reviewPierreRenderJob',
				mode: 'clone',
			},
		],
		wireVersion: 1,
		workerDerivationEpoch: 1,
	};
}

export function cloneReviewPublicationForRetry(
	publication: BridgeWorkerReviewPierreRenderJobEvent,
): BridgeWorkerReviewPierreRenderJobEvent {
	const publicationItem = requireExactReviewPierreDiffItem(publication.job.payload.item);
	const clonedPublicationItem = {
		...publicationItem,
		bridgeMetadata: {
			...publicationItem.bridgeMetadata,
			contentRoles: [...publicationItem.bridgeMetadata.contentRoles],
		},
		fileDiff: { ...publicationItem.fileDiff },
	};
	return bridgeWorkerReviewPierreRenderJobEventSchema.parse({
		...publication,
		job: {
			...publication.job,
			payload: {
				...publication.job.payload,
				item: clonedPublicationItem,
			},
		},
		renderReceiptIdentity: {
			...publication.renderReceiptIdentity,
			attemptId: 'attempt-review-equal-fingerprint-retry',
		},
	});
}

export function dispositionKinds(
	dispositions: readonly BridgeWorkerRenderDispositionReceipt[],
): readonly BridgeWorkerRenderDispositionReceipt['disposition'][] {
	return dispositions.map((receipt) => receipt.disposition);
}

export async function invokeCapturedPostRenderWithinAct(props: {
	readonly contextItem?: CodeViewItem;
	readonly invocation: CapturedBridgeCodeViewPostRender;
	readonly mutateRenderedContent?: () => void;
	readonly phase: PostRenderPhase;
}): Promise<void> {
	await act(async (): Promise<void> => {
		props.mutateRenderedContent?.();
		props.invocation.invoke({
			phase: props.phase,
			...(props.contextItem === undefined ? {} : { contextItem: props.contextItem }),
		});
		await Promise.resolve();
	});
}

export function requirePostRenderForItem(
	invocations: readonly CapturedBridgeCodeViewPostRender[],
	item: CodeViewItem,
): CapturedBridgeCodeViewPostRender {
	const invocation = invocations.findLast((candidate): boolean => candidate.contextItem === item);
	if (invocation === undefined) {
		throw new Error(`Expected Pierre onPostRender callback for exact item ${item.id}.`);
	}
	return invocation;
}

export function captureBridgeCodeViewPostRender(props: {
	readonly callback: NonNullable<CodeViewOptions<undefined>['onPostRender']>;
	readonly callbackArguments: readonly unknown[];
	readonly log: ExactItemReceiptLog<CodeViewItem, CapturedBridgeCodeViewPostRender>;
}): void {
	const callbackArguments = requireBridgeCodeViewPostRenderArguments(props.callbackArguments);
	const capturedContextItem = callbackArguments.context.item;
	const capturedContext = { ...callbackArguments.context, item: capturedContextItem };
	props.log.record({
		contextItem: capturedContextItem,
		invoke: (invokeProps): void => {
			Reflect.apply(props.callback, undefined, [
				callbackArguments.element,
				callbackArguments.instance,
				invokeProps.phase,
				{
					...capturedContext,
					item: invokeProps.contextItem ?? capturedContextItem,
				},
			]);
		},
	});
}

function requireBridgeCodeViewPostRenderArguments(callbackArguments: readonly unknown[]): {
	readonly context: Readonly<Record<string, unknown>> & { readonly item: CodeViewItem };
	readonly element: HTMLElement;
	readonly instance: unknown;
} {
	const [element, instance, phase, context] = callbackArguments;
	if (
		!(element instanceof HTMLElement) ||
		!isPostRenderPhase(phase) ||
		!isBridgeCodeViewPostRenderContext(context)
	) {
		throw new Error('Expected Pierre public onPostRender element, instance, phase, and context.');
	}
	return { context, element, instance };
}

function isBridgeCodeViewPostRenderContext(
	value: unknown,
): value is Readonly<Record<string, unknown>> & { readonly item: CodeViewItem } {
	return isUnknownRecord(value) && isCodeViewItem(value['item']);
}

function isCodeViewItem(value: unknown): value is CodeViewItem {
	return (
		isUnknownRecord(value) &&
		typeof value['id'] === 'string' &&
		(value['type'] === 'diff' || value['type'] === 'file')
	);
}

function isPostRenderPhase(value: unknown): value is PostRenderPhase {
	return value === 'mount' || value === 'unmount' || value === 'update';
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null;
}

export function requireExactReviewPierreDiffItem(
	item: BridgeMainRenderPublicationItem,
): ExactReviewPierreDiffItem {
	if (!isExactReviewPierreDiffItem(item)) {
		throw new Error('Expected exact Review worker publication to be a public Pierre diff item.');
	}
	return item;
}

export function requireCurrentReviewPierreDiffItem(
	codeView: CodeView,
	itemId: string,
): ExactReviewPierreDiffItem {
	const item = codeView.getItem(itemId);
	if (item === undefined || !isExactReviewPierreDiffItem(item)) {
		throw new Error(`Expected current Review item ${itemId} to carry Bridge publication metadata.`);
	}
	return item;
}

export function isExactReviewPierreDiffItem(
	item: BridgeMainRenderPublicationItem | CodeViewItem,
): item is ExactReviewPierreDiffItem {
	if (item.type !== 'diff' || !('bridgeMetadata' in item)) return false;
	const language = item.fileDiff.lang;
	return language === undefined
		? !Object.hasOwn(item.fileDiff, 'lang')
		: bridgePierreOptionalHighlightLanguage(language) === language;
}

export function assertReviewRenderedMembership(codeView: CodeView, item: CodeViewItem): void {
	expect(
		codeView
			.getRenderedItems()
			.some(
				(renderedItem): boolean =>
					renderedItem.id === item.id &&
					renderedItem.item === item &&
					renderedItem.element.isConnected,
			),
	).toBe(true);
}

export function waitForReviewAppliedReceipt(
	facts: BridgeProductTestFactRecorder<BridgeWorkerRenderDispositionReceipt>,
	publication: BridgeWorkerReviewPierreRenderJobEvent,
): Promise<BridgeWorkerRenderDispositionReceipt> {
	const identity = publication.renderReceiptIdentity;
	return facts.waitFor(
		(receipt): boolean =>
			receipt.disposition === 'applied' &&
			receipt.publicationId === identity.publicationId &&
			receipt.attemptId === identity.attemptId &&
			receipt.workerInstanceId === identity.workerInstanceId,
	);
}
