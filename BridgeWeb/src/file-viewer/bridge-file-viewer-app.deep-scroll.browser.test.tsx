import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import { installBridgeReadyHandshake } from '../app/bridge-app-browser-test-actions.js';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import {
	installBridgeAppDevProductSessionHost,
	type BridgeAppDevProductSessionHost,
} from '../app/bridge-app-dev-product-session-host.js';
import { BridgeAppProtocolRouter } from '../app/bridge-app-protocol-router.js';
import {
	createBridgePaneRuntime,
	type BridgePaneRuntime,
} from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductFileContentDescriptor } from '../core/comm-worker/bridge-product-content-contracts.js';
import type { BridgeWorkerMainToServerMessage } from '../core/comm-worker/bridge-worker-contracts.js';
import { ensureBridgeCodeViewThemeResolved } from '../review-viewer/code-view/bridge-code-view-theme.js';
import {
	bridgeViewerCodeGeometry,
	bridgeViewerVisibleCodeTextContent,
	bridgeViewerVisibleTreeItemPaths,
	findBridgeViewerTreeScrollOwner,
	waitForBridgeViewerVisibleTreeItemPath,
} from '../review-viewer/test-support/bridge-viewer-browser-dom.js';
import { createBridgePierrePortableBlobWorkerFactory } from '../review-viewer/workers/pierre/bridge-pierre-dev-worker-factory.js';
import {
	terminateBridgePierreWorkerPoolSingletonForTest,
	waitForBridgePierreWorkerPoolActiveTaskPublicationForTest,
} from '../review-viewer/workers/pierre/bridge-pierre-worker-pool.js';
import { createBridgeCommWorkerModuleWorker } from '../review-viewer/workers/shared-rpc/bridge-comm-worker-dev-factory.js';
import pageConfigurationFixture from '../test-fixtures/bridge-contract-fixtures/valid/bridge-page-configuration.json' with { type: 'json' };
import {
	BridgeFileViewerBrowserHarnessApp,
	type BridgeFileViewerBrowserTestProductSession,
} from './bridge-file-viewer-browser-test-app.js';
import {
	fileContentSha256Hex,
	logicalFileContentLineCount,
	makeFileContent,
} from './bridge-file-viewer-browser-test-fixtures.js';
import {
	actFrame,
	actClick,
	actUpdate,
	createBridgeFileViewerBrowserTestPaneSessionFactory,
	makeDeferredContent,
	openFilePath,
	openFileState,
	renderedFilePath,
	selectedDisplayPath,
	settleBridgeFileViewerBrowserUpdates,
	waitForFileCodeViewScrollable,
	waitForFileCodeViewScrollOwner,
	waitForMetadataTreeRowCount,
	waitForOpenedContentCount,
	waitForOpenFileState,
	waitForTreeScrollHeightAtLeast,
	waitForVisibleCodeText,
} from './bridge-file-viewer-browser-test-harness.js';
import {
	assertCompleteFileDeepScrollSourceOracle,
	assertCompleteFilePositionSurvivesModeSwitch,
	completeFileDeepScrollFixture,
	completeFileDeepScrollTreeRowCount,
	makeCompleteFileDeepScrollBatch,
	makeCompleteFileDeepScrollDescriptor,
	makeCorruptedCompleteFileDeepScrollContent,
	settleCompleteFilePierreWorkerPoolInitialization,
	type DeepScrollSurfacePaintSnapshot,
	waitForCompleteFileInitialPaintReady,
	waitForCompleteFileDeepScrollTerminalState,
	waitForDeepScrollRouteElement,
} from './bridge-file-viewer-deep-scroll-test-support.js';

const deepScrollSelectedPath = 'File-000.swift';
const deepScrollFinalTreePath = 'File-3419.swift';
const deepScrollFractions = [
	0.08, 0.16, 0.24, 0.32, 0.4, 0.48, 0.56, 0.64, 0.72, 0.8, 0.88, 0.96, 1,
] as const;

interface DeepScrollOwners {
	readonly codeScrollOwner: HTMLElement;
	readonly expectedSelectedPath: string;
	readonly routeOwners?: DeepScrollRouteOwners;
	readonly treeScrollOwner: HTMLElement;
}

interface DeepScrollRouteOwners {
	readonly appRoot: HTMLElement;
	readonly fileModeHost: HTMLElement;
}

interface DeepScrollSurfaceSnapshot {
	readonly code: DeepScrollSurfacePaintSnapshot;
	readonly codeContainerCount: number;
	readonly codeLineCount: number;
	readonly codeScrollTop: number;
	readonly codeVisibleCharacterCount: number;
	readonly renderedPath: string | null;
	readonly selectedPath: string | null;
	readonly tree: DeepScrollSurfacePaintSnapshot;
	readonly treeScrollTop: number;
	readonly treeVisiblePathCount: number;
}

let disposeRouteHandshake: (() => void) | null = null;
let routePierreWorkerFactory: ReturnType<
	typeof createBridgePierrePortableBlobWorkerFactory
> | null = null;
let routePaneRuntime: BridgePaneRuntime | null = null;
let routeProductSessionHost: BridgeAppDevProductSessionHost | null = null;

// oxlint-disable-next-line no-underscore-dangle -- Vite injects this test-only compile flag.
declare const __BRIDGE_REAL_VITE_PRODUCT_TEST__: boolean | undefined;

