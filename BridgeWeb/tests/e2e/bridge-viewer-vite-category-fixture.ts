import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import type { BridgeViewerViteProductFixtureOracle } from './bridge-viewer-vite-product-fixture.ts';

const execFileAsync = promisify(execFile);

export interface BridgeViewerCategoryFixture {
	readonly categoryCases: readonly BridgeViewerCategoryCase[];
	readonly dispose: () => Promise<void>;
	readonly expectedAllTreePaths: readonly string[];
	readonly expectedReviewDefaultTreePaths: readonly string[];
	readonly oracle: BridgeViewerViteProductFixtureOracle;
}

export interface BridgeViewerCategoryCase {
	readonly expectedFileTreePaths: readonly string[];
	readonly expectedReviewTreePaths: readonly string[];
	readonly label: string;
}

interface CategoryFixtureFile {
	readonly baseBody: string;
	readonly headBody: string;
	readonly path: string;
}

const fixtureFiles: readonly CategoryFixtureFile[] = [
	{
		baseBody: "export const sourceRevision = 'base';\n",
		headBody: "export const sourceRevision = 'head';\n",
		path: 'category-corpus/source/component.ts',
	},
	{
		baseBody: "export const testRevision = 'base';\n",
		headBody: "export const testRevision = 'head';\n",
		path: 'category-corpus/specimens/component.test.tsx',
	},
	{
		baseBody: "export const specRevision = 'base';\n",
		headBody: "export const specRevision = 'head';\n",
		path: 'category-corpus/specimens/component.spec.jsx',
	},
	{
		baseBody: '# Category fixture\n\nBase documentation.\n',
		headBody: '# Category fixture\n\nHead documentation.\n',
		path: 'category-corpus/docs/guide.md',
	},
	{
		baseBody: '{"fixtureRevision":"base"}\n',
		headBody: '{"fixtureRevision":"head"}\n',
		path: 'category-corpus/config/package.json',
	},
	{
		baseBody: "export const generatedRevision = 'base';\n",
		headBody: "export const generatedRevision = 'head';\n",
		path: 'category-corpus/generated/client.ts',
	},
	{
		baseBody: "export const vendorRevision = 'base';\n",
		headBody: "export const vendorRevision = 'head';\n",
		path: 'category-corpus/vendor/pkg/index.js',
	},
	{
		baseBody: 'base fixture data\n',
		headBody: 'head fixture data\n',
		path: 'category-corpus/test-fixtures/sample.txt',
	},
	{
		baseBody: 'base uncategorized data\n',
		headBody: 'head uncategorized data\n',
		path: 'category-corpus/other/NOTICE',
	},
];

export async function createBridgeViewerCategoryFixture(): Promise<BridgeViewerCategoryFixture> {
	const worktreeRoot = await mkdtemp(join(tmpdir(), 'bridge-viewer-category-e2e-'));
	let testLaunch: BridgeWebTestLaunch | null = null;
	let dataRootPath: string | null = null;
	try {
		testLaunch = await BridgeWebTestLaunch.start({
			dataRootPrefix: 'bridge-viewer-category-data-',
		});
		dataRootPath = testLaunch.dataRootPath;
		await writeFixturePhase(worktreeRoot, 'baseBody');
		await runFixtureGit(worktreeRoot, ['init', '--initial-branch=main']);
		await runFixtureGit(worktreeRoot, ['config', 'user.name', 'Bridge Category E2E']);
		await runFixtureGit(worktreeRoot, [
			'config',
			'user.email',
			'bridge-category-e2e@example.invalid',
		]);
		await runFixtureGit(worktreeRoot, ['add', '--all']);
		await runFixtureGit(worktreeRoot, [
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'category fixture base',
		]);
		const baseRef = (await runFixtureGit(worktreeRoot, ['rev-parse', 'HEAD'])).trim();
		await writeFixturePhase(worktreeRoot, 'headBody');

		const changedPaths = fixtureFiles.map(({ path }): string => path).toSorted();
		const categoryCases: readonly BridgeViewerCategoryCase[] = [
			categoryCase('Source code', ['category-corpus/source/component.ts']),
			categoryCase('Tests', [
				'category-corpus/specimens/component.spec.jsx',
				'category-corpus/specimens/component.test.tsx',
			]),
			categoryCase('Documentation', ['category-corpus/docs/guide.md']),
			categoryCase('Configuration', ['category-corpus/config/package.json']),
			categoryCase('Test data', ['category-corpus/test-fixtures/sample.txt']),
		];
		const expectedAllTreePaths = corpusTreePathsForFiles(changedPaths);
		const expectedReviewDefaultTreePaths = reviewTreePathsForFiles(changedPaths);
		return {
			categoryCases,
			dispose: async (): Promise<void> => {
				await testLaunch?.dispose();
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'category fixture worktree',
							run: async (): Promise<void> => {
								await rm(worktreeRoot, { force: true, recursive: true });
							},
						},
						{
							name: 'category fixture data root',
							run: async (): Promise<void> => {
								await testLaunch?.dispose();
							},
						},
					],
				});
			},
			expectedAllTreePaths,
			expectedReviewDefaultTreePaths,
			oracle: {
				testLaunch,
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
				fileTreeDeepPath: 'category-corpus/vendor/pkg/index.js',
				largeFileLineCount: 0,
				largeFilePath: '',
				largeFileSha256: '',
				paneId: randomUUID(),
				reviewFiles: [],
				worktreeRoot,
			},
		};
	} catch (error: unknown) {
		await runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'category fixture worktree',
					run: async (): Promise<void> => {
						await rm(worktreeRoot, { force: true, recursive: true });
					},
				},
				{
					name: 'category fixture data root',
					run: async (): Promise<void> => {
						await testLaunch?.dispose();
					},
				},
			],
			primaryError: error,
		});
		throw error;
	}
}

function categoryCase(label: string, filePaths: readonly string[]): BridgeViewerCategoryCase {
	return {
		expectedFileTreePaths: [
			...new Set(
				filePaths.flatMap((filePath): readonly string[] => [`${dirname(filePath)}/`, filePath]),
			),
		].toSorted(),
		expectedReviewTreePaths: reviewTreePathsForFiles(filePaths),
		label,
	};
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

function corpusTreePathsForFiles(filePaths: readonly string[]): readonly string[] {
	return [
		'category-corpus/',
		...new Set(
			filePaths.flatMap((filePath): readonly string[] => [`${dirname(filePath)}/`, filePath]),
		),
	].toSorted();
}

async function writeFixturePhase(
	worktreeRoot: string,
	bodyKey: 'baseBody' | 'headBody',
): Promise<void> {
	for (const fixtureFile of fixtureFiles) {
		const absolutePath = join(worktreeRoot, fixtureFile.path);
		// oxlint-disable-next-line no-await-in-loop -- Each deterministic file must exist before Git observes the phase.
		await mkdir(dirname(absolutePath), { recursive: true });
		// oxlint-disable-next-line no-await-in-loop -- Stable fixture ordering makes failures reproducible.
		await writeFile(absolutePath, fixtureFile[bodyKey]);
	}
}

async function runFixtureGit(cwd: string, arguments_: readonly string[]): Promise<string> {
	const { stdout } = await execFileAsync('git', [...arguments_], {
		cwd,
		encoding: 'utf8',
		maxBuffer: 16 * 1024 * 1024,
	});
	return stdout;
}
