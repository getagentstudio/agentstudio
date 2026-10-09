import { readFile, realpath, writeFile } from 'node:fs/promises';

import type { Page } from 'playwright';

import { installBridgeProductFileBatch } from '../../src/core/comm-worker/bridge-product-file-batch-installer.ts';
import type { BridgeProductViewInstallation } from '../../src/core/comm-worker/bridge-product-view-batch-receiver.ts';
import { resolveBridgeWorktreeVerifierWritePath } from '../verify-bridge-viewer-worktree-dev-server-paths.ts';
import { requireVerifierBrowser } from './browser-session.ts';
import {
	execFileAsync,
	proofRunCreatedAtUnixMilliseconds,
	repoRootPath,
	scenarioNameFromDevServerUrl,
	selectedContentFixtureRelativePath,
	targetPathOverride,
	worktreeDevServerUrl,
} from './config.ts';
import { BridgeVerifierProductFileSession } from './product-file-session.ts';
import { worktreeFilePathEligibleForPerformanceClick } from './scroll-performance.ts';
import {
	interactionPerformanceSampleCount,
	maximumNormalPerformanceLineCount,
	type WorktreeDevServerBrowserProof,
	type WorktreeFileDescriptor,
	type WorktreeFileSurface,
	type WorktreeFileTreeRow,
	type WorktreeProductFileDescriptor,
} from './types.ts';
import { hashText, isNodeErrorWithCode } from './utils.ts';

const worktreeFileRowHeightPixels = 24;
const productFileSessionBySurface = new WeakMap<
	WorktreeFileSurface,
	BridgeVerifierProductFileSession
>();
const productFileSessionByDescriptor = new WeakMap<
	WorktreeFileDescriptor,
	BridgeVerifierProductFileSession
>();
const liveProductFileSurfaces = new Set<WorktreeFileSurface>();

export async function fetchWorktreeSurface(): Promise<WorktreeFileSurface> {
	await closeAllWorktreeFileSurfaces();
	const session = new BridgeVerifierProductFileSession({
		baseUrl: new URL(worktreeDevServerUrl).origin,
		scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
	});
	const productSource = await session.open();
	const pathCount = worktreeFileTreeRows(productSource.installations).length;
	const surface: WorktreeFileSurface = {
		frames: productSource.installations,
		provenance: {
			baseRef: 'HEAD',
			scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
			worktreeRootToken: await bridgeWorktreeDevRootTokenForPath(repoRootPath),
		},
		source: productSource.sourceIdentity,
		treeSizeFacts: {
			estimatedTotalHeightPixels: pathCount * worktreeFileRowHeightPixels,
			pathCount,
			rowHeightPixels: worktreeFileRowHeightPixels,
		},
	};
	productFileSessionBySurface.set(surface, session);
	liveProductFileSurfaces.add(surface);
	return surface;
}

export async function closeWorktreeFileSurface(surface: WorktreeFileSurface): Promise<void> {
	const session = productFileSessionBySurface.get(surface);
	if (session === undefined) return;
	productFileSessionBySurface.delete(surface);
	liveProductFileSurfaces.delete(surface);
	if (session.state === 'open') await session.close();
}

export async function closeAllWorktreeFileSurfaces(): Promise<void> {
	await Promise.all([...liveProductFileSurfaces].map(closeWorktreeFileSurface));
}

export function openWorktreeFileSurfaceCount(): number {
	return liveProductFileSurfaces.size;
}

export async function readBrowserProof(page: Page): Promise<WorktreeDevServerBrowserProof> {
	const browser = requireVerifierBrowser();
	const viewport = page.viewportSize();
	return {
		browserName: browser.browserType().name(),
		browserVersion: browser.version(),
		headless: true,
		viewportHeight: viewport?.height ?? 0,
		viewportWidth: viewport?.width ?? 0,
	};
}

export function assertWorktreeTreeExtentMatchesSurfaceFacts(props: {
	readonly renderedTreeTotalSizePixels: number;
	readonly surfaceTreeSizeFacts: WorktreeFileSurface['treeSizeFacts'];
}): void {
	const expectedHeight = props.surfaceTreeSizeFacts.estimatedTotalHeightPixels ?? null;
	if (expectedHeight === null) {
		throw new Error(
			`Expected provider Worktree/File estimated tree extent facts: ${JSON.stringify(props.surfaceTreeSizeFacts)}`,
		);
	}
	if (Math.abs(props.renderedTreeTotalSizePixels - expectedHeight) > 1) {
		throw new Error(
			`Expected rendered tree extent to match provider facts: ${JSON.stringify({
				expectedHeight,
				renderedTreeTotalSizePixels: props.renderedTreeTotalSizePixels,
				surfaceTreeSizeFacts: props.surfaceTreeSizeFacts,
			})}`,
		);
	}
}

export async function bridgeWorktreeDevRootTokenForPath(path: string): Promise<string> {
	return `root-${hashText(await realpath(path)).slice(0, 32)}`;
}

