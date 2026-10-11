import { readFileSync } from 'node:fs';
import { dirname, join, matchesGlob, relative } from 'node:path';

import ts from 'typescript';

// Rule `no-timed-wait-in-tests`: a BridgeWeb test wait completes because an
// application event or a DOM condition occurred, never because time passed.
//
// Roots are the real test inventory: every file matched by an `include` glob or
// named in `setupFiles` of any `vitest*.config.ts`. The rule follows each root's
// runtime imports (resolved by TypeScript with BridgeWeb's tsconfig) and stops
// at production modules: a product deadline is product behavior, not a test
// wait. Production modules are those reachable from the product's real
// entrypoints (see `collectProductionModulePaths`); every other module a test
// reaches is test support, whatever its file name, and is scanned. It reports,
// in every root and reachable test-support module:
// - `waitForTimeout(...)`;
// - an awaited sleep/delay helper, or an awaited `setTimeout` from
//   `node:timers/promises`;
// - an awaited `new Promise` whose only resolution is a timer, whatever its delay
//   (a zero-delay timer is still a wait on time);
// - any other timer that settles a promise, unless the promise is written directly
//   in a `Promise.race([...])` array and its delay is exactly a hang-bound constant
//   imported from `tests/vitest-hang-bounds.ts`.

export interface TimedWaitSourceFile {
	readonly relativePath: string;
	readonly sourceFile: ts.SourceFile;
}

export type TimedWaitRuleId =
	| 'no-timed-wait-in-tests'
	| 'no-vitest-wait-options'
	| 'no-vitest-wait-calls'
	| 'no-playwright-timeout-options';

export interface FindTimedWaitsInTestImportClosureProps {
	readonly packageRootPath: string;
	readonly sourceFiles: readonly TimedWaitSourceFile[];
}

export interface TimedWaitFinding {
	readonly column: number;
	readonly line: number;
	readonly message: string;
	readonly relativePath: string;
	readonly ruleId: TimedWaitRuleId;
}

const vitestConfigPathPattern = /^vitest(?:\.[\w-]+)?\.config\.ts$/u;
// The package scripts that build or audit the shipped product; their files are
// production entrypoints alongside index.html, the tsdown entries and the
// Vite and tsdown configs themselves.
const productPackageScriptNames: readonly string[] = ['build', 'audit:assets'];
const productConfigPaths: readonly string[] = ['vite.config.ts', 'tsdown.config.ts'];
const hangBoundModulePath = 'tests/vitest-hang-bounds.ts';
const sleepHelperNamePattern = /^(?:sleep|delay)(?:[A-Z0-9_]\w*)?$/u;
const timerFunctionNames = new Set(['setTimeout', 'setInterval']);
const defaultCompilerOptions: ts.CompilerOptions = {
	allowImportingTsExtensions: true,
	module: ts.ModuleKind.NodeNext,
	moduleResolution: ts.ModuleResolutionKind.NodeNext,
	noEmit: true,
};

interface ModuleResolutionContext {
	readonly compilerOptions: ts.CompilerOptions;
	readonly packageRootPath: string;
	readonly sourceFilesByPath: ReadonlyMap<string, TimedWaitSourceFile>;
}

