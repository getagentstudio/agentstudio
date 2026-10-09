import { execFile, spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer as createHTTPServer } from 'node:http';
import { createServer as createTCPServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

import {
	runAllOwnedCleanupOperations,
	startOwnedBridgeDevelopmentServer,
} from '../../scripts/dev-server/bridge-development-server-process.ts';
import { bridgeReviewItemIdOracle } from '../../scripts/verify-bridge-viewer-worktree-dev-server/bridge-review-item-id-oracle.ts';
import type { BridgeViewerFileProofTargets } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-page.ts';

const execFileAsync = promisify(execFile);
const bridgeWebRootPath = new URL('../../', import.meta.url).pathname;
const repoRootPath = new URL('../../..', import.meta.url).pathname;
const viteCLIPath = join(bridgeWebRootPath, 'node_modules/vite/bin/vite.js');
const serverStartupTimeoutMilliseconds = 30_000;
const serverShutdownTimeoutMilliseconds = 10_000;
const maximumServerLogTailCharacters = 8_192;
const markdownProofPath = 'fixture-proof.md';
const markdownProofRenderedText = 'BRIDGE_VITE_PRODUCT_MARKDOWN_PAINT_PROOF';
const markdownProofContent = `# ${markdownProofRenderedText}\n`;
const codeProofPath = 'fixture-proof.swift';
const codeProofContent = `public enum BridgeViteProductCodeProof {
    public static let marker = "BRIDGE_VITE_PRODUCT_CODE_PAINT_MARKER"
}
`;

export interface BridgeViewerViteProductFixtureOracle {
	readonly baseRef: string;
	readonly changedPaths: readonly string[];
	readonly comparisonTargetName: string;
	readonly dataRootPath: string;
	readonly expectedReviewItemIds: readonly string[];
	readonly fileContent: BridgeViewerViteProductContentOracle;
	readonly fileTreeDeepPath: string;
	readonly largeFileLineCount: number;
	readonly largeFilePath: string;
	readonly largeFileSha256: string;
	readonly paneId: string;
	readonly reviewFiles: readonly BridgeViewerViteProductReviewFileOracle[];
	readonly worktreeRoot: string;
}

export interface BridgeViewerViteProductProofFixtureOracle extends BridgeViewerViteProductFixtureOracle {
	readonly fileProofCodeContent: string;
	readonly fileProofTargets: BridgeViewerFileProofTargets;
}

export interface BridgeViewerViteProductContentOracle {
	readonly byteLength: number;
	readonly firstMarker: string;
	readonly finalMarker: string;
	readonly lineCount: number;
	readonly middleMarker: string;
	readonly sha256: string;
}

export interface BridgeViewerViteProductReviewFileOracle {
	readonly base: BridgeViewerViteProductReviewRoleOracle;
	readonly head: BridgeViewerViteProductReviewRoleOracle;
	readonly itemId: string;
	readonly path: string;
}

export interface BridgeViewerViteProductReviewRoleOracle {
	readonly body: string;
	readonly byteLength: number;
	readonly role: 'base' | 'head';
	readonly sha256: string;
}

export interface BridgeViewerOwnedViteProductServer {
	readonly backendPid: number;
	readonly diagnostics: () => string;
	readonly origin: string;
	readonly pid: number;
	readonly stop: () => Promise<BridgeViewerOwnedViteProductServerCleanup>;
	readonly version: string | null;
}

export interface BridgeViewerOwnedViteProductServerCleanup {
	readonly exitCode: number | null;
	readonly exitObserved: boolean;
	readonly exitSignal: NodeJS.Signals | null;
	readonly forcedTerminationRequired: boolean;
	readonly ownedProcessAliveAfterStop: boolean;
}

export interface BridgeViewerReviewedHeadAdvance {
	readonly finalHeadOID: string;
	readonly importedCommitCount: number;
	readonly previousHeadOID: string;
}

export interface BridgeViewerReviewWorktreeMutation {
	readonly path: string;
}

export interface BridgeViewerOwnedViteProcessExit {
	readonly code: number | null;
	readonly signal: NodeJS.Signals | null;
}

export interface BridgeViewerOwnedViteProcessControl {
	readonly pid?: number | undefined;
	readonly kill: (signal: NodeJS.Signals) => boolean;
}

export interface BridgeViewerOwnedViteShutdownDependencies {
	readonly processIsAlive: (pid: number) => boolean;
	readonly waitForExitWithinDeadline: (
		exitPromise: Promise<BridgeViewerOwnedViteProcessExit>,
	) => Promise<BridgeViewerOwnedViteProcessExit | null>;
}

export async function createBridgeViewerViteProductFixture(
	options: { readonly reviewChangedFileCount?: number } = {},
): Promise<{
	readonly advanceComparisonTarget: () => Promise<string>;
	readonly advanceReviewedHeadByCommitCount: (
		commitCount: number,
	) => Promise<BridgeViewerReviewedHeadAdvance>;
	readonly dispose: () => Promise<void>;
	readonly mutateLargeFile: () => Promise<BridgeViewerViteProductContentOracle>;
	readonly mutateReviewFile: () => Promise<BridgeViewerReviewWorktreeMutation>;
	readonly oracle: BridgeViewerViteProductProofFixtureOracle;
}> {
	const worktreeRoot = await mkdtemp(join(tmpdir(), 'bridge-viewer-vite-product-e2e-'));
	let dataRootPath: string | null = null;
	const comparisonTargetName = 'bridge-vite-comparison-target';
	const paneId = randomUUID();
	let reviewedHeadAdvanceSequence = 0;
	let reviewWorktreeMutationSequence = 0;
	const largeFilePath = 'zz-large-complete-file.txt';
	const reviewChangedFileCount = options.reviewChangedFileCount ?? 16;
	if (!Number.isSafeInteger(reviewChangedFileCount) || reviewChangedFileCount <= 0) {
		throw new Error('Vite product fixture Review file count must be a positive safe integer.');
	}
	const routineCompleteFileLineCount = 128;
	const routineCompleteFileMiddleLineIndex = 63;
	const routineCompleteFileFinalLineIndex = 127;
	const firstMarker = 'BRIDGE_VITE_PRODUCT_FIRST_BYTE_MARKER';
	const middleMarker = 'BRIDGE_VITE_PRODUCT_MIDDLE_BYTE_MARKER';
	const finalMarker = 'BRIDGE_VITE_PRODUCT_FINAL_BYTE_MARKER';
	const largeFileLines = Array.from(
		{ length: routineCompleteFileLineCount },
		(_, lineIndex): string =>
			lineIndex === 0
				? firstMarker
				: lineIndex === routineCompleteFileMiddleLineIndex
					? middleMarker
					: lineIndex === routineCompleteFileFinalLineIndex
						? finalMarker
						: `bridge-vite-product-line-${String(lineIndex + 1).padStart(4, '0')}`,
	);
	const largeFileContent = `${largeFileLines.join('\n')}\n`;
	const nestedPaths = Array.from(
		{ length: reviewChangedFileCount },
		(_, fileIndex): string =>
			`nested/group-${String(Math.floor(fileIndex / 6) + 1).padStart(2, '0')}/file-${String(fileIndex + 1).padStart(2, '0')}.ts`,
	);
	const fileTreeOnlyPaths = Array.from(
		{ length: 24 },
		(_, fileIndex): string =>
			`tree-only/section-${String(Math.floor(fileIndex / 8) + 1).padStart(2, '0')}/entry-${String(fileIndex + 1).padStart(3, '0')}.txt`,
	);
	try {
		dataRootPath = await mkdtemp(join(tmpdir(), 'bridge-viewer-vite-product-data-'));
		await writeFixtureFiles({
			fileTreeOnlyPaths,
			largeFileContent,
			largeFilePath,
			nestedPaths,
			phase: 'base',
			worktreeRoot,
		});
		await runFixtureGit(worktreeRoot, ['init', '--initial-branch=main']);
		await runFixtureGit(worktreeRoot, ['config', 'user.name', 'Bridge Vite Product E2E']);
		await runFixtureGit(worktreeRoot, ['config', 'user.email', 'bridge-vite-e2e@example.invalid']);
		await runFixtureGit(worktreeRoot, ['add', '--all']);
		await runFixtureGit(worktreeRoot, [
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-m',
			'fixture base',
		]);
		await writeFixtureFiles({
			fileTreeOnlyPaths,
			largeFileContent,
			largeFilePath,
			nestedPaths,
			phase: 'head',
			worktreeRoot,
		});
		const baseRef = (await runFixtureGit(worktreeRoot, ['rev-parse', 'HEAD'])).trim();
		await runFixtureGit(worktreeRoot, [
			'update-ref',
			`refs/heads/${comparisonTargetName}`,
			baseRef,
		]);
		const changedPaths = (
			await runFixtureGit(worktreeRoot, ['diff', '--name-only', '--no-renames', baseRef, '--'])
		)
			.split('\n')
			.filter((path): boolean => path.length > 0)
			.toSorted((left, right): number => left.localeCompare(right));
		if (changedPaths.length !== nestedPaths.length) {
			throw new Error(`Disposable live-worktree oracle expected ${nestedPaths.length} changes.`);
		}
		const observedLargeFileContent = await readFile(join(worktreeRoot, largeFilePath), 'utf8');
		if (observedLargeFileContent !== largeFileContent) {
			throw new Error('Disposable live-worktree oracle did not preserve the complete large file.');
		}
		const fixtureFileIndexByPath = new Map(
			nestedPaths.map((path, fileIndex): readonly [string, number] => [path, fileIndex]),
		);
		const reviewFiles = await Promise.all(
			changedPaths.map(async (path): Promise<BridgeViewerViteProductReviewFileOracle> => {
				const fileIndex = fixtureFileIndexByPath.get(path);
				if (fileIndex === undefined) {
					throw new Error(`Disposable live-worktree oracle has no source index for ${path}.`);
				}
				const baseBody = reviewFixtureBody({ fileIndex, phase: 'base' });
				const headBody = await readFile(join(worktreeRoot, path), 'utf8');
				return {
					base: reviewRoleOracle('base', baseBody),
					head: reviewRoleOracle('head', headBody),
					itemId: bridgeReviewItemIdOracle({
						newContentHash: gitBlobHash(headBody),
						oldContentHash: gitBlobHash(baseBody),
						path,
						previousPath: null,
					}),
					path,
				};
			}),
		);
		const fileContent = fileContentOracle({
			content: largeFileContent,
			firstMarker,
			finalMarker,
			middleMarker,
		});
		return {
			advanceComparisonTarget: async (): Promise<string> => {
				const targetCommitOID = (
					await runFixtureGit(worktreeRoot, [
						'commit-tree',
						`${baseRef}^{tree}`,
						'-p',
						baseRef,
						'-m',
						'advance comparison target',
					])
				).trim();
				await runFixtureGit(worktreeRoot, [
					'update-ref',
					`refs/heads/${comparisonTargetName}`,
					targetCommitOID,
					baseRef,
				]);
				return targetCommitOID;
			},
			advanceReviewedHeadByCommitCount: async (
				commitCount,
			): Promise<BridgeViewerReviewedHeadAdvance> => {
				if (!Number.isSafeInteger(commitCount) || commitCount <= 0) {
					throw new Error('Reviewed-head commit count must be a positive safe integer.');
				}
				const changedPath = nestedPaths[0];
				if (changedPath === undefined) throw new Error('Promoted refresh fixture path is missing.');
				const previousHeadOID = (await runFixtureGit(worktreeRoot, ['rev-parse', 'HEAD'])).trim();
				const currentBody = await readFile(join(worktreeRoot, changedPath), 'utf8');
				reviewedHeadAdvanceSequence += 1;
				const privateChainRef = `refs/bridge-viewer-fixture/private-reviewed-head/${randomUUID()}`;
				try {
					const committedBody = `${currentBody}export const promotedHeadChain${reviewedHeadAdvanceSequence} = ${reviewedHeadAdvanceSequence};\n`;
					const committedBodyBlobOID = (
						await runFixtureGit(worktreeRoot, ['hash-object', '-w', '--stdin'], {
							input: committedBody,
						})
					).trim();
					const commitCommands: string[] = ['feature done'];
					for (let commitIndex = 0; commitIndex < commitCount; commitIndex += 1) {
						const commitMark = commitIndex + 1;
						const message = `promoted refresh chain ${reviewedHeadAdvanceSequence} commit ${commitMark}`;
						commitCommands.push(
							`commit ${privateChainRef}`,
							`mark :${commitMark}`,
							'committer Bridge Vite Product E2E <bridge-vite-e2e@example.invalid> 0 +0000',
							`data ${Buffer.byteLength(message)}`,
							message,
							`from ${commitIndex === 0 ? previousHeadOID : `:${commitIndex}`}`,
						);
						if (commitIndex === 0) {
							commitCommands.push(`M 100644 ${committedBodyBlobOID} ${changedPath}`);
						}
						commitCommands.push('');
					}
					commitCommands.push('done', '');
					await runFixtureGit(worktreeRoot, ['fast-import', '--quiet'], {
						input: commitCommands.join('\n'),
					});
					const finalHeadOID = (
						await runFixtureGit(worktreeRoot, ['rev-parse', privateChainRef])
					).trim();
					const importedCommitCount = Number(
						(
							await runFixtureGit(worktreeRoot, [
								'rev-list',
								'--count',
								`${previousHeadOID}..${finalHeadOID}`,
							])
						).trim(),
					);
					if (importedCommitCount !== commitCount) {
						throw new Error(
							`Reviewed-head chain expected ${commitCount} commits, received ${importedCommitCount}.`,
						);
					}
					// This is the only observed reviewed-head transition. Private object construction above
					// never moves the checked-out ref or exposes an intermediate reviewed head.
					await runFixtureGit(worktreeRoot, ['update-ref', 'HEAD', finalHeadOID, previousHeadOID]);
					return { finalHeadOID, importedCommitCount, previousHeadOID };
				} finally {
					await runFixtureGit(worktreeRoot, ['update-ref', '-d', privateChainRef]);
				}
			},
			dispose: async (): Promise<void> => {
				await runAllOwnedCleanupOperations({
					operations: [
						{
							name: 'Vite product fixture worktree',
							run: async (): Promise<void> => {
								await rm(worktreeRoot, { force: true, recursive: true });
							},
						},
						{
							name: 'Vite product fixture data root',
							run: async (): Promise<void> => {
								if (dataRootPath !== null) {
									await rm(dataRootPath, { force: true, recursive: true });
								}
							},
						},
					],
				});
			},
			mutateLargeFile: async (): Promise<BridgeViewerViteProductContentOracle> => {
				const mutatedFirstMarker = 'BRIDGE_VITE_PRODUCT_MUTATED_FIRST_BYTE_MARKER';
				const mutatedMiddleMarker = 'BRIDGE_VITE_PRODUCT_MUTATED_MIDDLE_BYTE_MARKER';
				const mutatedFinalMarker = 'BRIDGE_VITE_PRODUCT_MUTATED_FINAL_BYTE_MARKER';
				const mutatedLines = largeFileLines.map((line, lineIndex): string =>
					lineIndex === 0
						? mutatedFirstMarker
						: lineIndex === routineCompleteFileMiddleLineIndex
							? mutatedMiddleMarker
							: lineIndex === routineCompleteFileFinalLineIndex
								? mutatedFinalMarker
								: line,
				);
				const content = `${mutatedLines.join('\n')}\n`;
				await writeFile(join(worktreeRoot, largeFilePath), content);
				return fileContentOracle({
					content,
					firstMarker: mutatedFirstMarker,
					finalMarker: mutatedFinalMarker,
					middleMarker: mutatedMiddleMarker,
				});
			},
			mutateReviewFile: async (): Promise<BridgeViewerReviewWorktreeMutation> => {
				const changedPath = nestedPaths[0];
				if (changedPath === undefined) {
					throw new Error('Proportional Review fixture path is missing.');
				}
				const currentBody = await readFile(join(worktreeRoot, changedPath), 'utf8');
				reviewWorktreeMutationSequence += 1;
				await writeFile(
					join(worktreeRoot, changedPath),
					`${currentBody}export const proportionalWorktreeMutation${reviewWorktreeMutationSequence} = ${reviewWorktreeMutationSequence};\n`,
				);
				return { path: changedPath };
			},
			oracle: {
				baseRef,
				changedPaths,
				comparisonTargetName,
				dataRootPath,
				expectedReviewItemIds: reviewFiles.map(({ itemId }): string => itemId),
				fileContent,
				fileProofCodeContent: codeProofContent,
				fileProofTargets: {
					codePath: codeProofPath,
					markdownPath: markdownProofPath,
					markdownRenderedText: markdownProofRenderedText,
				},
				fileTreeDeepPath: fileTreeOnlyPaths.at(-1) ?? '',
				largeFileLineCount: largeFileLines.length,
				largeFilePath,
				largeFileSha256: sha256(largeFileContent),
				paneId,
				reviewFiles,
				worktreeRoot,
			},
		};
	} catch (error: unknown) {
		await runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'Vite product fixture worktree',
					run: async (): Promise<void> => {
						await rm(worktreeRoot, { force: true, recursive: true });
					},
				},
				{
					name: 'Vite product fixture data root',
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

export async function startBridgeViewerOwnedViteProductServer(
	oracle: BridgeViewerViteProductFixtureOracle,
): Promise<BridgeViewerOwnedViteProductServer> {
	const port = await reserveLoopbackPort();
	const telemetryReceiver = await startBridgeViewerOwnedTelemetryReceiver();
	const bridgeDevelopmentServer = await startOwnedBridgeDevelopmentServer({
		dataRootPath: oracle.dataRootPath,
		initialTarget: 'HEAD',
		paneId: oracle.paneId,
		repoRootPath,
		worktreeRoot: oracle.worktreeRoot,
	}).catch(async (error: unknown): Promise<never> => {
		await runAllOwnedCleanupOperations({
			operations: [{ name: 'telemetry receiver', run: telemetryReceiver.stop }],
			primaryError: error,
		});
		throw error;
	});
	const child = spawn(
		process.execPath,
		[viteCLIPath, '--host', '127.0.0.1', '--port', String(port), '--strictPort'],
		{
			cwd: bridgeWebRootPath,
			env: {
				...process.env,
				BRIDGE_WEB_DEV_BACKEND_ORIGIN: bridgeDevelopmentServer.origin,
				BRIDGE_WEB_DEV_TELEMETRY_OTLP_LOGS_URL: `${telemetryReceiver.origin}/v1/logs`,
				BRIDGE_WEB_DEV_TELEMETRY_OTLP_METRICS_URL: `${telemetryReceiver.origin}/v1/metrics`,
				BRIDGE_WEB_VITE_CACHE_DIR: join(oracle.dataRootPath, 'vite-cache'),
			},
			stdio: ['pipe', 'pipe', 'pipe'],
		},
	);
	const exitPromise = new Promise<BridgeViewerOwnedViteProcessExit>((resolve): void => {
		child.once('exit', (code, signal): void => resolve({ code, signal }));
	});
	let stdoutTail = '';
	let stderrTail = '';
	child.stdout.setEncoding('utf8');
	child.stderr.setEncoding('utf8');
	child.stdout.on('data', (chunk: string): void => {
		stdoutTail = appendBoundedTail(stdoutTail, chunk);
	});
	child.stderr.on('data', (chunk: string): void => {
		stderrTail = appendBoundedTail(stderrTail, chunk);
	});
	let readinessOutput: string;
	try {
		readinessOutput = await withBoundedTimeout(
			new Promise<string>((resolve, reject): void => {
				const inspectOutput = (): void => {
					const output = stripANSI(`${stdoutTail}\n${stderrTail}`);
					if (output.includes(`http://127.0.0.1:${port}/`)) resolve(output);
				};
				child.stdout.on('data', inspectOutput);
				child.stderr.on('data', inspectOutput);
				void exitPromise.then((exit): void => {
					reject(
						new Error(
							`Owned Vite exited before readiness: ${JSON.stringify({ exit, stderrTail, stdoutTail })}`,
						),
					);
				});
			}),
			serverStartupTimeoutMilliseconds,
			'owned Vite readiness',
		);
	} catch (error: unknown) {
		let startupError = error;
		try {
			await rejectOwnedViteStartupAfterCleanup({
				child,
				exitPromise,
				startupError: error,
			});
		} catch (cleanupAwareStartupError: unknown) {
			startupError = cleanupAwareStartupError;
		}
		await runAllOwnedCleanupOperations({
			operations: [
				{ name: 'telemetry receiver', run: telemetryReceiver.stop },
				{
					name: 'Swift development backend',
					run: async (): Promise<void> => {
						await bridgeDevelopmentServer.stop();
					},
				},
			],
			primaryError: startupError,
		});
		throw startupError;
	}
	const origin = `http://127.0.0.1:${port}`;
	let stopPromise: Promise<BridgeViewerOwnedViteProductServerCleanup> | null = null;
	const stop = async (): Promise<BridgeViewerOwnedViteProductServerCleanup> => {
		stopPromise ??= (async (): Promise<BridgeViewerOwnedViteProductServerCleanup> => {
			const cleanupResults: {
				backend: Awaited<ReturnType<typeof bridgeDevelopmentServer.stop>> | null;
				vite: BridgeViewerOwnedViteProductServerCleanup | null;
			} = { backend: null, vite: null };
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'Vite',
						run: async (): Promise<void> => {
							cleanupResults.vite = await stopOwnedViteServer({ child, exitPromise });
						},
					},
					{
						name: 'Swift development backend',
						run: async (): Promise<void> => {
							cleanupResults.backend = await bridgeDevelopmentServer.stop();
						},
					},
					{ name: 'telemetry receiver', run: telemetryReceiver.stop },
				],
			});
			if (cleanupResults.vite === null || cleanupResults.backend === null) {
				throw new Error('Owned Bridge product server cleanup did not return process facts.');
			}
			return {
				...cleanupResults.vite,
				forcedTerminationRequired:
					cleanupResults.vite.forcedTerminationRequired ||
					cleanupResults.backend.forcedTerminationRequired,
				ownedProcessAliveAfterStop:
					cleanupResults.vite.ownedProcessAliveAfterStop ||
					cleanupResults.backend.ownedProcessAliveAfterStop,
			};
		})();
		return await stopPromise;
	};
	return {
		backendPid: bridgeDevelopmentServer.pid,
		diagnostics: (): string =>
			JSON.stringify({
				backendStderr: bridgeDevelopmentServer.stderrTail(),
				backendStdout: bridgeDevelopmentServer.stdoutTail(),
				viteStderr: stderrTail,
				viteStdout: stdoutTail,
			}),
		origin,
		pid: child.pid ?? 0,
		stop,
		version: /VITE v(?<version>\d+\.\d+\.\d+)/u.exec(readinessOutput)?.groups?.['version'] ?? null,
	};
}

