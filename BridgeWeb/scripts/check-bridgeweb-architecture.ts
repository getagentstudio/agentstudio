import type { Dirent } from 'node:fs';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, extname, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import ts from 'typescript';

import { reconcileArchitectureLedgers } from './check-bridgeweb-architecture-ledgers.ts';
import * as timedWaits from './check-bridgeweb-architecture-timed-waits.ts';

type RuleId =
	| 'max-file-lines'
	| 'no-private-pierre-imports'
	| 'pierre-codeview-import-boundary'
	| 'pierre-trees-import-boundary'
	| 'pierre-worker-import-boundary'
	| 'markdown-render-worker-boundary'
	| 'review-viewer-folder-boundary'
	| 'review-viewer-state-has-effects'
	| 'review-viewer-shell-has-content-effects'
	| 'telemetry-boundary'
	| 'worker-boundary'
	| 'no-raw-file-bodies-in-state'
	| 'no-typescript-live-product-authority'
	| 'core-imports-app-protocol'
	| 'product-endpoint-boundary'
	| timedWaits.TimedWaitRuleId;

export interface ArchitectureViolation {
	readonly ruleId: RuleId;
	readonly relativePath: string;
	readonly line: number;
	readonly column: number;
	readonly message: string;
}

export interface ArchitectureReport {
	readonly ok: boolean;
	readonly violations: readonly ArchitectureViolation[];
}

export interface CheckBridgeWebArchitectureProps {
	readonly packageRootPath?: string;
	// The package's path from the repository root, used for debt ledger paths.
	readonly repositoryPathPrefix?: string;
}

interface SourceContext {
	readonly relativePath: string;
	readonly sourceFile: ts.SourceFile;
	readonly sourceText: string;
	readonly violations: ArchitectureViolation[];
}

interface ParseSourceFileProps {
	readonly filePath: string;
	readonly packageRootPath: string;
}

interface ParsedSourceFile {
	readonly relativePath: string;
	readonly sourceFile: ts.SourceFile;
	readonly sourceText: string;
}

interface AddViolationProps {
	readonly ruleId: RuleId;
	readonly node?: ts.Node;
	readonly position?: number;
	readonly message: string;
}

const defaultPackageRootPath = fileURLToPath(new URL('../', import.meta.url));
const checkedExtensions = new Set(['.ts', '.tsx']);
const debtLedgerRuleIds: ReadonlySet<string> = new Set<RuleId>([
	'no-timed-wait-in-tests',
	'no-vitest-wait-options',
	'no-vitest-wait-calls',
	'no-playwright-timeout-options',
]);
const ignoredDirectoryNames = new Set(['node_modules', 'dist', 'coverage', '.vite']);
const maxSourceFileLineCount = 1000;
const bridgeProductEndpointAdapterPaths = new Set([
	'src/core/comm-worker/bridge-product-agent-studio-request-executor.js',
	'src/core/comm-worker/bridge-product-agent-studio-request-executor.ts',
	'src/core/comm-worker/bridge-product-http-request-executor.js',
	'src/core/comm-worker/bridge-product-http-request-executor.ts',
]);
const bridgeProductExecutableEntryPaths = new Set([
	'src/core/comm-worker/bridge-comm-worker-packaged-entry.ts',
	'src/core/comm-worker/bridge-comm-worker-vite-entry.ts',
]);
const allowedPostMessagePaths = new Set([
	'src/app/diagnostics/bridge-product-stream-webkit-feasibility-probe.ts',
	'src/app/diagnostics/bridge-product-stream-webkit-feasibility-worker-entry.ts',
	'src/core/comm-worker/bridge-comm-worker-client.ts',
	'src/core/comm-worker/bridge-comm-worker-entry.ts',
	'src/core/comm-worker/bridge-pane-comm-worker-session.ts',
	'src/core/comm-worker/bridge-comm-worker-runtime-protocol.ts',
	'src/core/comm-worker/bridge-comm-worker-task-boundary.ts',
	'src/core/comm-worker/bridge-product-session-contracts.ts',
	'src/file-viewer/bridge-file-viewer-browser-test-comm-worker.ts',
]);
const publicPierreExports = new Set([
	'@pierre/diffs',
	'@pierre/diffs/react',
	'@pierre/diffs/ssr',
	'@pierre/diffs/worker',
	'@pierre/diffs/worker/worker.js',
	'@pierre/diffs/worker/worker-portable.js',
	'@pierre/theming/themes',
	'@pierre/trees',
	'@pierre/trees/react',
	'@pierre/trees/ssr',
	'@pierre/trees/web-components',
]);