export function findTimedWaitsInTestImportClosure(
	props: FindTimedWaitsInTestImportClosureProps,
): readonly TimedWaitFinding[] {
	const resolution: ModuleResolutionContext = {
		compilerOptions: readPackageCompilerOptions(props.packageRootPath),
		packageRootPath: props.packageRootPath,
		sourceFilesByPath: new Map(
			props.sourceFiles.map((sourceFile: TimedWaitSourceFile): [string, TimedWaitSourceFile] => [
				sourceFile.relativePath,
				sourceFile,
			]),
		),
	};
	const productionModulePaths = collectProductionModulePaths(resolution);
	const reachingTestRootByPath = collectTestImportClosure(resolution, productionModulePaths);
	const findings: TimedWaitFinding[] = [];

	for (const [relativePath, reachingTestRoot] of reachingTestRootByPath) {
		const closureFile = resolution.sourceFilesByPath.get(relativePath);
		if (closureFile === undefined) continue;
		const reachability =
			reachingTestRoot === relativePath
				? 'test file'
				: `module imported by test file ${reachingTestRoot}`;
		const hangBoundNames = importedHangBoundNames(closureFile, resolution);
		visitNodes(closureFile.sourceFile, (node: ts.Node): void => {
			const timedWaitDescription = describeTimedWait(node, hangBoundNames);
			if (timedWaitDescription === null) return;
			const position = closureFile.sourceFile.getLineAndCharacterOfPosition(
				node.getStart(closureFile.sourceFile),
			);
			findings.push({
				column: position.character + 1,
				line: position.line + 1,
				relativePath,
				ruleId: 'no-timed-wait-in-tests',
				message: `${timedWaitDescription} in a ${reachability}; a test wait must complete on an application event or DOM condition, and a timer may only bound it with a hang bound from ${hangBoundModulePath}`,
			});
		});
	}

	return findings;
}

export function findHiddenTimedWaitsInSourceFiles(props: {
	readonly packageRootPath: string;
	readonly sourceFiles: readonly TimedWaitSourceFile[];
}): readonly TimedWaitFinding[] {
	const resolution: ModuleResolutionContext = {
		compilerOptions: readPackageCompilerOptions(props.packageRootPath),
		packageRootPath: props.packageRootPath,
		sourceFilesByPath: new Map(
			props.sourceFiles.map((sourceFile): [string, TimedWaitSourceFile] => [
				sourceFile.relativePath,
				sourceFile,
			]),
		),
	};
	const productionModulePaths = collectProductionModulePaths(resolution);
	const testImportClosure = collectTestImportClosure(resolution, productionModulePaths);
	const findings: TimedWaitFinding[] = [];

	const candidatePaths = new Set(testImportClosure.keys());
	for (const sourceFile of props.sourceFiles) {
		if (isPlaywrightVerifierPath(sourceFile.relativePath))
			candidatePaths.add(sourceFile.relativePath);
	}
	for (const relativePath of candidatePaths) {
		const sourceFile = resolution.sourceFilesByPath.get(relativePath);
		if (sourceFile === undefined) continue;
		visitNodes(sourceFile.sourceFile, (node: ts.Node): void => {
			for (const vitestRuleId of describeVitestHiddenWaits(node)) {
				findings.push(
					makeTimedWaitFinding(sourceFile, node, vitestRuleId, vitestRuleMessage(vitestRuleId)),
				);
			}
			if (isPlaywrightVerifierPath(relativePath)) {
				const playwrightMessage = describePlaywrightTimeoutOption(node);
				if (playwrightMessage !== null) {
					findings.push(
						makeTimedWaitFinding(
							sourceFile,
							node,
							'no-playwright-timeout-options',
							playwrightMessage,
						),
					);
				}
			}
		});
	}

	return findings;
}

function makeTimedWaitFinding(
	sourceFile: TimedWaitSourceFile,
	node: ts.Node,
	ruleId: TimedWaitRuleId,
	description: string,
): TimedWaitFinding {
	const position = sourceFile.sourceFile.getLineAndCharacterOfPosition(
		node.getStart(sourceFile.sourceFile),
	);
	return {
		column: position.character + 1,
		line: position.line + 1,
		message: description,
		relativePath: sourceFile.relativePath,
		ruleId,
	};
}

function describeVitestHiddenWaits(node: ts.Node): readonly TimedWaitRuleId[] {
	if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression)) return [];
	const receiver = node.expression.expression;
	const method = node.expression.name.text;
	if (
		ts.isIdentifier(receiver) &&
		receiver.text === 'vi' &&
		(method === 'waitFor' || method === 'waitUntil')
	) {
		return hasWaitOption(node, ['timeout', 'interval'])
			? ['no-vitest-wait-options', 'no-vitest-wait-calls']
			: ['no-vitest-wait-calls'];
	}
	if (
		ts.isIdentifier(receiver) &&
		receiver.text === 'expect' &&
		(method === 'poll' || method === 'element')
	) {
		return hasWaitOption(node, ['timeout', 'interval']) ? ['no-vitest-wait-options'] : [];
	}
	return [];
}