async function writeFixtureFiles(props: {
	readonly fileTreeOnlyPaths: readonly string[];
	readonly largeFileContent: string;
	readonly largeFilePath: string;
	readonly nestedPaths: readonly string[];
	readonly phase: 'base' | 'head';
	readonly worktreeRoot: string;
}): Promise<void> {
	await writeFile(join(props.worktreeRoot, props.largeFilePath), props.largeFileContent);
	await writeFile(join(props.worktreeRoot, markdownProofPath), markdownProofContent);
	await writeFile(join(props.worktreeRoot, codeProofPath), codeProofContent);
	for (const [fileIndex, relativePath] of props.nestedPaths.entries()) {
		const absolutePath = join(props.worktreeRoot, relativePath);
		// oxlint-disable-next-line no-await-in-loop -- Fixture paths must exist before their deterministic writes.
		await mkdir(join(absolutePath, '..'), { recursive: true });
		// oxlint-disable-next-line no-await-in-loop -- Stable fixture order makes source identity reproducible.
		await writeFile(absolutePath, reviewFixtureBody({ fileIndex, phase: props.phase }));
	}
	for (const [fileIndex, relativePath] of props.fileTreeOnlyPaths.entries()) {
		const absolutePath = join(props.worktreeRoot, relativePath);
		// oxlint-disable-next-line no-await-in-loop -- Fixture paths must exist before their deterministic writes.
		await mkdir(join(absolutePath, '..'), { recursive: true });
		// oxlint-disable-next-line no-await-in-loop -- Stable fixture order makes the deep tree reproducible.
		await writeFile(absolutePath, `unchanged-tree-entry-${fileIndex + 1}\n`);
	}
}

