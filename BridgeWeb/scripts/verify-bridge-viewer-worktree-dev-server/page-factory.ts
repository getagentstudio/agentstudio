import type { Page } from 'playwright';

import type { ReviewMetadataBeforeContentProof } from '../verify-bridge-viewer-worktree-review-proof.ts';
import { observeVerifierStartupStep, requireVerifierBrowser } from './browser-session.ts';
import type {
	WorktreeBridgeTelemetrySampleProof,
	WorktreeVerifierBrowserHelpers,
} from './types.ts';

export async function makeVerificationPage(
	props: { readonly signal?: AbortSignal } = {},
): Promise<Page> {
	props.signal?.throwIfAborted();
	const pagePromise = observeVerifierStartupStep(
		'verifier page acquisition',
		requireVerifierBrowser().newPage({
			deviceScaleFactor: 1,
			viewport: {
				width: 1728,
				height: 980,
			},
		}),
	).value();
	const page =
		props.signal === undefined
			? await pagePromise
			: await raceVerifierPageAcquisition(pagePromise, props.signal);
	page.setDefaultTimeout(0);
	page.setDefaultNavigationTimeout(0);
	const observedTelemetryBatchKeys = new Set<string>();
	page.on('request', (request): void => {
		if (request.method() !== 'POST') {
			return;
		}
		const requestUrl = new URL(request.url());
		if (requestUrl.pathname !== '/__bridge-dev-telemetry/batch') {
			return;
		}
		const encodedBody = request.postData();
		if (encodedBody === null) {
			return;
		}
		let decodedBody: unknown;
		try {
			decodedBody = JSON.parse(encodedBody);
		} catch {
			return;
		}
		const observedBatch = decodeTelemetryWorkerPost(decodedBody);
		if (observedBatch === null) {
			return;
		}
		if (observedTelemetryBatchKeys.has(observedBatch.batchKey)) {
			return;
		}
		observedTelemetryBatchKeys.add(observedBatch.batchKey);
		void page
			.evaluate((observedSamples): void => {
				window.bridgeWorktreeVerifierTelemetrySamples?.push(...observedSamples);
			}, observedBatch.samples)
			.catch((): void => undefined);
	});
	await page.addInitScript((): void => {
		window.bridgeWorktreeVerifierTelemetrySamples = [];
		document.addEventListener('__bridge_ready_ack', (): void => {
			window.bridgeCompleteJourneyHandshakeReadyEpochMilliseconds ??= Date.now();
		});
		const verifierHelpers: WorktreeVerifierBrowserHelpers = {
			getBridgeFileViewerRenderedCodeLineCount(): number {
				const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
				if (!(canvas instanceof HTMLElement)) {
					return 0;
				}
				return Array.from(canvas.querySelectorAll('diffs-container')).reduce(
					(lineCount, container) =>
						lineCount +
						(container.shadowRoot?.querySelectorAll('[data-content] [data-line-index]').length ??
							0),
					0,
				);
			},
			getBridgeFileViewerRenderedCodeText(): string {
				const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
				if (!(canvas instanceof HTMLElement)) {
					return '';
				}
				const renderedContentBlocks = Array.from(
					canvas.querySelectorAll('diffs-container'),
				).flatMap((container) =>
					Array.from(container.shadowRoot?.querySelectorAll('[data-content]') ?? []),
				);
				const renderedText = renderedContentBlocks
					.map((contentBlock) => contentBlock.textContent ?? '')
					.join('\n');
				return renderedText.length > 0 ? renderedText : (canvas.textContent ?? '');
			},
			getBridgeFileViewerScrollableContent(): HTMLElement | null {
				const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
				if (!(canvas instanceof HTMLElement)) {
					return null;
				}
				const candidates = [
					canvas,
					...Array.from(canvas.querySelectorAll('*')).filter(
						(candidate): candidate is HTMLElement => candidate instanceof HTMLElement,
					),
				];
				return (
					candidates.find((candidate) => candidate.scrollHeight > candidate.clientHeight) ?? canvas
				);
			},
			getPierreFileTreeItem(path: string): HTMLElement | null {
				const escapedPath = CSS.escape(path);
				return (
					this.getPierreFileTreeItems().find(
						(candidate) => candidate.dataset['itemPath'] === path,
					) ??
					this.getPierreFileTreeScrollElement()?.querySelector(
						`[data-item-path="${escapedPath}"]`,
					) ??
					null
				);
			},
			getPierreFileTreeItems(): HTMLElement[] {
				const scrollElement = this.getPierreFileTreeScrollElement();
				if (!(scrollElement instanceof HTMLElement)) {
					return [];
				}
				return Array.from(scrollElement.querySelectorAll('[data-item-path]')).filter(
					(candidate): candidate is HTMLElement =>
						candidate instanceof HTMLElement &&
						candidate.dataset['fileTreeStickyRow'] !== 'true' &&
						candidate.dataset['itemParked'] !== 'true',
				);
			},
			getPierreFileTreeScrollElement(): HTMLElement | null {
				const treeHost = document.querySelector(
					'[data-testid="bridge-file-viewer-pierre-file-tree"] file-tree-container',
				);
				const scrollElement = treeHost?.shadowRoot?.querySelector(
					'[data-file-tree-virtualized-scroll="true"]',
				);
				return scrollElement instanceof HTMLElement ? scrollElement : null;
			},
		};
		Object.defineProperty(window, 'bridgeWorktreeVerifier', {
			configurable: true,
			value: verifierHelpers,
		});
		Object.defineProperty(window, 'bridgeWorktreeReviewMetadataBeforeContentProof', {
			configurable: true,
			value: (): ReviewMetadataBeforeContentProof => {
				const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
				const treeHost = document.querySelector(
					'[data-testid="bridge-review-trees-panel"] file-tree-container',
				);
				const scrollElement = treeHost?.shadowRoot?.querySelector(
					'[data-file-tree-virtualized-scroll="true"]',
				);
				const visibleRows = Array.from(
					scrollElement?.querySelectorAll<HTMLElement>(
						'button[data-item-path]:not([data-file-tree-sticky-row]):not([data-item-parked])',
					) ?? [],
				).filter((candidate): boolean => {
					if (!(candidate instanceof HTMLElement)) {
						return false;
					}
					const rect = candidate.getBoundingClientRect();
					return rect.width > 0 && rect.height > 0;
				});
				const scrollRect =
					scrollElement instanceof HTMLElement ? scrollElement.getBoundingClientRect() : null;
				return {
					blockedContentHitCount: 0,
					metadataHitCount: 0,
					selectedContentStateWhileBlocked:
						reviewShell instanceof HTMLElement
							? reviewShell.getAttribute('data-selected-content-state')
							: null,
					selectedDisplayPathWhileBlocked:
						reviewShell instanceof HTMLElement
							? reviewShell.getAttribute('data-selected-display-path')
							: null,
					treeVisibleRowCountWhileBlocked: visibleRows.length,
					treeVisibleWhileBlocked:
						scrollRect !== null &&
						scrollRect.width > 0 &&
						scrollRect.height > 0 &&
						visibleRows.length > 0,
				};
			},
		});
	});
	return page;
}