const realViteProductTestEnabled =
	typeof __BRIDGE_REAL_VITE_PRODUCT_TEST__ !== 'undefined' && __BRIDGE_REAL_VITE_PRODUCT_TEST__;
const realViteProductTest = realViteProductTestEnabled ? test : test.skip;

describe('BridgeFileViewerApp sustained deep scrolling', () => {
	afterEach(async () => {
		await actUpdate(async (): Promise<void> => {
			await cleanup();
		});
		await settleBridgeFileViewerBrowserUpdates();
		await actFrame();
		disposeRouteHandshake?.();
		disposeRouteHandshake = null;
		routeProductSessionHost?.dispose();
		routeProductSessionHost = null;
		routePaneRuntime?.dispose();
		routePaneRuntime = null;
		document.body.replaceChildren();
		terminateBridgePierreWorkerPoolSingletonForTest();
		routePierreWorkerFactory?.revoke();
		routePierreWorkerFactory = null;
	});

	test(
		'keeps the production FileTree and CodeView painted through sustained deep scrolling',
		{ tags: ['stress'] },
		async () => {
			await ensureBridgeCodeViewThemeResolved();
			routePierreWorkerFactory = createBridgePierrePortableBlobWorkerFactory();
			await assertCompleteFileDeepScrollSourceOracle();
			const selectedDescriptor = makeCompleteFileDeepScrollDescriptor({
				contentHandle: 'deep-scroll-selected-content',
				fileId: 'file-000',
				path: deepScrollSelectedPath,
			});
			const deferredContent = makeDeferredContent();
			const openedDescriptors: BridgeProductFileContentDescriptor[] = [];
			const openedDescriptorIds: string[] = [];
			const workerCommands: BridgeWorkerMainToServerMessage[] = [];

			await render(
				<div style={{ height: '720px', overflow: 'hidden', width: '1280px' }}>
					<BridgeFileViewerBrowserHarnessApp
						autoOpenInitialFile
						codeViewWorkerFactory={routePierreWorkerFactory.workerFactory}
						codeViewWorkerPoolEnabled
						initialFileBatch={makeCompleteFileDeepScrollBatch(selectedDescriptor)}
						fileProductSession={{
							onWorkerCommand: (message): void => {
								workerCommands.push(message);
							},
							readContent: ({ descriptor }) => {
								openedDescriptors.push(descriptor);
								openedDescriptorIds.push(descriptor.descriptorId);
								return deferredContent.promise;
							},
						}}
					/>
				</div>,
			);
			await settleCompleteFilePierreWorkerPoolInitialization(
				routePierreWorkerFactory.workerFactory,
			);

			await waitForMetadataTreeRowCount(completeFileDeepScrollTreeRowCount);
			await waitForTreeScrollHeightAtLeast(completeFileDeepScrollTreeRowCount * 24);
			await waitForOpenFileState('loading');
			await waitForOpenedContentCount({ expectedCount: 1, openedDescriptorIds });
			await assertDeepScrollLoadingState({
				openedDescriptor: openedDescriptors[0],
				selectedDescriptor,
				workerCommands,
			});
			const activeTaskPublication = waitForBridgePierreWorkerPoolActiveTaskPublicationForTest(
				routePierreWorkerFactory.workerFactory,
			);
			await actUpdate((): void => {
				deferredContent.resolve(makeFileContent(completeFileDeepScrollFixture.text));
			});
			await actUpdate(async (): Promise<void> => {
				await activeTaskPublication;
			});
			await waitForOpenFileState('ready');
			await waitForVisibleCodeText(completeFileDeepScrollFixture.firstSourceText);
			assertDeepScrollReadyCorrelation({
				openedDescriptor: openedDescriptors[0],
				selectedDescriptor,
				workerCommands,
			});
			const owners = await requireDeepScrollOwners();
			await waitForFileCodeViewScrollable(owners.codeScrollOwner);
			await waitForCompleteFileInitialPaintReady();
			assertDeepScrollSurfaceInvariant({ owners, step: 'initial' });

			await runDeepScrollSequence({
				fractionIndex: 0,
				owners,
				previousCodeScrollTop: 0,
				previousTreeScrollTop: 0,
			});
			await waitForBridgeViewerVisibleTreeItemPath(owners.treeScrollOwner, deepScrollFinalTreePath);
			await waitForDeepScrollFinalSource({ attempt: 0, owners });
			const finalSnapshot = assertDeepScrollSurfaceInvariant({ owners, step: 'final' });

			expect(finalSnapshot.treeScrollTop).toBeGreaterThan(70_000);
			expect(finalSnapshot.codeScrollTop).toBeGreaterThan(100_000);
			expect(bridgeViewerVisibleTreeItemPaths(owners.treeScrollOwner)).toContain(
				deepScrollFinalTreePath,
			);
			expect(bridgeViewerVisibleCodeTextContent(owners.codeScrollOwner)).toContain(
				completeFileDeepScrollFixture.finalSourceText,
			);
			expect(owners.codeScrollOwner.scrollTop).toBeGreaterThanOrEqual(
				owners.codeScrollOwner.scrollHeight - owners.codeScrollOwner.clientHeight - 1,
			);
		},
	);

	test(
		'keeps the full production File route painted through sustained deep scrolling',
		{ tags: ['stress'] },
		async () => {
			await assertCompleteFileDeepScrollSourceOracle();
			const selectedDescriptor = makeCompleteFileDeepScrollDescriptor({
				contentHandle: 'deep-scroll-route-selected-content',
				fileId: 'file-000',
				path: deepScrollSelectedPath,
			});
			const openedDescriptors: BridgeProductFileContentDescriptor[] = [];
			const workerCommands: BridgeWorkerMainToServerMessage[] = [];
			const productSession: BridgeFileViewerBrowserTestProductSession = {
				initialFileBatch: makeCompleteFileDeepScrollBatch(selectedDescriptor),
				onWorkerCommand: (message): void => {
					workerCommands.push(message);
				},
				readContent: async ({ descriptor }) => {
					openedDescriptors.push(descriptor);
					return makeFileContent(completeFileDeepScrollFixture.text);
				},
			};
			const paneSessionFactory = createBridgeFileViewerBrowserTestPaneSessionFactory({
				productSessionRef: { current: productSession },
			});
			disposeRouteHandshake = installBridgeReadyHandshake().dispose;
			routePierreWorkerFactory = createBridgePierrePortableBlobWorkerFactory();

			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerFactory={routePierreWorkerFactory.workerFactory}
					codeViewWorkerPoolEnabled
					fileViewerProps={{ autoOpenInitialFile: true }}
					paneRuntimeFactory={() => createBridgePaneRuntime({ sessionFactory: paneSessionFactory })}
					protocol="worktree-file"
				/>,
			);

			await waitForPierreWorkerRouteReady({ attempt: 0 });
			await waitForMetadataTreeRowCount(completeFileDeepScrollTreeRowCount);
			await waitForTreeScrollHeightAtLeast(completeFileDeepScrollTreeRowCount * 24);
			await waitForOpenFileState('ready');
			await waitForVisibleCodeText(completeFileDeepScrollFixture.firstSourceText);
			assertDeepScrollReadyCorrelation({
				openedDescriptor: openedDescriptors[0],
				selectedDescriptor,
				workerCommands,
			});
			const owners = await requireDeepScrollOwners({
				routeOwners: {
					appRoot: await waitForDeepScrollRouteElement({
						attempt: 0,
						selector: '[data-testid="bridge-app-root"]',
					}),
					fileModeHost: await waitForDeepScrollRouteElement({
						attempt: 0,
						selector: '[data-testid="bridge-viewer-mode-host-file"]',
					}),
				},
			});
			await waitForFileCodeViewScrollable(owners.codeScrollOwner);
			await waitForCompleteFileInitialPaintReady();
			assertDeepScrollSurfaceInvariant({ owners, step: 'route-initial' });

			await runDeepScrollSequence({
				fractionIndex: 0,
				owners,
				previousCodeScrollTop: 0,
				previousTreeScrollTop: 0,
			});
			await waitForBridgeViewerVisibleTreeItemPath(owners.treeScrollOwner, deepScrollFinalTreePath);
			await waitForDeepScrollFinalSource({ attempt: 0, owners });
			const finalSnapshot = assertDeepScrollSurfaceInvariant({ owners, step: 'route-final' });

			expect(finalSnapshot.treeScrollTop).toBeGreaterThan(70_000);
			expect(finalSnapshot.codeScrollTop).toBeGreaterThan(100_000);
			expect(bridgeViewerVisibleTreeItemPaths(owners.treeScrollOwner)).toContain(
				deepScrollFinalTreePath,
			);
			expect(bridgeViewerVisibleCodeTextContent(owners.codeScrollOwner)).toContain(
				completeFileDeepScrollFixture.finalSourceText,
			);
			expect(owners.codeScrollOwner.scrollTop).toBeGreaterThanOrEqual(
				owners.codeScrollOwner.scrollHeight - owners.codeScrollOwner.clientHeight - 1,
			);
			await assertCompleteFilePositionSurvivesModeSwitch({
				codeScrollOwner: owners.codeScrollOwner,
				expectedSelectedPath: deepScrollSelectedPath,
				treeScrollOwner: owners.treeScrollOwner,
			});
		},
	);

	test('rejects same-size middle-byte corruption before publishing a ready Pierre item', async () => {
		routePierreWorkerFactory = createBridgePierrePortableBlobWorkerFactory();
		const selectedDescriptor = makeCompleteFileDeepScrollDescriptor({
			contentHandle: 'deep-scroll-corrupted-content',
			fileId: 'file-000',
			path: deepScrollSelectedPath,
		});
		const corruptedContent = makeCorruptedCompleteFileDeepScrollContent();
		const corruptedBytes = corruptedContent.bytes;
		const deferredContent = makeDeferredContent();
		expect(corruptedBytes.byteLength).toBe(completeFileDeepScrollFixture.byteCount);
		expect(logicalFileContentLineCount(corruptedBytes)).toBe(
			completeFileDeepScrollFixture.lineCount,
		);
		expect(await fileContentSha256Hex(corruptedBytes)).not.toBe(
			completeFileDeepScrollFixture.sha256,
		);

		await render(
			<BridgeFileViewerBrowserHarnessApp
				autoOpenInitialFile
				codeViewWorkerFactory={routePierreWorkerFactory.workerFactory}
				codeViewWorkerPoolEnabled
				initialFileBatch={makeCompleteFileDeepScrollBatch(selectedDescriptor)}
				fileProductSession={{
					readContent: () => deferredContent.promise,
				}}
			/>,
		);
		await waitForOpenFileState('loading');
		await actUpdate((): void => {
			deferredContent.resolve(makeFileContent(corruptedContent.text));
		});

		expect(await waitForCompleteFileDeepScrollTerminalState()).toBe('unavailable');
		expect(document.querySelectorAll('diffs-container')).toHaveLength(0);
		expect(document.body.textContent ?? '').not.toContain(
			completeFileDeepScrollFixture.finalSourceText,
		);
	});

	realViteProductTest(
		'keeps the real Vite module-worker File route painted through sustained deep scrolling',
		async () => {
			disposeRouteHandshake = installBridgeReadyHandshake().dispose;
			routeProductSessionHost = installBridgeAppDevProductSessionHost({
				navigationIntent: {
					commandId: 'dev:test:file',
					commandKind: 'activateContext',
					surface: 'file',
				},
			});
			routePierreWorkerFactory = createBridgePierrePortableBlobWorkerFactory();

			await render(
				<BridgeAppProtocolRouter
					codeViewWorkerFactory={routePierreWorkerFactory.workerFactory}
					codeViewWorkerPoolEnabled
					fileViewerProps={{ autoOpenInitialFile: false }}
					paneRuntimeFactory={() => {
						routePaneRuntime ??= createBridgePaneRuntime({
							sessionProps: {
								bootstrapTimeoutMilliseconds:
									pageConfigurationFixture.workerBootstrapDeadlineMilliseconds,
								workerFactory: createBridgeCommWorkerModuleWorker,
							},
						});
						return routePaneRuntime;
					}}
					protocol="worktree-file"
				/>,
			);

			await waitForPierreWorkerRouteReady({ attempt: 0 });
			const metadataState = await waitForRealViteFileMetadataStable({
				attempt: 0,
				previousIdentity: null,
				stableFrameCount: 0,
			});
			const fileButton = await waitForFirstVisibleRealViteFileButton({ attempt: 0 });
			const selectedPath = fileButton.dataset['itemPath'];
			if (selectedPath === undefined || selectedPath.length === 0) {
				throw new Error('FILE_DEEP_SCROLL_REAL_VITE_FILE_PATH_MISSING');
			}
			await fetch('/__g0-product-trace?reset=1', { method: 'POST' });
			await actClick(fileButton);
			await waitForRealViteSelectedFileReady({
				attempt: 0,
				selectedPath,
				treeRowCount: metadataState.treeRowCount,
			});
			const owners = await requireDeepScrollOwners({
				expectedSelectedPath: selectedPath,
				routeOwners: {
					appRoot: await waitForDeepScrollRouteElement({
						attempt: 0,
						selector: '[data-testid="bridge-app-root"]',
					}),
					fileModeHost: await waitForDeepScrollRouteElement({
						attempt: 0,
						selector: '[data-testid="bridge-viewer-mode-host-file"]',
					}),
				},
			});
			await waitForTreeScrollHeightAtLeast(metadataState.treeRowCount * 20);
			await waitForCompleteFileInitialPaintReady();
			assertDeepScrollSurfaceInvariant({ owners, step: 'real-vite-initial' });

			await runDeepScrollSequence({
				fractionIndex: 0,
				owners,
				previousCodeScrollTop: 0,
				previousTreeScrollTop: 0,
			});
			const finalSnapshot = assertDeepScrollSurfaceInvariant({
				owners,
				step: 'real-vite-final',
			});

			expect(finalSnapshot.treeScrollTop).toBeGreaterThan(20_000);
			expect(finalSnapshot.treeVisiblePathCount).toBeGreaterThan(0);
			expect(finalSnapshot.codeVisibleCharacterCount).toBeGreaterThan(0);
		},
	);
});