function reviewFixtureBody(props: {
	readonly fileIndex: number;
	readonly phase: 'base' | 'head';
}): string {
	const fixtureOrdinal = props.fileIndex + 1;
	return [
		`export const fixtureValue${fixtureOrdinal} = '${props.phase}-${fixtureOrdinal}-bridge-vite-product-source-correlation';`,
		`export const fixtureDescription${fixtureOrdinal} = 'deterministic-provider-worker-pierre-disposition-journey';`,
		'',
	].join('\n');
}

function fileContentOracle(props: {
	readonly content: string;
	readonly firstMarker: string;
	readonly finalMarker: string;
	readonly middleMarker: string;
}): BridgeViewerViteProductContentOracle {
	return {
		byteLength: Buffer.byteLength(props.content),
		firstMarker: props.firstMarker,
		finalMarker: props.finalMarker,
		lineCount: props.content.split('\n').length - 1,
		middleMarker: props.middleMarker,
		sha256: sha256(props.content),
	};
}

function reviewRoleOracle(
	role: 'base' | 'head',
	body: string,
): BridgeViewerViteProductReviewRoleOracle {
	return { body, byteLength: Buffer.byteLength(body), role, sha256: sha256(body) };
}

function gitBlobHash(content: string): string {
	const contentBytes = Buffer.from(content);
	return createHash('sha1')
		.update(`blob ${contentBytes.byteLength}\0`)
		.update(contentBytes)
		.digest('hex');
}