function vitestRuleMessage(ruleId: TimedWaitRuleId): string {
	if (ruleId === 'no-vitest-wait-options') {
		return 'Vitest wait options may not set timeout or interval; await the owner fact or use the shared configuration hang bound';
	}
	return 'vi.waitFor() and vi.waitUntil() are timed waits; replace them with an owner fact or event';
}

function hasWaitOption(call: ts.CallExpression, optionNames: readonly string[]): boolean {
	const options = call.arguments[1];
	if (options === undefined || !ts.isObjectLiteralExpression(options)) return false;
	return options.properties.some((property): boolean => {
		if (!ts.isPropertyAssignment(property) && !ts.isShorthandPropertyAssignment(property))
			return false;
		const name = property.name;
		return (
			name !== undefined &&
			propertyNameText(name) !== null &&
			optionNames.includes(propertyNameText(name) ?? '')
		);
	});
}

function describePlaywrightTimeoutOption(node: ts.Node): string | null {
	if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression)) return null;
	if (!playwrightTimeoutMethodNames.has(node.expression.name.text)) return null;
	const options = node.arguments.find((argument): argument is ts.ObjectLiteralExpression =>
		ts.isObjectLiteralExpression(argument),
	);
	if (options === undefined) return null;
	const timeoutProperty = options.properties.find((property): boolean => {
		if (!ts.isPropertyAssignment(property) && !ts.isShorthandPropertyAssignment(property))
			return false;
		return property.name !== undefined && propertyNameText(property.name) === 'timeout';
	});
	if (timeoutProperty === undefined) return null;
	if (ts.isShorthandPropertyAssignment(timeoutProperty))
		return 'Playwright calls may not pass a timeout option; use the shared journey hang bound';
	if (!ts.isPropertyAssignment(timeoutProperty)) return null;
	return isNumericOrConstantExpression(timeoutProperty.initializer)
		? 'Playwright page, locator, and wait calls may not pass an explicit timeout option; use the shared journey hang bound'
		: null;
}

const playwrightTimeoutMethodNames = new Set([
	'click',
	'dblclick',
	'dispatchEvent',
	'dragTo',
	'evaluate',
	'evaluateAll',
	'evaluateHandle',
	'fill',
	'focus',
	'getAttribute',
	'goBack',
	'goForward',
	'hover',
	'innerHTML',
	'innerText',
	'inputValue',
	'isChecked',
	'isDisabled',
	'isEditable',
	'isEnabled',
	'isVisible',
	'press',
	'reload',
	'screenshot',
	'scrollIntoViewIfNeeded',
	'selectOption',
	'setContent',
	'setInputFiles',
	'tap',
	'textContent',
	'type',
	'uncheck',
	'waitFor',
	'waitForEvent',
	'waitForFunction',
	'waitForLoadState',
	'waitForNavigation',
	'waitForRequest',
	'waitForResponse',
	'waitForSelector',
	'waitForURL',
	'goto',
]);

function isPlaywrightVerifierPath(relativePath: string): boolean {
	return (
		relativePath.startsWith('tests/e2e/') ||
		relativePath.startsWith('scripts/verify-bridge-viewer-worktree-dev-server/')
	);
}

function propertyNameText(name: ts.PropertyName): string | null {
	if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name))
		return name.text;
	return null;
}

function isNumericOrConstantExpression(expression: ts.Expression): boolean {
	if (
		ts.isNumericLiteral(expression) ||
		ts.isIdentifier(expression) ||
		ts.isPropertyAccessExpression(expression)
	)
		return true;
	if (ts.isAsExpression(expression) || ts.isTypeAssertionExpression(expression)) {
		return isNumericOrConstantExpression(expression.expression);
	}
	return false;
}

