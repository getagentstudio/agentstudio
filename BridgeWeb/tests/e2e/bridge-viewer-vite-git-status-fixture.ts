import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { copyFile, mkdir, mkdtemp, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import type { BridgeViewerViteProductFixtureOracle } from './bridge-viewer-vite-product-fixture.ts';

const execFileAsync = promisify(execFile);

export interface BridgeViewerGitStatusFixture {
	readonly addedSourcePath: string;
	readonly addedTestTreePaths: readonly string[];
	readonly dispose: () => Promise<void>;
	readonly expectedAllTreePaths: readonly string[];
	readonly expectedWithBinaryAndLargeTreePaths: readonly string[];
	readonly expectedWithBinaryTreePaths: readonly string[];
	readonly expectedWithLargeTreePaths: readonly string[];
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly selectedSourceContentMarker: string;
	readonly statusCases: readonly BridgeViewerGitStatusCase[];
}

export interface BridgeViewerGitStatusCase {
	readonly expectedTreePaths: readonly string[];
	readonly label: 'Added' | 'Copied' | 'Deleted' | 'Modified' | 'Renamed';
}

interface FixtureMutationPaths {
	readonly added: readonly string[];
	readonly deleted: readonly string[];
	readonly modified: readonly string[];
	readonly renamed: readonly string[];
}

const corpusRoot = 'git-status-corpus';
const modifiedSourcePath = `${corpusRoot}/source/modified.ts`;
const modifiedTestPath = `${corpusRoot}/specimens/modified.test.ts`;
const deletedPath = `${corpusRoot}/source/deleted.ts`;
const renameSourcePath = `${corpusRoot}/source/rename-source.ts`;
const renamedPath = `${corpusRoot}/source/renamed.ts`;
const copySourcePath = `${corpusRoot}/source/copy-source.ts`;
const copyCandidatePath = `${corpusRoot}/source/copy-candidate.ts`;
const addedSourcePath = `${corpusRoot}/source/added.ts`;
const addedTestPath = `${corpusRoot}/specimens/added.test.ts`;
const binaryPath = `${corpusRoot}/assets/payload.bin`;
const largePath = `${corpusRoot}/assets/large.txt`;
const selectedSourceContentMarker = 'GIT_STATUS_FILTER_CONTENT_RECOVERY_MARKER';

const hiddenByDefaultPaths = [binaryPath, largePath] as const;

const fixtureMutationPaths: FixtureMutationPaths = {
	added: [addedSourcePath, addedTestPath, copyCandidatePath],
	deleted: [deletedPath],
	modified: [modifiedSourcePath, modifiedTestPath],
	renamed: [renamedPath],
};

export async function createBridgeViewerGitStatusFixture(): Promise<BridgeViewerGitStatusFixture> {
	const worktreeRoot = await mkdtemp(join(tmpdir(), 'bridge-viewer-git-status-e2e-'));
	let dataRootPath: string | null = null;
	try {
		dataRootPath = await mkdtemp(join(tmpdir(), 'bridge-viewer-git-status-data-'));
		await writeBaseFiles(worktreeRoot);
		await runFixtureGit(worktreeRoot, ['init', '--initial-branch=main']);
		await runFixtureGit(worktreeRoot, ['config', 'user.name', 'Bridge Git Status E2E']);
		await runFixtureGit(worktreeRoot, [
			'config',
			'user.email',
			'bridge-git-status-e2e@example.invalid',
		]);
		await runFixtureGit(worktreeRoot, ['add', '--all']);
		await runFixtureGit(worktreeRoot, [
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'git status fixture base',
		]);
		const baseRef = (await runFixtureGit(worktreeRoot, ['rev-parse', 'HEAD'])).trim();
		await applyWorkingTreeMutations(worktreeRoot);
		await assertFixtureGitShapes(worktreeRoot);

		const visibleChangedPaths = Object.values(fixtureMutationPaths)
			.flat()
			.toSorted((left, right): number => left.localeCompare(right));
		const changedPaths = [...visibleChangedPaths, ...hiddenByDefaultPaths].toSorted(
			(left, right): number => left.localeCompare(right),
		);
		const expectedAllTreePaths = reviewTreePathsForFiles(visibleChangedPaths);
		return {
			addedSourcePath,
			addedTestTreePaths: reviewTreePathsForFiles([addedTestPath]),
			dispose: async (): Promise<void> => {
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'Git status fixture worktree',
							run: async (): Promise<void> => {
								await rm(worktreeRoot, { force: true, recursive: true });
							},
						},
						{
							name: 'Git status fixture data root',
							run: async (): Promise<void> => {
								if (dataRootPath !== null) {
									await rm(dataRootPath, { force: true, recursive: true });
								}
							},
						},
					],
				});
			},
			expectedAllTreePaths,
			expectedWithBinaryAndLargeTreePaths: reviewTreePathsForFiles(changedPaths),
			expectedWithBinaryTreePaths: reviewTreePathsForFiles([...visibleChangedPaths, binaryPath]),
			expectedWithLargeTreePaths: reviewTreePathsForFiles([...visibleChangedPaths, largePath]),
			oracle: {
				baseRef,
				changedPaths,
				comparisonTargetName: 'main',
				dataRootPath,
				expectedReviewItemIds: [],
				fileContent: {
					byteLength: 0,
					finalMarker: '',
					firstMarker: '',
					lineCount: 0,
					middleMarker: '',
					sha256: '',
				},
				fileTreeDeepPath: renamedPath,
				largeFileLineCount: 0,
				largeFilePath: '',
				largeFileSha256: '',
				paneId: randomUUID(),
				reviewFiles: [],
				worktreeRoot,
			},
			selectedSourceContentMarker,
			statusCases: [
				statusCase('Added', fixtureMutationPaths.added),
				statusCase('Modified', fixtureMutationPaths.modified),
				statusCase('Renamed', fixtureMutationPaths.renamed),
				statusCase('Deleted', fixtureMutationPaths.deleted),
				// The pinned primary comparison path calls git_diff_find_similar with
				// GIT_DIFF_FIND_RENAMES only. Its identical untracked destination remains Added,
				// so this is honest empty-state coverage rather than positive Copied proof.
				statusCase('Copied', []),
			],
		};
	} catch (error: unknown) {
		await runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'Git status fixture worktree',
					run: async (): Promise<void> => {
						await rm(worktreeRoot, { force: true, recursive: true });
					},
				},
				{
					name: 'Git status fixture data root',
					run: async (): Promise<void> => {
						if (dataRootPath !== null) {
							await rm(dataRootPath, { force: true, recursive: true });
						}
					},
				},
			],
			primaryError: error,
		});
		throw error;
	}
}