async function runFixtureGit(
	cwd: string,
	arguments_: readonly string[],
	options: {
		readonly environment?: Readonly<Record<string, string>>;
		readonly input?: string;
	} = {},
): Promise<string> {
	if (options.input !== undefined) {
		return await new Promise<string>((resolve, reject): void => {
			const child = execFile(
				'git',
				[...arguments_],
				{
					cwd,
					encoding: 'utf8',
					env: { ...process.env, ...options.environment },
					maxBuffer: 16 * 1024 * 1024,
				},
				(error, stdout): void => {
					if (error !== null) {
						reject(error);
						return;
					}
					resolve(stdout);
				},
			);
			child.stdin?.end(options.input);
		});
	}
	const { stdout } = await execFileAsync('git', [...arguments_], {
		cwd,
		encoding: 'utf8',
		env: { ...process.env, ...options.environment },
		maxBuffer: 16 * 1024 * 1024,
	});
	return stdout;
}

async function stopOwnedViteServer(props: {
	readonly child: BridgeViewerOwnedViteProcessControl;
	readonly exitPromise: Promise<BridgeViewerOwnedViteProcessExit>;
	readonly shutdownDependencies?: BridgeViewerOwnedViteShutdownDependencies;
}): Promise<BridgeViewerOwnedViteProductServerCleanup> {
	const shutdownDependencies = props.shutdownDependencies ?? defaultOwnedViteShutdownDependencies();
	const pid = props.child.pid ?? null;
	props.child.kill('SIGTERM');
	let forcedTerminationRequired = false;
	let exit = await shutdownDependencies.waitForExitWithinDeadline(props.exitPromise);
	if (exit === null) {
		forcedTerminationRequired = true;
		props.child.kill('SIGKILL');
		exit = await shutdownDependencies.waitForExitWithinDeadline(props.exitPromise);
	}
	return {
		exitCode: exit?.code ?? null,
		exitObserved: exit !== null,
		exitSignal: exit?.signal ?? null,
		forcedTerminationRequired,
		ownedProcessAliveAfterStop: pid === null ? false : shutdownDependencies.processIsAlive(pid),
	};
}