async function assertDeepScrollLoadingState(props: {
	readonly openedDescriptor: BridgeProductFileContentDescriptor | undefined;
	readonly selectedDescriptor: ReturnType<typeof makeCompleteFileDeepScrollDescriptor>;
	readonly workerCommands: readonly BridgeWorkerMainToServerMessage[];
}): Promise<void> {
	const openedDescriptor = requireDeepScrollOpenedDescriptor(props.openedDescriptor);
	const expectedDescriptor = requireDeepScrollContentDescriptor(props.selectedDescriptor);
	expect(openedDescriptor).toEqual(expectedDescriptor);
	expect(openFileState()).toBe('loading');
	expect(openFilePath()).toBe(deepScrollSelectedPath);
	expect(selectedDisplayPath()).toBe(deepScrollSelectedPath);
	expect(props.workerCommands.find((message) => message.command === 'select')).toMatchObject({
		command: 'select',
		selectedItemId: expectedDescriptor.fileId,
		selectedSource: 'programmatic',
		surface: 'fileView',
	});
	const scrollOwner = await waitForFileCodeViewScrollOwner();
	await actFrame();
	expect(document.querySelectorAll('diffs-container')).toHaveLength(0);
	expect(document.querySelectorAll('[data-line-index], [data-content]')).toHaveLength(0);
	expect(scrollOwner.scrollHeight).toBeLessThanOrEqual(scrollOwner.clientHeight + 32);
	expect(
		document
			.querySelector('[data-bridge-region="file-content"]')
			?.getAttribute('data-presentation-state'),
	).toBe('loading');
	expect(
		document.querySelector('[data-bridge-region="file-content"] [data-slot="skeleton"]'),
	).not.toBeNull();
}