export async function checkBridgeWebArchitecture(
	props: CheckBridgeWebArchitectureProps = {},
): Promise<ArchitectureReport> {
	const packageRootPath = props.packageRootPath ?? defaultPackageRootPath;
	const sourceFilePaths = await collectSourceFiles(packageRootPath);
	const parsedSourceFiles = await Promise.all(
		sourceFilePaths.map(
			(filePath: string): Promise<ParsedSourceFile> =>
				parseSourceFile({ filePath, packageRootPath }),
		),
	);
	const repositoryPathPrefix = props.repositoryPathPrefix ?? 'BridgeWeb/';
	// One import-closure analysis covers all wait rules; product deadlines stay excluded.
	const timedWaitSites = timedWaits.findAllTimedWaitsInTestImportClosure({
		packageRootPath,
		sourceFiles: parsedSourceFiles,
	});
	const standardSites = [
		...parsedSourceFiles.flatMap(checkSourceFile),
		...timedWaitSites.filter((site): boolean => site.ruleId === 'no-timed-wait-in-tests'),
	];
	const waitBudgetSites = timedWaitSites.filter(
		(site): boolean => site.ruleId !== 'no-timed-wait-in-tests',
	);
	const violations = (
		await reconcileArchitectureLedgers({
			packageRootPath,
			parsedSourceFiles,
			repositoryPathPrefix,
			standardSites,
			waitBudgetSites,
			isLedgerRuleId,
		})
	).toSorted(compareViolations);

	return {
		ok: violations.length === 0,
		violations,
	};
}

async function collectSourceFiles(directoryPath: string): Promise<readonly string[]> {
	let entries: readonly Dirent[];

	try {
		entries = await readdir(directoryPath, { withFileTypes: true });
	} catch (error: unknown) {
		if (isNodeErrorWithCode(error, 'ENOENT')) {
			return [];
		}

		throw error;
	}

	const entryGroups = await Promise.all(
		entries.map(async (entry: Dirent): Promise<readonly string[]> => {
			const entryPath = join(directoryPath, entry.name);

			if (entry.isDirectory()) {
				if (ignoredDirectoryNames.has(entry.name)) {
					return [];
				}
				return collectSourceFiles(entryPath);
			}

			if (entry.isFile() && checkedExtensions.has(extname(entry.name))) {
				return [entryPath];
			}

			return [];
		}),
	);

	return entryGroups.flat();
}

async function parseSourceFile(props: ParseSourceFileProps): Promise<ParsedSourceFile> {
	const sourceText = await readFile(props.filePath, 'utf8');
	return {
		relativePath: normalizePath(relative(props.packageRootPath, props.filePath)),
		sourceFile: ts.createSourceFile(
			props.filePath,
			sourceText,
			ts.ScriptTarget.Latest,
			true,
			scriptKindForPath(props.filePath),
		),
		sourceText,
	};
}

function checkSourceFile(parsedSourceFile: ParsedSourceFile): readonly ArchitectureViolation[] {
	const { sourceFile } = parsedSourceFile;
	const context: SourceContext = {
		...parsedSourceFile,
		violations: [],
	};

	checkMaxSourceFileLineCount(context);
	checkReviewViewerFolderBoundary(context);
	walkSourceFile(sourceFile, (node: ts.Node): void => {
		checkImportSource(context, node);
		checkBridgeProductEndpointBoundary(context, node);
		checkWorkerUsage(context, node);
		checkStateEffects(context, node);
		checkTelemetryEmit(context, node);
	});
	checkRawBodyStateFields(context);
	checkTypeScriptLiveProductAuthority(context);

	return context.violations;
}

function checkMaxSourceFileLineCount(context: SourceContext): void {
	const lineCount = sourceLineCount(context.sourceText);
	if (lineCount <= maxSourceFileLineCount) {
		return;
	}

	addViolation(context, {
		ruleId: 'max-file-lines',
		message: `BridgeWeb TypeScript source files must be ${maxSourceFileLineCount} lines or fewer; split this file by controller, store, hook, runtime, test-support, or visual shell responsibility. Found ${lineCount} lines.`,
	});
}