export function worktreeFileTreeRows(
	frames: readonly BridgeProductViewInstallation[],
): readonly WorktreeFileTreeRow[] {
	const latestInstallation = frames.at(-1);
	return latestInstallation === undefined
		? []
		: installBridgeProductFileBatch(latestInstallation).displayTreeRows;
}

export function worktreeFileDemandCandidatePaths(surface: WorktreeFileSurface): readonly string[] {
	return worktreeFileTreeRows(surface.frames)
		.filter((row): boolean => !row.isDirectory && row.fileId !== null)
		.map((row): string => row.path);
}

export async function resolveTargetDescriptor(
	surface: WorktreeFileSurface,
): Promise<WorktreeFileDescriptor> {
	if (targetPathOverride !== null) {
		return await fetchFetchableWorktreeFileDescriptorForPath({
			path: targetPathOverride,
			surface,
		});
	}
	return await fetchFetchableWorktreeFileDescriptorForPath({
		path: selectedContentFixtureRelativePath,
		surface,
	});
}

export async function fetchPerformanceWorktreeFileDescriptors(
	surface: WorktreeFileSurface,
): Promise<readonly WorktreeFileDescriptor[]> {
	const descriptors: WorktreeFileDescriptor[] = [];
	for (const path of worktreeFileDemandCandidatePaths(surface).filter(
		worktreeFilePathEligibleForPerformanceClick,
	)) {
		const descriptor = await fetchWorktreeFileDescriptorForPath({ path, surface });
		if (isNormalWorktreeFilePerformanceDescriptor(descriptor)) {
			descriptors.push(descriptor);
		}
		if (descriptors.length >= interactionPerformanceSampleCount) {
			break;
		}
	}
	if (descriptors.length < interactionPerformanceSampleCount) {
		throw new Error(
			`Expected at least ${interactionPerformanceSampleCount} demanded normal Worktree/File descriptors for performance proof, got ${descriptors.length}`,
		);
	}
	return descriptors;
}

export async function fetchFirstFetchableWorktreeFileDescriptor(
	surface: WorktreeFileSurface,
): Promise<WorktreeFileDescriptor> {
	for (const path of worktreeFileDemandCandidatePaths(surface)) {
		const descriptor = await fetchWorktreeFileDescriptorForPath({ path, surface });
		if (!descriptor.isBinary && descriptor.virtualizedExtentKind === 'exactLineCount') {
			return descriptor;
		}
	}
	throw new Error('Expected at least one demanded fetchable Worktree/File descriptor');
}

export async function fetchFetchableWorktreeFileDescriptorForPath(props: {
	readonly path: string;
	readonly surface: WorktreeFileSurface;
}): Promise<WorktreeFileDescriptor> {
	const descriptor = await fetchWorktreeFileDescriptorForPath(props);
	if (descriptor.isBinary || descriptor.virtualizedExtentKind !== 'exactLineCount') {
		throw new Error(`Expected an existing fetchable Worktree/File descriptor for ${props.path}`);
	}
	return descriptor;
}

export async function fetchWorktreeFileDescriptorForPath(props: {
	readonly path: string;
	readonly surface: WorktreeFileSurface;
}): Promise<WorktreeFileDescriptor> {
	const knownPath = worktreeFileDemandCandidatePaths(props.surface).includes(props.path);
	if (!knownPath) {
		throw new Error(`Expected Worktree/File tree metadata row for ${props.path}`);
	}
	const session = productFileSessionBySurface.get(props.surface);
	if (session === undefined) {
		throw new Error('Worktree/File surface does not own a typed product session.');
	}
	const productDescriptor = await session.demandDescriptor(props.path);
	if (productDescriptor.path !== props.path) {
		throw new Error(
			`Expected demanded Worktree/File descriptor for ${props.path}, got ${productDescriptor.path}`,
		);
	}
	const descriptor = verifierDescriptorFromProductDescriptor(productDescriptor);
	productFileSessionByDescriptor.set(descriptor, session);
	return descriptor;
}

export function isNormalWorktreeFilePerformanceDescriptor(
	descriptor: WorktreeFileDescriptor,
): boolean {
	const lineCount = Number(descriptor.lineCount ?? 0);
	return (
		worktreeFilePathEligibleForPerformanceClick(descriptor.path) &&
		!descriptor.isBinary &&
		descriptor.virtualizedExtentKind === 'exactLineCount' &&
		Number.isFinite(lineCount) &&
		lineCount > 0 &&
		lineCount <= maximumNormalPerformanceLineCount
	);
}

export interface WorktreeFileModifiedFixture {
	readonly absolutePath: string;
	readonly initialContent: string;
	readonly initialContentHash: string;
	readonly relativePath: string;
	readonly updatedContent: string;
	readonly updatedContentHash: string;
}

export interface WorktreeFileStaleRefreshFixture extends WorktreeFileModifiedFixture {}