export async function rejectOwnedViteStartupAfterCleanup(props: {
	readonly child: BridgeViewerOwnedViteProcessControl;
	readonly exitPromise: Promise<BridgeViewerOwnedViteProcessExit>;
	readonly shutdownDependencies?: BridgeViewerOwnedViteShutdownDependencies;
	readonly startupError: unknown;
}): Promise<never> {
	const cleanup = await stopOwnedViteServer(props);
	if (!cleanup.exitObserved || cleanup.ownedProcessAliveAfterStop) {
		throw new AggregateError(
			[props.startupError],
			`OWNED_VITE_STARTUP_CLEANUP_FAILED:${JSON.stringify(cleanup)}`,
		);
	}
	throw props.startupError;
}

function defaultOwnedViteShutdownDependencies(): BridgeViewerOwnedViteShutdownDependencies {
	return {
		processIsAlive,
		waitForExitWithinDeadline: async (
			exitPromise,
		): Promise<BridgeViewerOwnedViteProcessExit | null> =>
			await withBoundedTimeoutOrNull(exitPromise, serverShutdownTimeoutMilliseconds),
	};
}

async function reserveLoopbackPort(): Promise<number> {
	const server = createTCPServer();
	await new Promise<void>((resolve, reject): void => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', (): void => resolve());
	});
	const address = server.address();
	if (address === null || typeof address === 'string') {
		server.close();
		throw new Error('Failed to reserve a loopback Vite port.');
	}
	await new Promise<void>((resolve, reject): void => {
		server.close((error): void => (error === undefined ? resolve() : reject(error)));
	});
	return address.port;
}