function readPackageCompilerOptions(packageRootPath: string): ts.CompilerOptions {
	const tsconfigPath = join(packageRootPath, 'tsconfig.json');
	if (!ts.sys.fileExists(tsconfigPath)) return defaultCompilerOptions;
	const configFile = ts.readConfigFile(tsconfigPath, (path: string): string | undefined =>
		ts.sys.readFile(path),
	);
	if (configFile.error !== undefined) {
		throw new Error(
			`Cannot read ${tsconfigPath}: ${ts.flattenDiagnosticMessageText(configFile.error.messageText, '\n')}`,
		);
	}
	return ts.parseJsonConfigFileContent(
		configFile.config,
		ts.sys,
		packageRootPath,
		undefined,
		tsconfigPath,
	).options;
}

// Breadth-first from every test root, remembering the first root that reaches
// each module so a finding can name how a test depends on it.
function collectTestImportClosure(
	resolution: ModuleResolutionContext,
	productionModulePaths: ReadonlySet<string>,
): ReadonlyMap<string, string> {
	const reachingTestRootByPath = new Map<string, string>();
	const pendingPaths: string[] = [];
	for (const relativePath of collectTestRootPaths(resolution.sourceFilesByPath)) {
		reachingTestRootByPath.set(relativePath, relativePath);
		pendingPaths.push(relativePath);
	}

	for (let pendingIndex = 0; pendingIndex < pendingPaths.length; pendingIndex += 1) {
		const importerPath = pendingPaths[pendingIndex];
		if (importerPath === undefined) continue;
		const importerFile = resolution.sourceFilesByPath.get(importerPath);
		const reachingTestRoot = reachingTestRootByPath.get(importerPath);
		if (importerFile === undefined || reachingTestRoot === undefined) continue;
		for (const importSpecifier of readRuntimeImportSpecifiers(importerFile.sourceFile)) {
			const importedPath = resolveImportedSourcePath(importerFile, importSpecifier, resolution);
			if (importedPath === null || reachingTestRootByPath.has(importedPath)) continue;
			if (productionModulePaths.has(importedPath)) continue;
			reachingTestRootByPath.set(importedPath, reachingTestRoot);
			pendingPaths.push(importedPath);
		}
	}

	return reachingTestRootByPath;
}

// Every module the shipped product can load: the closure of runtime imports and
// `new URL('<relative path>', import.meta.url)` references (worker entries and
// bundled assets) from index.html's module scripts, the tsdown entries, the
// Vite and tsdown configs, and the files the product package scripts run.
function collectProductionModulePaths(resolution: ModuleResolutionContext): ReadonlySet<string> {
	const productionModulePaths = new Set<string>();
	const pendingPaths = readProductionEntrypointPaths(resolution).filter(
		(relativePath: string): boolean => resolution.sourceFilesByPath.has(relativePath),
	);
	for (let pendingIndex = 0; pendingIndex < pendingPaths.length; pendingIndex += 1) {
		const modulePath = pendingPaths[pendingIndex];
		if (modulePath === undefined || productionModulePaths.has(modulePath)) continue;
		const moduleFile = resolution.sourceFilesByPath.get(modulePath);
		if (moduleFile === undefined) continue;
		productionModulePaths.add(modulePath);
		for (const importSpecifier of readRuntimeImportSpecifiers(moduleFile.sourceFile)) {
			const importedPath = resolveImportedSourcePath(moduleFile, importSpecifier, resolution);
			if (importedPath !== null) pendingPaths.push(importedPath);
		}
		for (const referencedPath of readImportMetaUrlReferences(moduleFile)) {
			if (resolution.sourceFilesByPath.has(referencedPath)) pendingPaths.push(referencedPath);
		}
	}
	return productionModulePaths;
}