function assertDeepScrollReadyCorrelation(props: {
	readonly openedDescriptor: BridgeProductFileContentDescriptor | undefined;
	readonly selectedDescriptor: ReturnType<typeof makeCompleteFileDeepScrollDescriptor>;
	readonly workerCommands: readonly BridgeWorkerMainToServerMessage[];
}): void {
	const openedDescriptor = requireDeepScrollOpenedDescriptor(props.openedDescriptor);
	const expectedDescriptor = requireDeepScrollContentDescriptor(props.selectedDescriptor);
	const selectRequest = props.workerCommands.find((message) => message.command === 'select');
	if (selectRequest?.command !== 'select') {
		throw new Error('Deep-scroll File selection emitted no worker request.');
	}
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
	if (!(shell instanceof HTMLElement) || !(canvas instanceof HTMLElement)) {
		throw new Error('Deep-scroll File correlation requires the mounted shell and CodeView canvas.');
	}
	expect(openedDescriptor).toEqual(expectedDescriptor);
	expect(openedDescriptor).toMatchObject({
		declaredByteLength: completeFileDeepScrollFixture.byteCount,
		descriptorId: expectedDescriptor.descriptorId,
		expectedSha256: completeFileDeepScrollFixture.sha256,
		fileId: 'file-000',
		maximumBytes: completeFileDeepScrollFixture.byteCount,
		source: props.selectedDescriptor.source,
		window: {
			maximumBytes: completeFileDeepScrollFixture.byteCount,
			maximumLines: completeFileDeepScrollFixture.lineCount,
			startByte: 0,
		},
	});
	expect(selectRequest.requestId).not.toHaveLength(0);
	expect(selectRequest.selectedItemId).toBe(openedDescriptor.fileId);
	expect(shell.getAttribute('data-selected-display-path')).toBe(deepScrollSelectedPath);
	expect(shell.getAttribute('data-file-display-source-id')).toBe(
		props.selectedDescriptor.source.sourceId,
	);
	expect(shell.getAttribute('data-file-display-generation')).toBe(
		String(props.selectedDescriptor.source.subscriptionGeneration),
	);
	expect(shell.getAttribute('data-file-display-payload-byte-count')).toBe(
		String(completeFileDeepScrollFixture.byteCount),
	);
	expect(shell.getAttribute('data-file-display-payload-line-count')).toBe(
		String(completeFileDeepScrollFixture.lineCount),
	);
	expect(canvas.getAttribute('data-worktree-rendered-file-path')).toBe(deepScrollSelectedPath);
	expect(canvas.getAttribute('data-worktree-rendered-item-id')).toBe(openedDescriptor.fileId);
	expect(canvas.getAttribute('data-worktree-rendered-content-roles')).toBe('file');
	expect(canvas.getAttribute('data-worktree-rendered-content-state')).toBe('hydrated');
	expect(canvas.getAttribute('data-worktree-rendered-line-count')).toBe(
		String(completeFileDeepScrollFixture.lineCount),
	);
}

