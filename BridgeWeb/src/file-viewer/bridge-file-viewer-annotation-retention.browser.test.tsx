import { CodeView, type CodeViewOptions } from '@pierre/diffs';
import { act, type ReactElement } from 'react';
import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { userEvent } from 'vitest/browser';

import { BridgeTestFactRecorder } from '../../tests/test-support/bridge-test-fact-recorder.ts';
import { observeBridgeTransitionDOMFact } from '../../tests/test-support/bridge-transition-dom-fact.browser.test-support.ts';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	createBridgePaneRuntime,
	type BridgePaneSessionPort,
	type BridgePaneSurfaceClient,
} from '../core/comm-worker/bridge-pane-runtime.js';
import type {
	BridgeWorkerFileDisplayPatchEvent,
	BridgeWorkerFilePierreRenderJobEvent,
	BridgeWorkerFileRenderPatchEvent,
	BridgeWorkerMainToServerMessage,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	buildBridgeWorkerPierreRenderJob,
	type BridgeWorkerRenderSourceCorrelation,
} from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRenderDispositionReceipt } from '../core/comm-worker/bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from '../core/comm-worker/bridge-worker-render-fulfillment.test-support.js';
import {
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from '../worktree-annotations/worktree-annotation-browser-test-support.js';
import type { WorktreeAnnotationCommandOutcome } from '../worktree-annotations/worktree-annotation-surface-client.js';
import { WorktreeAnnotationSurfaceProvider } from '../worktree-annotations/worktree-annotation-surface-provider.js';
import { BridgeFileViewerCodePanel } from './bridge-file-viewer-code-panel.js';
import type { BridgeFileViewerSelection } from './bridge-file-viewer-display-model.js';
import {
	BridgeFileViewerSurfaceClientProvider,
	useBridgeFileViewerRenderSnapshotController,
} from './bridge-file-viewer-render-snapshot-controller.js';

const fileSelection = {
	fileId: 'file-1',
	path: 'Sources/App/View.swift',
} satisfies BridgeFileViewerSelection;

describe('Bridge File viewer annotation retention', () => {
	test.each([false, true])(
		'retains a committed preview before annotation convergence (source replacement: %s)',
		async (replacesSource) => {
			const successorEpoch = replacesSource ? 2 : 1;
			const scenario = await arrangePinnedFileAnnotationScenario({
				replacesSource,
				successorEpoch,
			});
			const {
				annotationSurface,
				committedPreview,
				renderReceipts,
				renderFacts,
				rendered,
				runtimeFileClient,
				savedReceipt,
			} = scenario;
			try {
				expect(runtimeFileClient.renderStore.getSnapshot().fileDisplayFreshness).toMatchObject({
					epoch: successorEpoch,
					projectionRevision: 2,
				});
				expect(committedPreview.isConnected).toBe(true);
				expect(getComputedStyle(committedPreview).visibility).toBe('visible');
				expect(committedPreview.getBoundingClientRect().height).toBeGreaterThan(0);
				expect(
					rendered
						.getByTestId('bridge-file-viewer-code-canvas')
						.element()
						.getAttribute('data-worktree-open-file-body-preview'),
				).toContain('let line4 = 4');
				expect(
					renderReceipts.some(
						(receipt) => receipt.publicationSequence === 2 && receipt.disposition === 'queued',
					),
				).toBe(true);
				expect(
					renderReceipts.some(
						(receipt) =>
							receipt.publicationSequence === 2 &&
							(receipt.disposition === 'applied' || receipt.disposition === 'painted'),
					),
				).toBe(false);
				expect(committedPreview.textContent).toContain('Saved before the File refresh settles.');
				expect(
					annotationSurface.sentOperations.filter(
						(operation) => operation.kind === 'draft.edit.release',
					),
				).toHaveLength(0);

				await act(async (): Promise<void> => {
					annotationSurface.publishProjectionState({
						expectedThreadCount: 1,
						revision: savedReceipt.message.sessionRevision + 1,
						sessions: [
							annotationSessionSummary({
								revision: savedReceipt.message.sessionRevision,
								sessionId: annotationSessionId,
							}),
						],
					});
					annotationSurface.publishThread({
						context: {
							...savedReceipt.context,
							placement: 'exact',
							sourceIdentity: 'descriptor-file-2',
						},
						message: savedReceipt.message,
					});
					await Promise.resolve();
				});
				await settleBrowserCondition(
					(): boolean =>
						document.querySelectorAll('[data-testid="worktree-annotation-thread"]').length === 1 &&
						document.querySelector(
							'[data-testid="worktree-annotation-committed-pending-projection"]',
						) === null,
					'Expected the successor projection to reconcile the committed preview exactly once.',
				);
				expect(
					rendered
						.getByTestId('bridge-file-viewer-code-canvas')
						.element()
						.getAttribute('data-worktree-open-file-body-preview'),
				).toContain('let line4 = 5');
				await renderFacts.waitFor(
					(receipt): boolean =>
						receipt.publicationSequence === 2 && receipt.disposition === 'painted',
					'File successor publication 2 painted acknowledgement',
				);
				expect(
					renderReceipts.some(
						(receipt): boolean =>
							receipt.publicationSequence === 2 && receipt.disposition === 'painted',
					),
				).toBe(true);
			} finally {
				scenario.dispose();
			}
		},
	);

	test('Update releases a pinned File source whose annotation receipt never reconciles', async () => {
		// Arrange
		const scenario = await arrangePinnedFileAnnotationScenario({
			replacesSource: true,
			successorEpoch: 2,
		});
		try {
			const canvas = scenario.rendered.getByTestId('bridge-file-viewer-code-canvas').element();
			expect(canvas.getAttribute('data-worktree-open-file-body-preview')).toContain(
				'let line4 = 4',
			);
			const updateButton = scenario.rendered.getByRole('button', { name: 'Update file' });
			await expect.element(updateButton).toBeVisible();

			// Act
			await act(async (): Promise<void> => {
				await updateButton.click();
				await settleBrowserCondition(
					(): boolean =>
						canvas
							.getAttribute('data-worktree-open-file-body-preview')
							?.includes('let line4 = 5') === true,
					'Expected Update to install the latest File source.',
				);
			});

			// Assert: the latest File source is displayed with no annotation reconciliation.
			expect(
				document.querySelector('[aria-label="Update file"]'),
				'Expected the File changed control to leave once the latest source is shown.',
			).toBeNull();
		} finally {
			scenario.dispose();
		}
	});
});

interface PinnedFileAnnotationScenario {
	readonly annotationSurface: RecordingAnnotationBrowserSurface;
	readonly committedPreview: HTMLElement;
	readonly dispose: () => void;
	readonly renderReceipts: readonly BridgeWorkerRenderDispositionReceipt[];
	readonly renderFacts: BridgeTestFactRecorder<BridgeWorkerRenderDispositionReceipt>;
	readonly rendered: Awaited<ReturnType<typeof render>>;
	readonly runtimeFileClient: BridgePaneSurfaceClient;
	readonly savedReceipt: Extract<
		NonNullable<WorktreeAnnotationCommandOutcome['receipt']>,
		{ readonly kind: 'message' }
	>;
}

// Saves a File annotation, then publishes a successor source while annotations are
// unavailable, so the code view pins the committed source behind the saved comment.
async function arrangePinnedFileAnnotationScenario(scenarioOptions: {
	readonly replacesSource: boolean;
	readonly successorEpoch: number;
}): Promise<PinnedFileAnnotationScenario> {
	const { replacesSource, successorEpoch } = scenarioOptions;
	const annotationSurface = new RecordingAnnotationBrowserSurface('fileView');
	const commandOutcomes: WorktreeAnnotationCommandOutcome[] = [];
	const unsubscribeCommandOutcomes = annotationSurface.client.subscribeMessages((message): void => {
		if (message.kind === 'annotationCommandAccepted' && message.outcome !== undefined) {
			commandOutcomes.push(message.outcome);
		}
	});
	const renderReceipts: BridgeWorkerRenderDispositionReceipt[] = [];
	const renderFacts = new BridgeTestFactRecorder<BridgeWorkerRenderDispositionReceipt>();
	const operationFacts = new BridgeTestFactRecorder<
		RecordingAnnotationBrowserSurface['sentOperations'][number]
	>();
	let publishRuntimeMessages: (
		messages: readonly BridgeWorkerServerToMainMessage[],
	) => void = (): void => {};
	const paneRuntime = createBridgePaneRuntime({
		sessionFactory: (): BridgePaneSessionPort => ({
			createDispatcher: (props) => {
				publishRuntimeMessages = props.publishWorkerMessages;
				return {
					dispatch: (message: BridgeWorkerMainToServerMessage): void => {
						if (message.command !== 'renderDisposition') return;
						const dispositions = message.receipts.filter(
							(receipt) => receipt.kind === 'render.disposition',
						);
						renderReceipts.push(...dispositions);
						for (const receipt of dispositions) renderFacts.record(receipt);
						queueMicrotask((): void => {
							publishRuntimeMessages([
								{
									direction: 'serverWorkerToMain',
									kind: 'health',
									requestId: message.requestId,
									status: 'ready',
									transferDescriptors: [],
									wireVersion: 1,
								},
							]);
						});
					},
					dispose: (): void => {},
				};
			},
			dispose: (): void => {},
			installNativeBootstrap: (): void => {},
		}),
	});
	const runtimeFileClient = paneRuntime.surfaceClient('fileView');
	const surfaceClient = combineFileRuntimeWithAnnotationFixture({
		annotationClient: annotationSurface.client,
		fileClient: runtimeFileClient,
		onAnnotationOperation: (operation): void => operationFacts.record(operation),
	});
	runtimeFileClient.renderStore.setLocalSelection({
		selectedItemId: fileSelection.fileId,
		source: 'user',
	});
	const appliedOptions: CodeViewOptions<undefined>[] = [];
	const optionsFacts = new BridgeTestFactRecorder<CodeViewOptions<undefined>>();
	// oxlint-disable-next-line unbound-method -- Browser witness restores the exact prototype method.
	const originalSetOptions = CodeView.prototype.setOptions;
	CodeView.prototype.setOptions = function captureOptions(
		options: CodeViewOptions<undefined> | undefined,
	): void {
		if (options !== undefined) appliedOptions.push(options);
		originalSetOptions.call(this, options);
		if (options !== undefined) optionsFacts.record(options);
	};

	const dispose = (): void => {
		renderFacts.close(new Error('File retention scenario disposed'));
		operationFacts.close(new Error('File retention scenario disposed'));
		optionsFacts.close(new Error('File retention scenario disposed'));
		unsubscribeCommandOutcomes();
		CodeView.prototype.setOptions = originalSetOptions;
		paneRuntime.dispose();
	};
	try {
		const rendered = await render(
			<div style={{ height: 480, width: 800 }}>
				<BridgeFileViewerSurfaceClientProvider surfaceClient={surfaceClient}>
					<WorktreeAnnotationSurfaceProvider surfaceClient={surfaceClient}>
						<FileAnnotationRetentionProbe />
					</WorktreeAnnotationSurfaceProvider>
				</BridgeFileViewerSurfaceClientProvider>
			</div>,
		);
		await act(async (): Promise<void> => {
			publishRuntimeMessages([
				makeFileDisplayEvent({ epoch: 1, sequence: 1, replacesSource: true }),
				await makeFilePublication({
					epoch: 1,
					publicationSequence: 1,
					sourceDescriptorId: 'descriptor-file-1',
					version: 1,
				}),
				makeFileReadyEvent({ epoch: 1, publicationSequence: 1 }),
			]);
			await Promise.resolve();
		});
		await optionsFacts.waitFor(
			(options): boolean => options.onLineSelectionEnd !== undefined,
			'File predecessor publication Pierre options applied',
		);
		expect(appliedOptions.at(-1)?.onLineSelectionEnd !== undefined).toBe(true);

		await act(async (): Promise<void> => {
			invokeGutterAdmission(requireCodeViewOptions(appliedOptions.at(-1)));
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			await rendered
				.getByRole('textbox', { name: 'Write an annotation in Markdown' })
				.fill('Saved before the File refresh settles.');
			await userEvent.keyboard('{Meta>}{Enter}{/Meta}');
		});
		await operationFacts.waitFor(
			(operation): boolean => operation.kind === 'root.create',
			'File Save durable root.create dispatch',
		);
		expect(
			annotationSurface.sentOperations.some(
				(operation): boolean => operation.kind === 'root.create',
			),
		).toBe(true);
		await act(async (): Promise<void> => {
			annotationSurface.settleMostRecentCommittedWithoutProjection(
				annotationSessionId,
				'root.create',
			);
			await operationFacts.waitFor(
				(operation): boolean => operation.kind === 'draft.save',
				'File root receipt continued to draft.save dispatch',
			);
			expect(
				annotationSurface.sentOperations.some(
					(operation): boolean => operation.kind === 'draft.save',
				),
			).toBe(true);
		});
		await act(async (): Promise<void> => {
			annotationSurface.settleMostRecentCommittedWithoutProjection(
				annotationSessionId,
				'draft.save',
			);
			await Promise.resolve();
		});
		await settleBrowserCondition(
			(): boolean => document.querySelector('[data-testid="worktree-annotation-thread"]') !== null,
			'Expected the exact Save receipt to present the committed File preview.',
		);
		const committedPreview = document.querySelector<HTMLElement>(
			'[data-testid="worktree-annotation-thread"]',
		);
		if (committedPreview === null) throw new Error('Expected committed File preview.');
		const savedReceipt = commandOutcomes.at(-1)?.receipt;
		if (savedReceipt?.kind !== 'message' || savedReceipt.message.savedRevision === null) {
			throw new Error('Expected the canonical Save receipt before source replacement.');
		}

		await act(async (): Promise<void> => {
			publishRuntimeMessages([
				makeFileDisplayEvent({ epoch: successorEpoch, sequence: 2, replacesSource }),
				await makeFilePublication({
					epoch: successorEpoch,
					publicationSequence: 2,
					sourceDescriptorId: 'descriptor-file-2',
					version: 2,
				}),
				makeFileReadyEvent({ epoch: successorEpoch, publicationSequence: 2 }),
			]);
			annotationSurface.publishUnavailable();
			await Promise.resolve();
			await Promise.resolve();
		});
		return {
			annotationSurface,
			committedPreview,
			dispose,
			renderReceipts,
			renderFacts,
			rendered,
			runtimeFileClient,
			savedReceipt,
		};
	} catch (error: unknown) {
		dispose();
		throw error;
	}
}

function FileAnnotationRetentionProbe(): ReactElement {
	const controller = useBridgeFileViewerRenderSnapshotController({ selection: fileSelection });
	return (
		<BridgeFileViewerCodePanel
			codeViewWorkerPoolEnabled={false}
			openFileState={{
				displayItem: null,
				fileId: fileSelection.fileId,
				path: fileSelection.path,
				status: controller.selectedCodeViewItem === null ? 'loading' : 'ready',
			}}
			renderFulfillmentCoordinator={controller.renderFulfillmentCoordinator}
			selectedCodeViewItem={controller.selectedCodeViewItem}
			totalHeightPixels={null}
		/>
	);
}

function combineFileRuntimeWithAnnotationFixture(props: {
	readonly annotationClient: BridgePaneSurfaceClient;
	readonly fileClient: BridgePaneSurfaceClient;
	readonly onAnnotationOperation: (
		operation: RecordingAnnotationBrowserSurface['sentOperations'][number],
	) => void;
}): BridgePaneSurfaceClient {
	return {
		...props.fileClient,
		send: (command): string => {
			const requestId =
				command.command === 'annotationCommand' || command.command === 'annotationOutputInspect'
					? props.annotationClient.send(command)
					: props.fileClient.send(command);
			if (command.command === 'annotationCommand') props.onAnnotationOperation(command.operation);
			return requestId;
		},
		subscribeMessages: (listener): (() => void) => {
			const unsubscribeAnnotation = props.annotationClient.subscribeMessages(listener);
			const unsubscribeFile = props.fileClient.subscribeMessages(listener);
			return (): void => {
				unsubscribeAnnotation();
				unsubscribeFile();
			};
		},
	};
}

function makeFileDisplayEvent(props: {
	readonly epoch: number;
	readonly sequence: number;
	readonly replacesSource: boolean;
}): BridgeWorkerFileDisplayPatchEvent {
	const event: BridgeWorkerFileDisplayPatchEvent = {
		direction: 'serverWorkerToMain',
		epoch: props.epoch,
		kind: 'fileDisplayPatch',
		patches: [
			{
				operation: 'reset',
				payload: { sourceGeneration: props.epoch, sourceId: `source-${props.epoch}` },
				slice: 'fileTree',
			},
			{ operation: 'reset', slice: 'fileItem' },
			{
				itemId: fileSelection.fileId,
				operation: 'upsert',
				payload: {
					availability: { kind: 'available' },
					displayPath: fileSelection.path,
					endsMidLine: false,
					endsWithNewline: true,
					extent: { kind: 'exactLineCount', lineCount: 8 },
					fileExtension: 'swift',
					language: 'swift',
					payloadByteCount: 128,
					payloadLineCount: 8,
					rowId: 'row-file-1',
					sizeBytes: 128,
					totalLineCount: 8,
					truncationKind: 'none',
				},
				slice: 'fileItem',
			},
			{
				operation: 'replacementCommit',
				payload: { sourceGeneration: props.epoch, sourceId: `source-${props.epoch}` },
				slice: 'fileTree',
			},
		],
		projectionRevision: props.sequence,
		sequence: props.sequence,
		surface: 'fileView',
		transferDescriptors: [],
		wireVersion: 1,
	};
	return props.replacesSource
		? event
		: {
				...event,
				patches: event.patches.filter(
					(patch) => patch.slice === 'fileItem' && patch.operation === 'upsert',
				),
			};
}

async function makeFilePublication(props: {
	readonly epoch: number;
	readonly publicationSequence: number;
	readonly sourceDescriptorId: string;
	readonly version: number;
}): Promise<BridgeWorkerFilePierreRenderJobEvent> {
	const cacheKey = `file-cache-${props.sourceDescriptorId}`;
	const contents = Array.from(
		{ length: 8 },
		(_, index): string => `let line${index + 1} = ${index + props.version}`,
	).join('\n');
	const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(contents));
	const observedSha256 = Array.from(new Uint8Array(digest), (byte): string =>
		byte.toString(16).padStart(2, '0'),
	).join('');
	const sourceCorrelation = {
		descriptorId: props.sourceDescriptorId,
		itemId: fileSelection.fileId,
		observedSha256,
		position: 'whole',
		requestId: `request-${props.publicationSequence}`,
		role: 'file',
		sourceGeneration: props.epoch,
		sourceIdentity: `source-${props.epoch}`,
	} satisfies BridgeWorkerRenderSourceCorrelation;
	const job = buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank: { lane: 'selected', priority: props.publicationSequence },
		budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
		contentCacheKey: cacheKey,
		contentHash: `sha256:${observedSha256}`,
		itemId: fileSelection.fileId,
		language: 'swift',
		payload: {
			item: {
				bridgeMetadata: {
					cacheKey,
					contentRoles: ['file'],
					contentState: 'hydrated',
					displayPath: fileSelection.path,
					itemId: fileSelection.fileId,
					lineCount: 8,
					sourceDescriptorId: props.sourceDescriptorId,
					sourceDescriptorIdsByRole: {
						base: null,
						diff: null,
						file: props.sourceDescriptorId,
						head: null,
					},
				},
				file: {
					cacheKey,
					contents,
					lang: 'swift',
					name: fileSelection.path,
				},
				id: `file:${fileSelection.fileId}`,
				type: 'file',
				version: props.version,
			},
			kind: 'codeViewFileItem',
		},
		renderKind: 'fileText',
		sourceCorrelations: [sourceCorrelation],
		window: { endLine: 8, startLine: 1, totalLineCount: 8 },
	});
	return {
		direction: 'serverWorkerToMain',
		job,
		kind: 'filePierreRenderJob',
		publicationSequence: props.publicationSequence,
		renderReceiptIdentity: makeBridgeWorkerRenderReceiptIdentity({
			itemId: fileSelection.fileId,
			publicationSequence: props.publicationSequence,
			surface: 'file',
			workerDerivationEpoch: props.epoch,
		}),
		surface: 'file',
		transferDescriptors: [
			{
				byteLength: job.payloadByteLength,
				fieldPath: ['job', 'payload'],
				messageKind: 'filePierreRenderJob',
				mode: 'clone',
			},
		],
		wireVersion: 1,
		workerDerivationEpoch: props.epoch,
	};
}