export async function worktreeFileModifiedFixture(props: {
	readonly markerPlacement?: 'append' | 'prependComment';
	readonly relativePath: string;
	readonly tag: string;
}): Promise<WorktreeFileModifiedFixture> {
	const absolutePath = await resolveBridgeWorktreeVerifierWritePath({
		descriptorPath: props.relativePath,
		rootPath: repoRootPath,
	});
	await assertGitTrackedWorktreeVerifierPath(props.relativePath);
	const initialContent = await readFile(absolutePath, 'utf8');
	const marker = `bridge_worktree_devserver_${props.tag}_${proofRunCreatedAtUnixMilliseconds}`;
	const updatedContent =
		props.markerPlacement === 'prependComment'
			? `// ${marker}\n${initialContent}`
			: initialContent.endsWith('\n')
				? `${initialContent}${marker}\n`
				: `${initialContent}\n${marker}\n`;
	const fixture = {
		absolutePath,
		initialContent,
		initialContentHash: hashText(initialContent),
		relativePath: props.relativePath,
		updatedContent,
		updatedContentHash: hashText(updatedContent),
	};
	await writeFile(absolutePath, updatedContent);
	return fixture;
}

export async function worktreeFileStaleRefreshFixture(props: {
	readonly descriptor: WorktreeFileDescriptor;
	readonly initialContent: string;
}): Promise<WorktreeFileStaleRefreshFixture> {
	const marker = `bridge_worktree_devserver_proof_${proofRunCreatedAtUnixMilliseconds}`;
	const absolutePath = await resolveBridgeWorktreeVerifierWritePath({
		descriptorPath: props.descriptor.path,
		rootPath: repoRootPath,
	});
	await assertGitTrackedWorktreeVerifierPath(props.descriptor.path);
	const initialContent = await readFile(absolutePath, 'utf8');
	const updatedContent = `${initialContent}\n// ${marker}: updated content\n`;
	return {
		absolutePath,
		initialContent,
		initialContentHash: hashText(initialContent),
		relativePath: props.descriptor.path,
		updatedContent,
		updatedContentHash: hashText(updatedContent),
	};
}

export async function assertGitTrackedWorktreeVerifierPath(relativePath: string): Promise<void> {
	try {
		await execFileAsync('git', [
			'-C',
			repoRootPath,
			'ls-files',
			'--error-unmatch',
			'--',
			relativePath,
		]);
	} catch (error) {
		throw new Error(`Bridge worktree verifier path must be git-tracked: ${relativePath}`, {
			cause: error,
		});
	}
}

export async function restoreWorktreeFileStaleRefreshFixture(
	fixture: WorktreeFileStaleRefreshFixture,
): Promise<void> {
	await restoreWorktreeFileModifiedFixture(fixture);
}

export async function restoreWorktreeFileModifiedFixture(
	fixture: WorktreeFileModifiedFixture,
): Promise<void> {
	const currentHash = await readTextFileHashOrNull(fixture.absolutePath);
	if (currentHash !== fixture.initialContentHash && currentHash !== fixture.updatedContentHash) {
		throw new Error(
			`Refusing to restore modified proof file after external edit: ${fixture.relativePath}`,
		);
	}
	if (currentHash === fixture.updatedContentHash) {
		await writeFile(fixture.absolutePath, fixture.initialContent);
	}
	const restoredContent = await readFile(fixture.absolutePath, 'utf8');
	if (hashText(restoredContent) !== fixture.initialContentHash) {
		throw new Error(`Failed to restore modified proof file: ${fixture.relativePath}`);
	}
}

export async function readTextFileHashOrNull(absolutePath: string): Promise<string | null> {
	try {
		return hashText(await readFile(absolutePath, 'utf8'));
	} catch (error) {
		if (isNodeErrorWithCode(error, 'ENOENT')) {
			return null;
		}
		throw error;
	}
}

export async function fetchWorktreeFileContent(
	descriptor: WorktreeFileDescriptor,
): Promise<string> {
	const session = productFileSessionByDescriptor.get(descriptor);
	if (session === undefined) {
		throw new Error('Worktree/File descriptor does not own a typed product session.');
	}
	const content = await session.openContent(descriptor);
	return new TextDecoder().decode(content.bytes);
}

function verifierDescriptorFromProductDescriptor(
	productDescriptor: WorktreeProductFileDescriptor,
): WorktreeFileDescriptor {
	const availableContentDescriptor =
		productDescriptor.availability.availabilityKind === 'available'
			? productDescriptor.availability.contentDescriptor
			: null;
	return {
		...productDescriptor,
		contentDescriptor: {
			descriptor: {
				content:
					availableContentDescriptor === null
						? null
						: {
								expectedBytes: availableContentDescriptor.declaredByteLength,
								maxBytes: availableContentDescriptor.maximumBytes,
							},
			},
		},
		contentHandle: availableContentDescriptor?.descriptorId ?? productDescriptor.fileId,
		...(availableContentDescriptor === null
			? {}
			: { contentHash: availableContentDescriptor.expectedSha256 }),
		isBinary: productDescriptor.availability.availabilityKind === 'binary',
		...(productDescriptor.totalLineCount === null
			? {}
			: { lineCount: productDescriptor.totalLineCount }),
	};
}