function requireDeepScrollContentDescriptor(
	descriptor: ReturnType<typeof makeCompleteFileDeepScrollDescriptor>,
): BridgeProductFileContentDescriptor {
	if (descriptor.availability.availabilityKind !== 'available') {
		throw new Error('Deep-scroll File descriptor is not available.');
	}
	return descriptor.availability.contentDescriptor;
}

function requireDeepScrollOpenedDescriptor(
	descriptor: BridgeProductFileContentDescriptor | undefined,
): BridgeProductFileContentDescriptor {
	if (descriptor === undefined) {
		throw new Error('Deep-scroll File content request did not expose its descriptor.');
	}
	return descriptor;
}

async function requireDeepScrollOwners(
	props: {
		readonly expectedSelectedPath?: string;
		readonly routeOwners?: DeepScrollRouteOwners;
	} = {},
): Promise<DeepScrollOwners> {
	const treeScrollOwner = findBridgeViewerTreeScrollOwner();
	if (treeScrollOwner === null) {
		throw new Error('FILE_DEEP_SCROLL_HARNESS_INVALID: expected the Pierre FileTree scroll owner.');
	}
	return {
		codeScrollOwner: await waitForFileCodeViewScrollOwner(),
		expectedSelectedPath: props.expectedSelectedPath ?? deepScrollSelectedPath,
		...(props.routeOwners === undefined ? {} : { routeOwners: props.routeOwners }),
		treeScrollOwner,
	};
}

async function runDeepScrollSequence(props: {
	readonly fractionIndex: number;
	readonly owners: DeepScrollOwners;
	readonly previousCodeScrollTop: number;
	readonly previousTreeScrollTop: number;
}): Promise<void> {
	const fraction = deepScrollFractions[props.fractionIndex];
	if (fraction === undefined) {
		return;
	}
	const codeScrollTop = Math.floor(
		(props.owners.codeScrollOwner.scrollHeight - props.owners.codeScrollOwner.clientHeight) *
			fraction,
	);
	const treeScrollTop = Math.floor(
		(props.owners.treeScrollOwner.scrollHeight - props.owners.treeScrollOwner.clientHeight) *
			fraction,
	);
	await actUpdate((): void => {
		props.owners.treeScrollOwner.scrollTop = treeScrollTop;
		props.owners.treeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
		props.owners.codeScrollOwner.scrollTop = codeScrollTop;
		props.owners.codeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
	});
	await actFrame();
	await assertDeepScrollSurfaceInvariantWithDiagnostics({
		minimumCodeScrollTop: Math.max(props.previousCodeScrollTop, codeScrollTop - 1),
		minimumTreeScrollTop: Math.max(props.previousTreeScrollTop, treeScrollTop - 1),
		owners: props.owners,
		step: `fraction-${fraction}`,
	});
	await actFrame();
	const settledSnapshot = await assertDeepScrollSurfaceInvariantWithDiagnostics({
		minimumCodeScrollTop: Math.max(props.previousCodeScrollTop, codeScrollTop - 1),
		minimumTreeScrollTop: Math.max(props.previousTreeScrollTop, treeScrollTop - 1),
		owners: props.owners,
		step: `fraction-${fraction}-settled`,
	});
	await runDeepScrollSequence({
		fractionIndex: props.fractionIndex + 1,
		owners: props.owners,
		previousCodeScrollTop: settledSnapshot.codeScrollTop,
		previousTreeScrollTop: settledSnapshot.treeScrollTop,
	});
}