function sourceLineCount(sourceText: string): number {
	if (sourceText.length === 0) {
		return 0;
	}

	const normalizedSourceText = sourceText.replace(/\r\n?/gu, '\n');
	const trimmedTrailingNewlineSourceText = normalizedSourceText.endsWith('\n')
		? normalizedSourceText.slice(0, -1)
		: normalizedSourceText;
	return trimmedTrailingNewlineSourceText.split('\n').length;
}

function walkSourceFile(node: ts.Node, visitNode: (node: ts.Node) => void): void {
	visitNode(node);
	node.forEachChild((childNode: ts.Node): void => walkSourceFile(childNode, visitNode));
}

function checkPierreImportSource(
	context: SourceContext,
	node: ts.Node,
	rawImportSource: string,
	importSource: string,
): void {
	if (isArchitectureCheckerPath(context.relativePath)) {
		return;
	}

	if (importSource.startsWith('@pierre/') && !publicPierreExports.has(importSource)) {
		addViolation(context, {
			ruleId: 'no-private-pierre-imports',
			node,
			message: `Pierre import must use a public package export: ${rawImportSource}`,
		});
		return;
	}

	if (isPrivatePierrePath(rawImportSource)) {
		addViolation(context, {
			ruleId: 'no-private-pierre-imports',
			node,
			message: `Pierre import must not reference private package paths: ${rawImportSource}`,
		});
	}
}

function checkImportSource(context: SourceContext, node: ts.Node): void {
	const rawImportSource = readImportSource(node);

	if (rawImportSource === null) {
		return;
	}

	const importSource = normalizeImportSpecifier(rawImportSource);
	checkPierreImportSource(context, node, rawImportSource, importSource);
	const importTargetPath =
		resolveImportTargetPath(context.relativePath, importSource) ?? importSource;
	if (
		!isTestPath(context.relativePath) &&
		context.relativePath !== 'vite.config.ts' &&
		!bridgeProductExecutableEntryPaths.has(context.relativePath) &&
		bridgeProductEndpointAdapterPaths.has(importTargetPath)
	) {
		addViolation(context, {
			ruleId: 'product-endpoint-boundary',
			node,
			message:
				'shared Bridge product runtime modules must receive the request executor at construction instead of importing an endpoint adapter',
		});
	}

	if (isTestPath(context.relativePath)) {
		return;
	}

	if (isCorePath(context.relativePath) && isAppProtocolOrViewerImport(context, importSource)) {
		addViolation(context, {
			ruleId: 'core-imports-app-protocol',
			node,
			message: `generic core modules must not import app protocol or viewer modules: ${importSource}`,
		});
	}

	if (importSource.startsWith('@pierre/trees') && !isAllowedTreesImportPath(context.relativePath)) {
		addViolation(context, {
			ruleId: 'pierre-trees-import-boundary',
			node,
			message: `Pierre Trees runtime imports belong under owning viewer tree panes: ${importSource}`,
		});
	}

	if (isCodeViewImport(importSource) && !isAllowedCodeViewImportPath(context.relativePath)) {
		addViolation(context, {
			ruleId: 'pierre-codeview-import-boundary',
			node,
			message: `Pierre CodeView runtime imports belong under owning viewer code panes: ${importSource}`,
		});
	}

	if (
		isPierreWorkerImport(importSource) &&
		!isAllowedPierreWorkerImportPath(context.relativePath)
	) {
		addViolation(context, {
			ruleId: 'pierre-worker-import-boundary',
			node,
			message: `Pierre worker imports belong under review-viewer/workers/pierre: ${importSource}`,
		});
	}

	if (isStatePath(context.relativePath) && isStateEffectImport(importSource)) {
		addViolation(context, {
			ruleId: 'review-viewer-state-has-effects',
			node,
			message: `review-viewer/state must not import effectful boundary: ${importSource}`,
		});
	}

	if (
		isMarkdownRenderImport(importSource) &&
		!isAllowedMarkdownRenderImportPath(context.relativePath)
	) {
		addViolation(context, {
			ruleId: 'markdown-render-worker-boundary',
			node,
			message: `Markdown and Shiki rendering imports belong in the markdown worker renderer only: ${importSource}`,
		});
	}

	if (isShellPath(context.relativePath) && isContentEffectImport(importSource)) {
		addViolation(context, {
			ruleId: 'review-viewer-shell-has-content-effects',
			node,
			message: `review-viewer/shell must not import content loading boundary: ${importSource}`,
		});
	}
}