function makeFileReadyEvent(props: {
	readonly epoch: number;
	readonly publicationSequence: number;
}): BridgeWorkerFileRenderPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		kind: 'fileRenderPatch',
		patches: [
			{
				itemId: fileSelection.fileId,
				operation: 'upsert',
				payload: { state: 'ready' },
				slice: 'contentAvailability',
			},
		],
		publicationSequence: props.publicationSequence,
		surface: 'file',
		transferDescriptors: [],
		wireVersion: 1,
		workerDerivationEpoch: props.epoch,
	};
}

function invokeGutterAdmission(options: CodeViewOptions<undefined>): void {
	if (options.onGutterUtilityClick === undefined || options.onLineSelectionEnd === undefined) {
		throw new Error('Expected Pierre gutter and line-selection callbacks.');
	}
	const range = { end: 4, start: 4 };
	const item = { id: `file:${fileSelection.fileId}` };
	Reflect.apply(options.onGutterUtilityClick, undefined, [range, { item }]);
	Reflect.apply(options.onLineSelectionEnd, undefined, [range, { item }]);
}

function requireCodeViewOptions(
	value: CodeViewOptions<undefined> | undefined,
): CodeViewOptions<undefined> {
	if (value === undefined) throw new Error('Expected current Pierre options.');
	return value;
}

async function settleBrowserCondition(
	predicate: () => boolean,
	failureMessage: string,
): Promise<void> {
	const observation = observeFileRetentionDOMCondition(predicate, failureMessage);
	try {
		await observation.promise;
		expect(predicate(), failureMessage).toBe(true);
	} finally {
		observation.close();
	}
}

function observeFileRetentionDOMCondition(
	predicate: () => boolean,
	label: string,
): ReturnType<typeof observeBridgeTransitionDOMFact> {
	return observeBridgeTransitionDOMFact({ isCommitted: predicate, label });
}

test('names a withheld File retention DOM fact at explicit owner retirement', async () => {
	const observation = observeFileRetentionDOMCondition(
		(): boolean => false,
		'withheld File retention projection',
	);
	void observation.promise.catch((): void => {});
	observation.close();
	await expect(
		Promise.race([
			observation.promise,
			Promise.reject(new Error('Owner close did not settle File retention observation')),
		]),
	).rejects.toThrow('Test owner retired while awaiting withheld File retention projection');
});