async function assertDeepScrollSurfaceInvariantWithDiagnostics(props: {
	readonly minimumCodeScrollTop?: number;
	readonly minimumTreeScrollTop?: number;
	readonly owners: DeepScrollOwners;
	readonly step: string;
}): Promise<DeepScrollSurfaceSnapshot> {
	try {
		return assertDeepScrollSurfaceInvariant(props);
	} catch (error: unknown) {
		if (routeProductSessionHost === null) throw error;
		const productTrace = await fetch('/__g0-product-trace?summary=1').then(
			async (response): Promise<unknown> => await response.json(),
			(): null => null,
		);
		const message = error instanceof Error ? error.message : String(error);
		throw new Error(
			`${message} productTrace=${JSON.stringify(productTrace)} worker=${realViteFileWorkerDiagnostic()}`,
			{ cause: error },
		);
	}
}

function assertDeepScrollSurfaceInvariant(props: {
	readonly minimumCodeScrollTop?: number;
	readonly minimumTreeScrollTop?: number;
	readonly owners: DeepScrollOwners;
	readonly step: string;
}): DeepScrollSurfaceSnapshot {
	const currentTreeScrollOwner = findBridgeViewerTreeScrollOwner();
	const currentCodeScrollOwner = document.querySelector('.bridge-code-view-scroll-owner');
	const fileTreeContainer = document.querySelector('file-tree-container');
	const codeCanvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
	if (!(fileTreeContainer instanceof HTMLElement) || !(codeCanvas instanceof HTMLElement)) {
		throw new Error(
			`FILE_DEEP_SCROLL_SURFACE_DISAPPEARED: step=${props.step} tree=${fileTreeContainer === null ? 'missing' : 'invalid'} code=${codeCanvas === null ? 'missing' : 'invalid'}`,
		);
	}
	if (
		currentTreeScrollOwner !== props.owners.treeScrollOwner ||
		currentCodeScrollOwner !== props.owners.codeScrollOwner ||
		!props.owners.treeScrollOwner.isConnected ||
		!props.owners.codeScrollOwner.isConnected
	) {
		throw new Error(
			`FILE_DEEP_SCROLL_SCROLL_OWNER_REPLACED: step=${props.step} treeSame=${currentTreeScrollOwner === props.owners.treeScrollOwner} codeSame=${currentCodeScrollOwner === props.owners.codeScrollOwner} treeConnected=${props.owners.treeScrollOwner.isConnected} codeConnected=${props.owners.codeScrollOwner.isConnected}`,
		);
	}
	assertDeepScrollRouteInvariant({ owners: props.owners, step: props.step });
	const codeGeometry = bridgeViewerCodeGeometry();
	const snapshot: DeepScrollSurfaceSnapshot = {
		code: surfacePaintSnapshot(codeCanvas),
		codeContainerCount: codeGeometry.containerCount,
		codeLineCount: codeGeometry.lineCount,
		codeScrollTop: props.owners.codeScrollOwner.scrollTop,
		codeVisibleCharacterCount: bridgeViewerVisibleCodeTextContent(
			props.owners.codeScrollOwner,
		).trim().length,
		renderedPath: renderedFilePath(),
		selectedPath: selectedDisplayPath(),
		tree: surfacePaintSnapshot(fileTreeContainer),
		treeScrollTop: props.owners.treeScrollOwner.scrollTop,
		treeVisiblePathCount: bridgeViewerVisibleTreeItemPaths(props.owners.treeScrollOwner).length,
	};
	const hasPositiveSurfacePaint =
		hasPositivePaint(snapshot.tree) &&
		hasPositivePaint(snapshot.code) &&
		snapshot.treeVisiblePathCount > 0 &&
		snapshot.codeContainerCount > 0 &&
		snapshot.codeLineCount > 0 &&
		snapshot.codeVisibleCharacterCount > 0;
	if (!hasPositiveSurfacePaint) {
		throw new Error(
			`FILE_DEEP_SCROLL_SURFACE_DISAPPEARED: step=${props.step} geometry=${JSON.stringify(snapshot)}`,
		);
	}
	if (
		selectedDisplayPath() !== props.owners.expectedSelectedPath ||
		openFilePath() !== props.owners.expectedSelectedPath ||
		renderedFilePath() !== props.owners.expectedSelectedPath ||
		openFileState() !== 'ready' ||
		codeCanvas.getAttribute('data-pierre-code-view-owner') !== 'CodeView.file' ||
		codeCanvas.getAttribute('data-shiki-rendering') !== 'pierre'
	) {
		throw new Error(
			`FILE_DEEP_SCROLL_IDENTITY_DIVERGED: step=${props.step} selected=${selectedDisplayPath() ?? 'missing'} open=${openFilePath() ?? 'missing'} rendered=${renderedFilePath() ?? 'missing'} state=${openFileState() ?? 'missing'} pierreOwner=${codeCanvas.getAttribute('data-pierre-code-view-owner') ?? 'missing'}`,
		);
	}
	if (
		snapshot.codeScrollTop < (props.minimumCodeScrollTop ?? 0) ||
		snapshot.treeScrollTop < (props.minimumTreeScrollTop ?? 0)
	) {
		throw new Error(
			`FILE_DEEP_SCROLL_POSITION_REGRESSED: step=${props.step} tree=${snapshot.treeScrollTop}/${props.minimumTreeScrollTop ?? 0} code=${snapshot.codeScrollTop}/${props.minimumCodeScrollTop ?? 0}`,
		);
	}
	return snapshot;
}