function readProductionEntrypointPaths(resolution: ModuleResolutionContext): readonly string[] {
	const entrypointPaths: string[] = [...productConfigPaths];
	const indexHtml = readPackageTextFile(resolution.packageRootPath, 'index.html');
	for (const match of indexHtml?.matchAll(/<script\b[^>]*\bsrc="\/?([^"]+)"/gu) ?? []) {
		if (match[1] !== undefined) entrypointPaths.push(match[1]);
	}
	const tsdownConfig = resolution.sourceFilesByPath.get('tsdown.config.ts');
	if (tsdownConfig !== undefined) {
		visitNodes(tsdownConfig.sourceFile, (node: ts.Node): void => {
			if (
				!ts.isPropertyAssignment(node) ||
				!ts.isIdentifier(node.name) ||
				node.name.text !== 'entry' ||
				!ts.isObjectLiteralExpression(node.initializer)
			) {
				return;
			}
			for (const property of node.initializer.properties) {
				if (ts.isPropertyAssignment(property) && ts.isStringLiteralLike(property.initializer)) {
					entrypointPaths.push(join(property.initializer.text).replaceAll('\\', '/'));
				}
			}
		});
	}
	const packageJson = readPackageTextFile(resolution.packageRootPath, 'package.json');
	const packageManifest: unknown = packageJson === null ? null : JSON.parse(packageJson);
	const packageScripts: unknown =
		typeof packageManifest === 'object' && packageManifest !== null
			? Reflect.get(packageManifest, 'scripts')
			: null;
	for (const scriptName of productPackageScriptNames) {
		const command: unknown =
			typeof packageScripts === 'object' && packageScripts !== null
				? Reflect.get(packageScripts, scriptName)
				: undefined;
		if (typeof command !== 'string') continue;
		for (const match of command.matchAll(/(?:^|\s)(\S+\.tsx?)(?=\s|$)/gu)) {
			if (match[1] !== undefined) entrypointPaths.push(match[1]);
		}
	}
	return entrypointPaths;
}