function checkBridgeProductEndpointBoundary(context: SourceContext, node: ts.Node): void {
	if (!isSharedBridgeProductRuntimePath(context.relativePath)) return;
	if (
		isSharedBridgeProductRequestRuntimePath(context.relativePath) &&
		ts.isCallExpression(node) &&
		isBridgeProductRequestExecutorCall(node) &&
		!isExactBridgeProductRequestExecutorCall(node)
	) {
		addViolation(context, {
			ruleId: 'product-endpoint-boundary',
			node,
			message:
				'Bridge product request executor calls must use a closed route and capability-bound JSON POST request',
		});
		return;
	}

	if (
		isSharedBridgeProductRequestRuntimePath(context.relativePath) &&
		ts.isCallExpression(node) &&
		isDirectFetchCall(node, context.sourceFile)
	) {
		addViolation(context, {
			ruleId: 'product-endpoint-boundary',
			node,
			message:
				'shared Bridge product runtime modules must execute requests through the injected request executor',
		});
		return;
	}

	if (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) {
		if (
			(ts.isPropertyAccessExpression(node.parent) || ts.isElementAccessExpression(node.parent)) &&
			node.parent.expression === node
		) {
			return;
		}
		const expressionText = constantStringMemberAccessText(node, context.sourceFile);
		if (expressionText === null) return;
		if (
			/^import\.meta\.env(?:\.|$)/u.test(expressionText) ||
			/^process\.env(?:\.|$)/u.test(expressionText) ||
			/^(?:globalThis|self|window)\.location(?:\.|$)/u.test(expressionText) ||
			/^location\.(?:host|hostname|origin|protocol)$/u.test(expressionText)
		) {
			addViolation(context, {
				ruleId: 'product-endpoint-boundary',
				node,
				message:
					'shared Bridge product runtime modules must not detect the product transport environment',
			});
			return;
		}
	}

	if (
		isStringLiteralLike(node) &&
		(node.text.startsWith('agentstudio://rpc/') || node.text.startsWith('/__bridge-product/'))
	) {
		addViolation(context, {
			ruleId: 'product-endpoint-boundary',
			node,
			message:
				'shared Bridge product runtime modules must not own packaged or Vite product endpoint strings',
		});
	}
}

function isDirectFetchCall(callExpression: ts.CallExpression, sourceFile: ts.SourceFile): boolean {
	const calleeText = constantStringMemberAccessText(callExpression.expression, sourceFile);
	return calleeText === 'fetch' || /^(?:globalThis|self|window)\.fetch$/u.test(calleeText ?? '');
}

function constantStringMemberAccessText(
	expression: ts.Expression,
	sourceFile: ts.SourceFile,
): string | null {
	if (ts.isIdentifier(expression)) return expression.text;
	if (ts.isMetaProperty(expression)) return expression.getText(sourceFile);

	if (ts.isPropertyAccessExpression(expression)) {
		const receiverText = constantStringMemberAccessText(expression.expression, sourceFile);
		return receiverText === null ? null : `${receiverText}.${expression.name.text}`;
	}

	if (
		ts.isElementAccessExpression(expression) &&
		isStringLiteralLike(expression.argumentExpression)
	) {
		const receiverText = constantStringMemberAccessText(expression.expression, sourceFile);
		return receiverText === null ? null : `${receiverText}.${expression.argumentExpression.text}`;
	}

	return null;
}