async function startBridgeViewerOwnedTelemetryReceiver(): Promise<{
	readonly origin: string;
	readonly stop: () => Promise<void>;
}> {
	const server = createHTTPServer((request, response): void => {
		request.resume();
		if (
			request.method === 'POST' &&
			(request.url === '/v1/logs' || request.url === '/v1/metrics')
		) {
			response.statusCode = 200;
			response.end();
			return;
		}
		response.statusCode = 404;
		response.end();
	});
	await new Promise<void>((resolve, reject): void => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', (): void => resolve());
	});
	const address = server.address();
	if (address === null || typeof address === 'string') {
		server.close();
		throw new Error('Failed to start the owned Bridge telemetry receiver.');
	}
	return {
		origin: `http://127.0.0.1:${address.port}`,
		stop: async (): Promise<void> => {
			await new Promise<void>((resolve, reject): void => {
				server.close((error): void => (error === undefined ? resolve() : reject(error)));
			});
		},
	};
}

function sha256(value: string | Uint8Array): string {
	return createHash('sha256').update(value).digest('hex');
}

function appendBoundedTail(current: string, next: string): string {
	return `${current}${next}`.slice(-maximumServerLogTailCharacters);
}

function stripANSI(value: string): string {
	return value.replace(new RegExp(`${String.fromCharCode(27)}\\[[0-?]*[ -/]*[@-~]`, 'gu'), '');
}

function processIsAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error: unknown) {
		return !(
			typeof error === 'object' &&
			error !== null &&
			'code' in error &&
			error.code === 'ESRCH'
		);
	}
}

async function withBoundedTimeout<TValue>(
	promise: Promise<TValue>,
	timeoutMilliseconds: number,
	label: string,
): Promise<TValue> {
	const result = await withBoundedTimeoutOrNull(promise, timeoutMilliseconds);
	if (result === null) throw new Error(`Timed out waiting for ${label}.`);
	return result;
}

async function withBoundedTimeoutOrNull<TValue>(
	promise: Promise<TValue>,
	timeoutMilliseconds: number,
): Promise<TValue | null> {
	let timeout: ReturnType<typeof setTimeout> | null = null;
	try {
		return await Promise.race([
			promise,
			new Promise<null>((resolve): void => {
				timeout = setTimeout((): void => resolve(null), timeoutMilliseconds);
			}),
		]);
	} finally {
		if (timeout !== null) clearTimeout(timeout);
	}
}