function readImportMetaUrlReferences(moduleFile: TimedWaitSourceFile): readonly string[] {
	const referencedPaths: string[] = [];
	visitNodes(moduleFile.sourceFile, (node: ts.Node): void => {
		if (
			!ts.isNewExpression(node) ||
			!ts.isIdentifier(node.expression) ||
			node.expression.text !== 'URL'
		) {
			return;
		}
		const [urlArgument, baseArgument] = node.arguments ?? [];
		if (
			urlArgument === undefined ||
			!ts.isStringLiteralLike(urlArgument) ||
			!urlArgument.text.startsWith('.') ||
			baseArgument === undefined ||
			baseArgument.getText(moduleFile.sourceFile) !== 'import.meta.url'
		) {
			return;
		}
		referencedPaths.push(
			join(dirname(moduleFile.relativePath), urlArgument.text.replace(/[?#].*$/u, '')).replaceAll(
				'\\',
				'/',
			),
		);
	});
	return referencedPaths;
}

function readPackageTextFile(packageRootPath: string, relativePath: string): string | null {
	try {
		return readFileSync(join(packageRootPath, relativePath), 'utf8');
	} catch {
		return null;
	}
}

function collectTestRootPaths(
	sourceFilesByPath: ReadonlyMap<string, TimedWaitSourceFile>,
): readonly string[] {
	const includeGlobs: string[] = [];
	const setupFilePaths: string[] = [];
	for (const [relativePath, configFile] of sourceFilesByPath) {
		if (!vitestConfigPathPattern.test(relativePath)) continue;
		visitNodes(configFile.sourceFile, (node: ts.Node): void => {
			if (!ts.isPropertyAssignment(node) || !ts.isArrayLiteralExpression(node.initializer)) return;
			const propertyName = ts.isIdentifier(node.name) ? node.name.text : null;
			const values = node.initializer.elements.flatMap((element: ts.Expression): string[] =>
				ts.isStringLiteralLike(element) ? [element.text] : [],
			);
			if (propertyName === 'include') includeGlobs.push(...values);
			if (propertyName === 'setupFiles') {
				setupFilePaths.push(...values.map((value: string): string => value.replace(/^\.\//u, '')));
			}
		});
	}
	return [...sourceFilesByPath.keys()]
		.filter(
			(relativePath: string): boolean =>
				setupFilePaths.includes(relativePath) ||
				includeGlobs.some((includeGlob: string): boolean => matchesGlob(relativePath, includeGlob)),
		)
		.toSorted();
}

function readRuntimeImportSpecifiers(sourceFile: ts.SourceFile): readonly string[] {
	const importSpecifiers: string[] = [];
	visitNodes(sourceFile, (node: ts.Node): void => {
		if (ts.isImportDeclaration(node)) {
			if (node.importClause?.isTypeOnly === true) return;
			if (ts.isStringLiteral(node.moduleSpecifier))
				importSpecifiers.push(node.moduleSpecifier.text);
			return;
		}
		if (ts.isExportDeclaration(node)) {
			if (node.isTypeOnly || node.moduleSpecifier === undefined) return;
			if (ts.isStringLiteral(node.moduleSpecifier))
				importSpecifiers.push(node.moduleSpecifier.text);
			return;
		}
		if (
			ts.isCallExpression(node) &&
			node.expression.kind === ts.SyntaxKind.ImportKeyword &&
			node.arguments.length === 1
		) {
			const importArgument = node.arguments[0];
			if (importArgument !== undefined && ts.isStringLiteralLike(importArgument)) {
				importSpecifiers.push(importArgument.text);
			}
		}
	});
	return importSpecifiers;
}

function resolveImportedSourcePath(
	importerFile: TimedWaitSourceFile,
	importSpecifier: string,
	resolution: ModuleResolutionContext,
): string | null {
	const resolvedModule = ts.resolveModuleName(
		importSpecifier.replace(/[?#].*$/u, ''),
		importerFile.sourceFile.fileName,
		resolution.compilerOptions,
		ts.sys,
	).resolvedModule;
	if (resolvedModule === undefined || resolvedModule.isExternalLibraryImport === true) return null;
	const relativePath = relative(
		resolution.packageRootPath,
		resolvedModule.resolvedFileName,
	).replaceAll('\\', '/');
	return resolution.sourceFilesByPath.has(relativePath) ? relativePath : null;
}

// Local names bound to the shared hang-bound constants in this module.
function importedHangBoundNames(
	closureFile: TimedWaitSourceFile,
	resolution: ModuleResolutionContext,
): ReadonlySet<string> {
	const names = new Set<string>();
	for (const statement of closureFile.sourceFile.statements) {
		if (!ts.isImportDeclaration(statement) || !ts.isStringLiteral(statement.moduleSpecifier))
			continue;
		const namedBindings = statement.importClause?.namedBindings;
		if (namedBindings === undefined || !ts.isNamedImports(namedBindings)) continue;
		if (
			resolveImportedSourcePath(closureFile, statement.moduleSpecifier.text, resolution) !==
			hangBoundModulePath
		) {
			continue;
		}
		for (const element of namedBindings.elements) names.add(element.name.text);
	}
	return names;
}

function describeTimedWait(node: ts.Node, hangBoundNames: ReadonlySet<string>): string | null {
	if (ts.isCallExpression(node) && calleeName(node.expression) === 'waitForTimeout') {
		return 'waitForTimeout()';
	}
	if (ts.isAwaitExpression(node)) {
		const awaitedExpression = skipParentheses(node.expression);
		if (ts.isCallExpression(awaitedExpression)) {
			const awaitedCalleeName = calleeName(awaitedExpression.expression);
			if (awaitedCalleeName !== null && sleepHelperNamePattern.test(awaitedCalleeName)) {
				return `awaited ${awaitedCalleeName}()`;
			}
			if (awaitedCalleeName === 'setTimeout') return 'awaited timers/promises setTimeout()';
		}
		return null;
	}
	if (!ts.isNewExpression(node)) return null;
	const timerSettlement = describeTimerSettledPromise(node);
	if (timerSettlement === null) return null;
	if (isHangBoundRaceElement(node, timerSettlement, hangBoundNames)) return null;
	if (timerSettlement.timerOnlyResolution && isAwaited(node)) {
		return 'awaited Promise resolved only by a timer';
	}
	return 'timer promise that is not a Promise.race hang bound';
}

// The one permitted timer: a promise written directly in the array passed to
// `Promise.race(...)`, racing a condition, whose every delay is exactly an
// imported hang-bound constant (no arithmetic, no indirection).
function isHangBoundRaceElement(
	timerPromise: ts.NewExpression,
	timerSettlement: TimerSettledPromise,
	hangBoundNames: ReadonlySet<string>,
): boolean {
	let raceArray: ts.Node = timerPromise.parent;
	let raceElement: ts.Node = timerPromise;
	while (ts.isParenthesizedExpression(raceArray)) {
		raceElement = raceArray;
		raceArray = raceArray.parent;
	}
	if (
		!ts.isArrayLiteralExpression(raceArray) ||
		!raceArray.elements.some((element) => element === raceElement)
	) {
		return false;
	}
	const raceCall = raceArray.parent;
	if (
		!ts.isCallExpression(raceCall) ||
		raceCall.arguments[0] !== raceArray ||
		!ts.isPropertyAccessExpression(raceCall.expression) ||
		!ts.isIdentifier(raceCall.expression.expression) ||
		raceCall.expression.expression.text !== 'Promise' ||
		raceCall.expression.name.text !== 'race'
	) {
		return false;
	}
	return timerSettlement.delays.every(
		(delay): boolean => ts.isIdentifier(delay) && hangBoundNames.has(delay.text),
	);
}

interface TimerSettledPromise {
	readonly delays: readonly ts.Expression[];
	readonly timerOnlyResolution: boolean;
}

// A `new Promise` whose executor settles it (resolve or reject) from a timer.
function describeTimerSettledPromise(expression: ts.NewExpression): TimerSettledPromise | null {
	if (!ts.isIdentifier(expression.expression) || expression.expression.text !== 'Promise') {
		return null;
	}
	const executor = expression.arguments?.[0];
	if (
		executor === undefined ||
		(!ts.isArrowFunction(executor) && !ts.isFunctionExpression(executor))
	) {
		return null;
	}
	const settleNames = new Set(
		executor.parameters.flatMap((parameter): string[] =>
			ts.isIdentifier(parameter.name) ? [parameter.name.text] : [],
		),
	);
	const resolveName = executor.parameters[0]?.name;
	const delays: ts.Expression[] = [];
	let resolveReferenceCount = 0;
	let timerResolveReferenceCount = 0;
	visitNodes(executor.body, (node: ts.Node): void => {
		if (!ts.isIdentifier(node) || !settleNames.has(node.text)) return;
		const timerCall = enclosingTimerCall(node, executor);
		const isResolve =
			resolveName !== undefined && ts.isIdentifier(resolveName) && node.text === resolveName.text;
		if (isResolve) resolveReferenceCount += 1;
		if (timerCall === null) return;
		if (isResolve) timerResolveReferenceCount += 1;
		delays.push(timerCall.arguments[1] ?? ts.factory.createNumericLiteral(0));
	});
	if (delays.length === 0) return null;
	return {
		delays,
		timerOnlyResolution:
			resolveReferenceCount > 0 && resolveReferenceCount === timerResolveReferenceCount,
	};
}

function enclosingTimerCall(node: ts.Node, boundary: ts.Node): ts.CallExpression | null {
	let child: ts.Node = node;
	let ancestor: ts.Node | undefined = node.parent;
	while (ancestor !== undefined && child !== boundary) {
		if (
			ts.isCallExpression(ancestor) &&
			ancestor.arguments.some((argument: ts.Expression): boolean => argument === child) &&
			timerFunctionNames.has(calleeName(ancestor.expression) ?? '')
		) {
			return ancestor;
		}
		child = ancestor;
		ancestor = ancestor.parent;
	}
	return null;
}

function isAwaited(expression: ts.Expression): boolean {
	let parent = expression.parent;
	while (ts.isParenthesizedExpression(parent)) parent = parent.parent;
	return ts.isAwaitExpression(parent);
}

function calleeName(expression: ts.Expression): string | null {
	if (ts.isIdentifier(expression)) return expression.text;
	if (ts.isPropertyAccessExpression(expression)) return expression.name.text;
	return null;
}

function skipParentheses(expression: ts.Expression): ts.Expression {
	return ts.isParenthesizedExpression(expression)
		? skipParentheses(expression.expression)
		: expression;
}

function visitNodes(node: ts.Node, visitNode: (node: ts.Node) => void): void {
	visitNode(node);
	node.forEachChild((childNode: ts.Node): void => visitNodes(childNode, visitNode));
}