async function writeBaseFiles(worktreeRoot: string): Promise<void> {
	const baseFiles: Readonly<Record<string, string | Uint8Array>> = {
		[binaryPath]: new Uint8Array([0, 1, 2, 3]),
		[copySourcePath]: "export const copySource = 'unchanged-copy-source';\n",
		[deletedPath]: "export const deletedRevision = 'base';\n",
		[largePath]: new Uint8Array(1_000_000).fill(97),
		[modifiedSourcePath]: "export const sourceRevision = 'base';\n",
		[modifiedTestPath]: "export const testRevision = 'base';\n",
		[renameSourcePath]: "export const renameRevision = 'base';\n",
	};
	for (const [relativePath, body] of Object.entries(baseFiles)) {
		const absolutePath = join(worktreeRoot, relativePath);
		// oxlint-disable-next-line no-await-in-loop -- Every deterministic base path must exist before Git observes it.
		await mkdir(dirname(absolutePath), { recursive: true });
		// oxlint-disable-next-line no-await-in-loop -- Stable fixture order makes setup failures reproducible.
		await writeFile(absolutePath, body);
	}
}

async function applyWorkingTreeMutations(worktreeRoot: string): Promise<void> {
	await writeFile(join(worktreeRoot, binaryPath), new Uint8Array([0, 3, 2, 1]));
	const changedLargeBody = new Uint8Array(1_000_000).fill(97);
	changedLargeBody[0] = 98;
	await writeFile(join(worktreeRoot, largePath), changedLargeBody);
	await writeFile(
		join(worktreeRoot, modifiedSourcePath),
		"export const sourceRevision = 'working-tree';\n",
	);
	await writeFile(
		join(worktreeRoot, modifiedTestPath),
		"export const testRevision = 'working-tree';\n",
	);
	await unlink(join(worktreeRoot, deletedPath));
	await runFixtureGit(worktreeRoot, ['mv', renameSourcePath, renamedPath]);
	await writeFile(
		join(worktreeRoot, addedSourcePath),
		`export const addedSource = '${selectedSourceContentMarker}';\n`,
	);
	await writeFile(join(worktreeRoot, addedTestPath), 'export const addedTest = true;\n');
	await copyFile(join(worktreeRoot, copySourcePath), join(worktreeRoot, copyCandidatePath));
}

async function assertFixtureGitShapes(worktreeRoot: string): Promise<void> {
	const trackedChanges = (
		await runFixtureGit(worktreeRoot, ['diff', '--name-status', '--find-renames=50%', 'HEAD', '--'])
	)
		.trim()
		.split('\n')
		.filter((line): boolean => line.length > 0)
		.toSorted();
	const expectedTrackedChanges = [
		`D\t${deletedPath}`,
		`M\t${binaryPath}`,
		`M\t${largePath}`,
		`M\t${modifiedSourcePath}`,
		`M\t${modifiedTestPath}`,
		`R100\t${renameSourcePath}\t${renamedPath}`,
	].toSorted();
	if (JSON.stringify(trackedChanges) !== JSON.stringify(expectedTrackedChanges)) {
		throw new Error(
			`Git status fixture produced unexpected tracked shapes: ${JSON.stringify(trackedChanges)}.`,
		);
	}
	const untrackedPaths = (
		await runFixtureGit(worktreeRoot, ['ls-files', '--others', '--exclude-standard'])
	)
		.trim()
		.split('\n')
		.filter((path): boolean => path.length > 0)
		.toSorted();
	if (
		JSON.stringify(untrackedPaths) !== JSON.stringify([...fixtureMutationPaths.added].toSorted())
	) {
		throw new Error(
			`Git status fixture produced unexpected untracked paths: ${JSON.stringify(untrackedPaths)}.`,
		);
	}
}

function statusCase(
	label: BridgeViewerGitStatusCase['label'],
	filePaths: readonly string[],
): BridgeViewerGitStatusCase {
	return { expectedTreePaths: reviewTreePathsForFiles(filePaths), label };
}

function reviewTreePathsForFiles(filePaths: readonly string[]): readonly string[] {
	const treePaths = new Set<string>();
	for (const filePath of filePaths) {
		const pathComponents = filePath.split('/');
		for (let componentCount = 1; componentCount <= pathComponents.length; componentCount += 1) {
			const path = pathComponents.slice(0, componentCount).join('/');
			treePaths.add(componentCount === pathComponents.length ? path : `${path}/`);
		}
	}
	return [...treePaths].toSorted();
}

async function runFixtureGit(cwd: string, arguments_: readonly string[]): Promise<string> {
	const { stdout } = await execFileAsync('git', [...arguments_], {
		cwd,
		encoding: 'utf8',
		maxBuffer: 16 * 1024 * 1024,
	});
	return stdout;
}