function isBridgeProductRequestExecutorCall(callExpression: ts.CallExpression): boolean {
	const callee = callExpression.expression;
	if (!ts.isPropertyAccessExpression(callee)) return false;
	return callee.name.text.replace(/^#/u, '') === 'executeProductRequest';
}

function isExactBridgeProductRequestExecutorCall(callExpression: ts.CallExpression): boolean {
	if (callExpression.arguments.length !== 2) return false;
	const route = callExpression.arguments[0];
	const requestInit = callExpression.arguments[1];
	if (
		route === undefined ||
		requestInit === undefined ||
		!isStringLiteralLike(route) ||
		!new Set(['command', 'content', 'stream']).has(route.text) ||
		!ts.isObjectLiteralExpression(requestInit)
	) {
		return false;
	}
	const method = objectLiteralProperty(requestInit, 'method');
	const hasBody = objectLiteralHasProperty(requestInit, 'body');
	const headers = objectLiteralProperty(requestInit, 'headers');
	if (
		method === null ||
		!isStringLiteralLike(method.initializer) ||
		method.initializer.text !== 'POST' ||
		!hasBody ||
		headers === null ||
		!ts.isObjectLiteralExpression(headers.initializer)
	) {
		return false;
	}
	const contentType = objectLiteralProperty(headers.initializer, 'Content-Type');
	const capability = objectLiteralProperty(
		headers.initializer,
		'X-AgentStudio-Bridge-Product-Capability',
	);
	return (
		contentType !== null &&
		isStringLiteralLike(contentType.initializer) &&
		contentType.initializer.text === 'application/json' &&
		capability !== null
	);
}

function objectLiteralHasProperty(
	objectLiteral: ts.ObjectLiteralExpression,
	propertyName: string,
): boolean {
	return objectLiteral.properties.some(
		(property): boolean =>
			(ts.isPropertyAssignment(property) || ts.isShorthandPropertyAssignment(property)) &&
			(ts.isIdentifier(property.name) || isStringLiteralLike(property.name)) &&
			property.name.text === propertyName,
	);
}

function objectLiteralProperty(
	objectLiteral: ts.ObjectLiteralExpression,
	propertyName: string,
): ts.PropertyAssignment | null {
	for (const property of objectLiteral.properties) {
		if (!ts.isPropertyAssignment(property)) continue;
		if (
			(ts.isIdentifier(property.name) || isStringLiteralLike(property.name)) &&
			property.name.text === propertyName
		) {
			return property;
		}
	}
	return null;
}

function checkWorkerUsage(context: SourceContext, node: ts.Node): void {
	if (isTestPath(context.relativePath)) {
		return;
	}

	if (
		!isAllowedWorkerConstructionPath(context.relativePath) &&
		ts.isNewExpression(node) &&
		ts.isIdentifier(node.expression) &&
		node.expression.text === 'Worker'
	) {
		addViolation(context, {
			ruleId: 'worker-boundary',
			node,
			message:
				'Worker construction belongs under app/markdown/worker, review-viewer/workers/projection, workers/pierre, or workers/shared-rpc',
		});
	}

	if (
		!isAllowedPostMessagePath(context.relativePath) &&
		ts.isCallExpression(node) &&
		ts.isPropertyAccessExpression(node.expression) &&
		node.expression.name.text === 'postMessage'
	) {
		addViolation(context, {
			ruleId: 'worker-boundary',
			node,
			message:
				'postMessage usage belongs to an owned worker lane, exact comm-worker gateway, or exact packaged diagnostic boundary',
		});
	}
}

function checkReviewViewerFolderBoundary(context: SourceContext): void {
	if (isTestPath(context.relativePath)) {
		return;
	}

	if (isPathInside(context.relativePath, 'src/review-viewer/runtime/')) {
		addViolation(context, {
			ruleId: 'review-viewer-folder-boundary',
			message:
				'review-viewer/runtime is too vague; move files to a feature-owned folder such as content or projections',
		});
		return;
	}

	if (isPathInside(context.relativePath, 'src/review-viewer/workers/rpc/')) {
		addViolation(context, {
			ruleId: 'review-viewer-folder-boundary',
			message:
				'review-viewer/workers/rpc is too vague; use workers/projection for projection workers or workers/shared-rpc for generic transport helpers',
		});
	}
}

function checkStateEffects(context: SourceContext, node: ts.Node): void {
	if (!isStatePath(context.relativePath)) {
		return;
	}

	if (
		ts.isCallExpression(node) &&
		ts.isIdentifier(node.expression) &&
		node.expression.text === 'fetch'
	) {
		addViolation(context, {
			ruleId: 'review-viewer-state-has-effects',
			node,
			message: 'state modules must not fetch content directly',
		});
	}

	if (!isStringLiteralLike(node)) {
		return;
	}

	if (
		node.text === 'system.bridgeTelemetry' ||
		node.text.startsWith('agentstudio://resource/') ||
		node.text.startsWith('agentstudio://app/')
	) {
		addViolation(context, {
			ruleId: 'review-viewer-state-has-effects',
			node,
			message: `state modules must not own Bridge transport strings: ${node.text}`,
		});
	}
}

function checkTelemetryEmit(context: SourceContext, node: ts.Node): void {
	if (
		!context.relativePath.startsWith('src/review-viewer/') ||
		isPathInside(context.relativePath, 'src/foundation/telemetry/') ||
		isTestPath(context.relativePath)
	) {
		return;
	}

	if (
		ts.isCallExpression(node) &&
		ts.isPropertyAccessExpression(node.expression) &&
		(node.expression.name.text === 'record' || node.expression.name.text === 'flush') &&
		node.expression.expression.getText(context.sourceFile).includes('telemetry')
	) {
		addViolation(context, {
			ruleId: 'telemetry-boundary',
			node,
			message: 'review-viewer code must route telemetry through foundation/telemetry adapters',
		});
	}
}

function checkRawBodyStateFields(context: SourceContext): void {
	if (!isStatePath(context.relativePath)) {
		return;
	}

	const match =
		/\b(?:loadedFileBody|rawFileBody|fileBody|bodyText|fileText|sourceText|contentText|selectedContentText|contentPromise|bodyPromise|abortController|workerHandle|pierreInstance)\b/u.exec(
			context.sourceText,
		);

	if (match === null) {
		return;
	}

	addViolation(context, {
		ruleId: 'no-raw-file-bodies-in-state',
		position: match.index,
		message:
			'state modules must store refs/status/facts, not raw bodies, promises, controllers, workers, or Pierre instances',
	});
}

function checkTypeScriptLiveProductAuthority(context: SourceContext): void {
	if (
		!isPathInside(context.relativePath, 'scripts/dev-server/') ||
		isTestPath(context.relativePath) ||
		context.relativePath === 'scripts/dev-server/bridge-dev-telemetry.ts' ||
		context.relativePath === 'scripts/dev-server/bridge-development-server-process.ts'
	) {
		return;
	}

	const forbiddenPattern =
		/\b(?:loadReviewPackage|pushPackage|BridgeReviewPackage|BridgeProductDevCarrier|BridgeProductDevSession|bridgeReviewPackageSchema|buildReviewSnapshotFrame|dispatchBridgeDevHostAdmittedEnvelope)\b|foundation\/review-package/u;
	const match = forbiddenPattern.exec(context.sourceText);

	if (match === null) {
		return;
	}

	addViolation(context, {
		ruleId: 'no-typescript-live-product-authority',
		position: match.index,
		message:
			'Debug TypeScript may supervise or proxy the Swift development backend but must not implement live Files/Review product authority',
	});
}

function readImportSource(node: ts.Node): string | null {
	if (
		(ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
		node.moduleSpecifier !== undefined &&
		isStringLiteralLike(node.moduleSpecifier)
	) {
		return node.moduleSpecifier.text;
	}

	if (!ts.isCallExpression(node) || node.arguments.length !== 1) {
		return null;
	}

	const firstArgument = node.arguments[0];

	if (firstArgument === undefined || !isStringLiteralLike(firstArgument)) {
		return null;
	}

	if (node.expression.kind === ts.SyntaxKind.ImportKeyword) {
		return firstArgument.text;
	}

	if (ts.isIdentifier(node.expression) && node.expression.text === 'require') {
		return firstArgument.text;
	}

	return null;
}

function isStringLiteralLike(
	node: ts.Node,
): node is ts.StringLiteral | ts.NoSubstitutionTemplateLiteral {
	return ts.isStringLiteral(node) || node.kind === ts.SyntaxKind.NoSubstitutionTemplateLiteral;
}

function isPrivatePierrePath(text: string): boolean {
	return (
		text.includes('@pierre/diffs/dist/') ||
		text.includes('@pierre/trees/dist/') ||
		text.includes('/packages/diffs/') ||
		text.includes('/packages/trees/') ||
		text.includes('pierrecomputer/pierre') ||
		text.includes('/libs-react/pierre/')
	);
}

function normalizeImportSpecifier(text: string): string {
	const queryIndex = text.search(/[?#]/);
	return queryIndex === -1 ? text : text.slice(0, queryIndex);
}

function isCodeViewImport(importSource: string): boolean {
	return importSource === '@pierre/diffs' || importSource === '@pierre/diffs/react';
}

function isPierreWorkerImport(importSource: string): boolean {
	return (
		importSource === '@pierre/diffs/worker' ||
		importSource === '@pierre/diffs/worker/worker.js' ||
		importSource === '@pierre/diffs/worker/worker-portable.js'
	);
}

function isAllowedTreesImportPath(relativePath: string): boolean {
	return (
		relativePath === 'src/app/bridge-viewer-tree-theme.ts' ||
		isPathInside(relativePath, 'src/file-viewer/') ||
		isPathInside(relativePath, 'src/review-viewer/trees/')
	);
}

function isAllowedCodeViewImportPath(relativePath: string): boolean {
	return (
		relativePath === 'src/core/comm-worker/bridge-worker-review-pierre-job-planner.ts' ||
		isPathInside(relativePath, 'src/file-viewer/') ||
		isPathInside(relativePath, 'src/review-viewer/code-view/') ||
		isPathInside(relativePath, 'src/review-viewer/workers/pierre/')
	);
}

function isAllowedPierreWorkerImportPath(relativePath: string): boolean {
	return isPathInside(relativePath, 'src/review-viewer/workers/pierre/');
}

function isAllowedWorkerConstructionPath(relativePath: string): boolean {
	return (
		relativePath === 'src/core/comm-worker/bridge-pane-comm-worker-session.ts' ||
		isPathInside(relativePath, 'src/core/telemetry-worker/') ||
		isPathInside(relativePath, 'src/review-viewer/workers/projection/') ||
		isPathInside(relativePath, 'src/review-viewer/workers/pierre/') ||
		isPathInside(relativePath, 'src/app/markdown/worker/') ||
		isPathInside(relativePath, 'src/review-viewer/workers/shared-rpc/')
	);
}

function isAllowedPostMessagePath(relativePath: string): boolean {
	return isAllowedWorkerConstructionPath(relativePath) || allowedPostMessagePaths.has(relativePath);
}

function isMarkdownRenderImport(importSource: string): boolean {
	return (
		importSource === '@shikijs/markdown-exit' ||
		importSource.startsWith('@shikijs/markdown-exit/') ||
		importSource === 'markdown-exit' ||
		importSource.startsWith('markdown-exit/') ||
		importSource === 'shiki' ||
		importSource.startsWith('shiki/')
	);
}

function isAllowedMarkdownRenderImportPath(relativePath: string): boolean {
	return (
		relativePath === 'src/review-viewer/workers/pierre/bridge-pierre-language-normalization.ts' ||
		relativePath === 'src/app/markdown/worker/bridge-markdown-render-worker-renderer.ts'
	);
}

function isStateEffectImport(importSource: string): boolean {
	return (
		importSource.startsWith('@pierre/') ||
		importSource.includes('/bridge/') ||
		importSource.includes('bridge-rpc') ||
		importSource.includes('bridge-resource-url') ||
		importSource.includes('/foundation/content') ||
		importSource.includes('/foundation/telemetry') ||
		importSource.includes('/review-viewer/workers') ||
		importSource.includes('../workers') ||
		importSource.includes('./workers')
	);
}

function isAppProtocolOrViewerImport(context: SourceContext, importSource: string): boolean {
	const targetPath = resolveImportTargetPath(context.relativePath, importSource) ?? importSource;
	return (
		isPathInside(targetPath, 'src/features/review/') ||
		isPathInside(targetPath, 'src/features/worktree-file/') ||
		isPathInside(targetPath, 'src/review-viewer/') ||
		isPathInside(targetPath, 'src/foundation/review-package/')
	);
}

function resolveImportTargetPath(relativePath: string, importSource: string): string | null {
	if (importSource.startsWith('@/')) {
		return normalizePath(join('src', importSource.slice(2)));
	}
	if (!importSource.startsWith('.')) {
		return null;
	}
	return normalizePath(join(dirname(relativePath), importSource));
}

function isCorePath(relativePath: string): boolean {
	return isPathInside(relativePath, 'src/core/');
}

function isSharedBridgeProductRuntimePath(relativePath: string): boolean {
	if (
		isTestPath(relativePath) ||
		relativePath === 'src/core/comm-worker/bridge-product-dev-bootstrap.ts' ||
		bridgeProductEndpointAdapterPaths.has(relativePath) ||
		bridgeProductExecutableEntryPaths.has(relativePath)
	) {
		return false;
	}
	return (
		isPathInside(relativePath, 'src/core/comm-worker/') ||
		relativePath === 'src/app/bridge-app.tsx' ||
		(isPathInside(relativePath, 'src/app/bridge-app-') &&
			!isPathInside(relativePath, 'src/app/bridge-app-dev-')) ||
		isPathInside(relativePath, 'src/file-viewer/') ||
		isPathInside(relativePath, 'src/review-viewer/')
	);
}

function isSharedBridgeProductRequestRuntimePath(relativePath: string): boolean {
	return (
		isPathInside(relativePath, 'src/core/comm-worker/bridge-comm-worker-') ||
		isPathInside(relativePath, 'src/core/comm-worker/bridge-worker-') ||
		isPathInside(relativePath, 'src/core/comm-worker/bridge-product-')
	);
}

function isContentEffectImport(importSource: string): boolean {
	return importSource.includes('/foundation/content');
}

function isStatePath(relativePath: string): boolean {
	return (
		isPathInside(relativePath, 'src/review-viewer/state/') ||
		isPathInside(relativePath, 'src/features/review/state/') ||
		isPathInside(relativePath, 'src/features/worktree-file/state/')
	);
}

function isShellPath(relativePath: string): boolean {
	return isPathInside(relativePath, 'src/review-viewer/shell/');
}

function isTestPath(relativePath: string): boolean {
	return (
		/\.(?:unit|integration|e2e|browser)\.test\.[cm]?[jt]sx?$/u.test(relativePath) ||
		/\.browser\.[a-z0-9-]+-suite\.[cm]?[jt]sx?$/u.test(relativePath) ||
		/\.browser\.benchmark\.[cm]?[jt]sx?$/u.test(relativePath) ||
		relativePath.includes('/test-fixtures/')
	);
}

function isArchitectureCheckerPath(relativePath: string): boolean {
	return relativePath.startsWith('scripts/check-bridgeweb-architecture');
}

function scriptKindForPath(filePath: string): ts.ScriptKind {
	if (filePath.endsWith('.tsx')) {
		return ts.ScriptKind.TSX;
	}

	if (filePath.endsWith('.jsx')) {
		return ts.ScriptKind.JSX;
	}

	return ts.ScriptKind.TS;
}

function isPathInside(relativePath: string, directoryPath: string): boolean {
	return relativePath.startsWith(directoryPath);
}

function normalizePath(path: string): string {
	return path.replaceAll('\\', '/');
}

function addViolation(context: SourceContext, props: AddViolationProps): void {
	const violationPosition = props.position ?? props.node?.getStart(context.sourceFile) ?? 0;
	const lineAndCharacter = context.sourceFile.getLineAndCharacterOfPosition(violationPosition);

	context.violations.push({
		ruleId: props.ruleId,
		relativePath: context.relativePath,
		line: lineAndCharacter.line + 1,
		column: lineAndCharacter.character + 1,
		message: props.message,
	});
}

function compareViolations(left: ArchitectureViolation, right: ArchitectureViolation): number {
	return (
		left.relativePath.localeCompare(right.relativePath) ||
		left.line - right.line ||
		left.column - right.column ||
		left.ruleId.localeCompare(right.ruleId)
	);
}

function isLedgerRuleId(value: string): value is RuleId {
	return debtLedgerRuleIds.has(value);
}

function isNodeErrorWithCode(error: unknown, code: string): error is NodeJS.ErrnoException {
	return error instanceof Error && 'code' in error && error.code === code;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
	const report = await checkBridgeWebArchitecture();

	if (!report.ok) {
		for (const violation of report.violations) {
			console.error(
				[
					violation.relativePath,
					`${violation.line}:${violation.column}`,
					violation.ruleId,
					violation.message,
				].join(' - '),
			);
		}

		process.exitCode = 1;
	}
}