interface RealViteFileMetadataState {
	readonly identity: string;
	readonly treeRowCount: number;
}

async function waitForRealViteFileMetadataStable(props: {
	readonly attempt: number;
	readonly previousIdentity: string | null;
	readonly stableFrameCount: number;
}): Promise<RealViteFileMetadataState> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	if (shell instanceof HTMLElement) {
		const fileItemCount = Number(shell.getAttribute('data-file-display-item-count'));
		const generation = shell.getAttribute('data-file-display-generation');
		const sourceId = shell.getAttribute('data-file-display-source-id');
		const treeRowCount = Number(shell.getAttribute('data-file-display-tree-row-count'));
		const metadataReady =
			shell.getAttribute('data-file-display-status') === 'ready' &&
			sourceId !== null &&
			sourceId.length > 0 &&
			generation !== null &&
			generation.length > 0 &&
			Number.isSafeInteger(fileItemCount) &&
			fileItemCount > 0 &&
			Number.isSafeInteger(treeRowCount) &&
			treeRowCount >= 1_000;
		const selectedPath = shell.getAttribute('data-selected-display-path');
		if (metadataReady && selectedPath !== null) {
			throw new Error(`FILE_DEEP_SCROLL_REAL_VITE_AUTO_OPENED: selected=${selectedPath}`);
		}
		if (metadataReady) {
			const identity = `${sourceId}:${generation}:${treeRowCount}:${fileItemCount}`;
			const stableFrameCount = identity === props.previousIdentity ? props.stableFrameCount + 1 : 0;
			if (stableFrameCount >= 12) {
				return { identity, treeRowCount };
			}
			await actFrame();
			return await waitForRealViteFileMetadataStable({
				attempt: props.attempt + 1,
				previousIdentity: identity,
				stableFrameCount,
			});
		}
	}
	if (props.attempt >= 600) {
		throw new Error(
			`FILE_DEEP_SCROLL_REAL_VITE_PROVIDER_FAILED: shell=${shell instanceof HTMLElement ? shell.outerHTML.slice(0, 800) : 'missing'}`,
		);
	}
	await actFrame();
	return await waitForRealViteFileMetadataStable({
		attempt: props.attempt + 1,
		previousIdentity: props.previousIdentity,
		stableFrameCount: props.stableFrameCount,
	});
}

async function waitForFirstVisibleRealViteFileButton(props: {
	readonly attempt: number;
}): Promise<HTMLButtonElement> {
	const treeContainer = document.querySelector('file-tree-container');
	const fileButton = treeContainer?.shadowRoot?.querySelector(
		'button[data-type="item"][data-item-type="file"][data-item-path]',
	);
	if (fileButton instanceof HTMLButtonElement && fileButton.getClientRects().length > 0) {
		return fileButton;
	}
	if (props.attempt >= 180) {
		throw new Error('FILE_DEEP_SCROLL_REAL_VITE_VISIBLE_FILE_MISSING');
	}
	await actFrame();
	return await waitForFirstVisibleRealViteFileButton({ attempt: props.attempt + 1 });
}

async function waitForRealViteSelectedFileReady(props: {
	readonly attempt: number;
	readonly selectedPath: string;
	readonly treeRowCount: number;
}): Promise<void> {
	const shell = document.querySelector('[data-testid="bridge-file-viewer-shell"]');
	if (shell instanceof HTMLElement) {
		const selectedPath = shell.getAttribute('data-selected-display-path');
		const selectedOpenFilePath = shell.getAttribute('data-worktree-open-file-path');
		const openFileStatus = shell.getAttribute('data-worktree-open-file-state');
		if (
			selectedPath === props.selectedPath &&
			(openFileStatus === 'failed' || openFileStatus === 'unavailable')
		) {
			throw new Error(
				`G0 FILE REAL VITE CONTENT UNAVAILABLE: selected=${selectedPath} openState=${openFileStatus} treeRows=${props.treeRowCount} worker=${realViteFileWorkerDiagnostic()}`,
			);
		}
		if (
			selectedPath === props.selectedPath &&
			selectedOpenFilePath === props.selectedPath &&
			openFileStatus === 'ready'
		) {
			return;
		}
	}
	if (props.attempt >= 600) {
		const productTrace = await fetch('/__g0-product-trace').then(
			async (response): Promise<unknown> => await response.json(),
			(): null => null,
		);
		throw new Error(
			`FILE_DEEP_SCROLL_REAL_VITE_CONTENT_FAILED: selected=${props.selectedPath} productTrace=${JSON.stringify(productTrace)} worker=${realViteFileWorkerDiagnostic()} shell=${shell instanceof HTMLElement ? shell.outerHTML.slice(0, 800) : 'missing'}`,
		);
	}
	await actFrame();
	await waitForRealViteSelectedFileReady({ ...props, attempt: props.attempt + 1 });
}