async function raceVerifierPageAcquisition(
	pagePromise: Promise<Page>,
	signal: AbortSignal,
): Promise<Page> {
	let rejectOnAbort: (() => void) | null = null;
	const abortPromise = new Promise<never>((_resolve, reject): void => {
		rejectOnAbort = (): void =>
			reject(signal.reason ?? new Error('Verifier page acquisition aborted.'));
		if (signal.aborted) {
			rejectOnAbort();
			return;
		}
		signal.addEventListener('abort', rejectOnAbort, { once: true });
	});
	try {
		return await Promise.race([pagePromise, abortPromise]);
	} catch (error: unknown) {
		void pagePromise.then(
			(page): Promise<void> => page.close().catch((): void => undefined),
			(): void => undefined,
		);
		throw error;
	} finally {
		if (rejectOnAbort !== null) signal.removeEventListener('abort', rejectOnAbort);
	}
}

function decodeTelemetryWorkerPost(value: unknown): {
	readonly batchKey: string;
	readonly samples: readonly WorktreeBridgeTelemetrySampleProof[];
} | null {
	if (
		!isUnknownRecord(value) ||
		value['type'] !== 'telemetry.batch' ||
		value['schemaVersion'] !== 2 ||
		typeof value['telemetrySessionId'] !== 'string' ||
		!Number.isInteger(value['batchSequence']) ||
		typeof value['batchSequence'] !== 'number' ||
		!Array.isArray(value['samples'])
	) {
		return null;
	}
	return {
		batchKey: `${value['telemetrySessionId']}:${value['batchSequence']}`,
		samples: value['samples'].flatMap((stampedSample) => {
			if (!isUnknownRecord(stampedSample) || !isUnknownRecord(stampedSample['sample'])) {
				return [];
			}
			const compactSample = stampedSample['sample'];
			if (
				(compactSample['type'] !== 'event.required' &&
					compactSample['type'] !== 'event.optional') ||
				!isUnknownRecord(compactSample['sample'])
			) {
				return [];
			}
			const proof = mapEventSampleToVerifierProof(compactSample['sample']);
			return proof === null ? [] : [proof];
		}),
	};
}

function mapEventSampleToVerifierProof(
	sample: Readonly<Record<string, unknown>>,
): WorktreeBridgeTelemetrySampleProof | null {
	if (
		typeof sample['name'] !== 'string' ||
		!isUnknownRecord(sample['stringAttributes']) ||
		!isUnknownRecord(sample['numericAttributes'])
	) {
		return null;
	}
	const durationMilliseconds = sample['durationMilliseconds'];
	if (durationMilliseconds !== null && typeof durationMilliseconds !== 'number') {
		return null;
	}
	const stringAttributes = sample['stringAttributes'];
	const numericAttributes = Object.fromEntries(
		Object.entries(sample['numericAttributes']).filter(
			(entry): entry is [string, number] => typeof entry[1] === 'number',
		),
	);
	return {
		durationMilliseconds,
		name: sample['name'],
		numericAttributes,
		phase: stringAttribute(stringAttributes, 'agentstudio.bridge.phase'),
		result: stringAttribute(stringAttributes, 'agentstudio.bridge.result'),
		slice: stringAttribute(stringAttributes, 'agentstudio.bridge.slice'),
		transport: stringAttribute(stringAttributes, 'agentstudio.bridge.transport'),
		viewer: stringAttribute(stringAttributes, 'agentstudio.bridge.viewer'),
		workerCommand: stringAttribute(stringAttributes, 'agentstudio.bridge.worker.command'),
		workerLane: stringAttribute(stringAttributes, 'agentstudio.bridge.worker.lane'),
		workerTaskKind: stringAttribute(stringAttributes, 'agentstudio.bridge.worker.task_kind'),
	};
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringAttribute(
	attributes: Readonly<Record<string, unknown>>,
	key: string,
): string | null {
	const value = attributes[key];
	return typeof value === 'string' ? value : null;
}