function realViteFileWorkerDiagnostic(): string {
	if (routePaneRuntime === null) return 'missing';
	return JSON.stringify({
		fileLifecycle: routePaneRuntime.surfaceClient('fileView').lifecycle.getSnapshot(),
		renderFreshness: routePaneRuntime.surfaceClient('fileView').renderStore.getSnapshot()
			.fileDisplayFreshness,
	});
}

function assertDeepScrollRouteInvariant(props: {
	readonly owners: DeepScrollOwners;
	readonly step: string;
}): void {
	const routeOwners = props.owners.routeOwners;
	if (routeOwners === undefined) {
		return;
	}
	const currentAppRoot = document.querySelector('[data-testid="bridge-app-root"]');
	const currentFileModeHost = document.querySelector(
		'[data-testid="bridge-viewer-mode-host-file"]',
	);
	const appRootPaint = surfacePaintSnapshot(routeOwners.appRoot);
	const fileModeHostPaint = surfacePaintSnapshot(routeOwners.fileModeHost);
	if (
		currentAppRoot !== routeOwners.appRoot ||
		currentFileModeHost !== routeOwners.fileModeHost ||
		!routeOwners.appRoot.isConnected ||
		!routeOwners.fileModeHost.isConnected ||
		routeOwners.fileModeHost.hidden ||
		routeOwners.appRoot.getAttribute('data-bridge-viewer-mode') !== 'file' ||
		!hasPositivePaint(appRootPaint) ||
		!hasPositivePaint(fileModeHostPaint)
	) {
		throw new Error(
			`FILE_DEEP_SCROLL_ROUTE_LIVENESS_BROKE: step=${props.step} appRootSame=${currentAppRoot === routeOwners.appRoot} fileModeHostSame=${currentFileModeHost === routeOwners.fileModeHost} appRootConnected=${routeOwners.appRoot.isConnected} fileModeHostConnected=${routeOwners.fileModeHost.isConnected} fileModeHidden=${routeOwners.fileModeHost.hidden} mode=${routeOwners.appRoot.getAttribute('data-bridge-viewer-mode') ?? 'missing'} appGeometry=${JSON.stringify(appRootPaint)} hostGeometry=${JSON.stringify(fileModeHostPaint)}`,
		);
	}
}

function surfacePaintSnapshot(element: HTMLElement): DeepScrollSurfacePaintSnapshot {
	const rectangle = element.getBoundingClientRect();
	const style = getComputedStyle(element);
	return {
		clientRectCount: element.getClientRects().length,
		height: Math.round(rectangle.height),
		opacity: style.opacity,
		visibility: style.visibility,
		width: Math.round(rectangle.width),
	};
}

function hasPositivePaint(snapshot: DeepScrollSurfacePaintSnapshot): boolean {
	return (
		snapshot.clientRectCount > 0 &&
		snapshot.height > 0 &&
		snapshot.width > 0 &&
		snapshot.opacity !== '0' &&
		snapshot.visibility !== 'hidden'
	);
}

async function waitForDeepScrollFinalSource(props: {
	readonly attempt: number;
	readonly owners: DeepScrollOwners;
}): Promise<void> {
	const visibleSourceText = bridgeViewerVisibleCodeTextContent(props.owners.codeScrollOwner);
	if (visibleSourceText.includes(completeFileDeepScrollFixture.finalSourceText)) {
		return;
	}
	if (props.attempt >= 120) {
		throw new Error(
			`FILE_DEEP_SCROLL_FINAL_SOURCE_UNREADABLE: selected=${selectedDisplayPath() ?? 'missing'} rendered=${renderedFilePath() ?? 'missing'} codeScrollTop=${props.owners.codeScrollOwner.scrollTop} codeScrollHeight=${props.owners.codeScrollOwner.scrollHeight} visible=${visibleSourceText.slice(-240)}`,
		);
	}
	await actUpdate((): void => {
		props.owners.codeScrollOwner.scrollTop =
			props.owners.codeScrollOwner.scrollHeight - props.owners.codeScrollOwner.clientHeight;
		props.owners.codeScrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
	});
	await actFrame();
	assertDeepScrollSurfaceInvariant({
		owners: props.owners,
		step: `final-source-wait-${props.attempt}`,
	});
	await waitForDeepScrollFinalSource({ attempt: props.attempt + 1, owners: props.owners });
}

async function waitForPierreWorkerRouteReady(props: { readonly attempt: number }): Promise<void> {
	const workerState = document.documentElement.dataset['bridgePierreWorkerPoolState'];
	const themeState = document.documentElement.dataset['bridgePierreCodeViewThemeState'];
	if (workerState === 'ready' && themeState === 'ready') {
		return;
	}
	if (props.attempt >= 120 || workerState === 'failed' || themeState === 'failed') {
		throw new Error(
			`FILE_DEEP_SCROLL_HARNESS_INVALID: Pierre route worker/theme did not become ready; worker=${workerState ?? 'missing'} theme=${themeState ?? 'missing'}`,
		);
	}
	await actFrame();
	await waitForPierreWorkerRouteReady({ attempt: props.attempt + 1 });
}
