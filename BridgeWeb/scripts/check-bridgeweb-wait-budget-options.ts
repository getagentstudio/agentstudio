import ts from 'typescript';

// Resolve the installed API declaration rather than guessing from a method name.
// Playwright 1.61.0 Page/Frame evaluate has data arguments; Locator evaluate has
// timeout-bearing options. Overload resolution gives each its actual position.
const playwrightOwnerNames = new Set([
	'Page',
	'Frame',
	'Locator',
	'ElementHandle',
	'BrowserContext',
	'BrowserType',
]);

export function createWaitBudgetTypeChecker(props: {
	readonly compilerOptions: ts.CompilerOptions;
	readonly sourceFiles: readonly ts.SourceFile[];
}): ts.TypeChecker {
	const host = ts.createCompilerHost(props.compilerOptions);
	const suppliedFiles = new Map(
		props.sourceFiles.map((file): [string, ts.SourceFile] => [file.fileName, file]),
	);
	const readSourceFile = host.getSourceFile.bind(host);
	host.getSourceFile = (
		filename,
		languageVersion,
		onError,
		shouldCreateNewSourceFile,
	): ts.SourceFile | undefined =>
		suppliedFiles.get(filename) ??
		readSourceFile(filename, languageVersion, onError, shouldCreateNewSourceFile);
	return ts
		.createProgram({ rootNames: [...suppliedFiles.keys()], options: props.compilerOptions, host })
		.getTypeChecker();
}

export function playwrightTimeoutOptionsIndex(
	call: ts.CallExpression,
	checker: ts.TypeChecker,
): number | null {
	const declaration = checker.getResolvedSignature(call)?.declaration;
	if (
		declaration === undefined ||
		!ts.isMethodSignature(declaration) ||
		!ts.isInterfaceDeclaration(declaration.parent)
	)
		return null;
	if (!playwrightOwnerNames.has(declaration.parent.name.text)) return null;
	// Only Playwright declarations own this policy; an unrelated click() is data.
	if (!declaration.getSourceFile().fileName.replaceAll('\\', '/').includes('/playwright-core/'))
		return null;
	for (const [index, parameter] of declaration.parameters.entries()) {
		if (
			!ts.isIdentifier(parameter.name) ||
			!['options', 'optionsOrPredicate'].includes(parameter.name.text)
		)
			continue;
		const parameterType = checker.getNonNullableType(checker.getTypeAtLocation(parameter));
		if (typeHasProperty(parameterType, 'timeout')) {
			// The no-Arg Locator.evaluate overload in 1.61.0 lists options
			// second, but coreBundle.js evaluates arg second and options third.
			// Never interpret page-function data as that runtime budget.
			if (
				declaration.parent.name.text === 'Locator' &&
				declaration.name !== undefined &&
				ts.isIdentifier(declaration.name) &&
				declaration.name.text === 'evaluate'
			)
				return 2;
			return index;
		}
	}
	return null;
}

export function hasExplicitWaitOption(props: {
	readonly expression: ts.Expression | undefined;
	readonly optionNames: readonly string[];
	readonly checker: ts.TypeChecker;
}): boolean {
	return inspectWaitOption(props, new Set<ts.Node>(), props.expression);
}

function inspectWaitOption(
	props: {
		readonly expression: ts.Expression | undefined;
		readonly optionNames: readonly string[];
		readonly checker: ts.TypeChecker;
	},
	visited: Set<ts.Node>,
	callOptions: ts.Expression | undefined,
): boolean {
	const expression = props.expression;
	if (expression === undefined || visited.has(expression)) return false;
	visited.add(expression);
	if (
		ts.isParenthesizedExpression(expression) ||
		ts.isAsExpression(expression) ||
		ts.isSatisfiesExpression(expression) ||
		ts.isTypeAssertionExpression(expression)
	) {
		return inspectWaitOption({ ...props, expression: expression.expression }, visited, callOptions);
	}
	if (ts.isObjectLiteralExpression(expression)) {
		return expression.properties.some((property): boolean => {
			if (ts.isSpreadAssignment(property))
				return inspectWaitOption(
					{ ...props, expression: property.expression },
					visited,
					callOptions,
				);
			if (!ts.isPropertyAssignment(property) && !ts.isShorthandPropertyAssignment(property))
				return false;
			const name = property.name;
			const propertyName = ts.isComputedPropertyName(name)
				? constantStringValue(name.expression, props.checker)
				: ts.isIdentifier(name) || ts.isStringLiteralLike(name)
					? name.text
					: null;
			return propertyName !== null && props.optionNames.includes(propertyName);
		});
	}
	if (ts.isConditionalExpression(expression)) {
		return (
			inspectWaitOption({ ...props, expression: expression.whenTrue }, visited, callOptions) ||
			inspectWaitOption({ ...props, expression: expression.whenFalse }, visited, callOptions)
		);
	}
	if (ts.isBinaryExpression(expression)) {
		return (
			inspectWaitOption({ ...props, expression: expression.left }, visited, callOptions) ||
			inspectWaitOption({ ...props, expression: expression.right }, visited, callOptions)
		);
	}
	const symbol = props.checker.getSymbolAtLocation(expression);
	const declaration = symbol?.valueDeclaration;
	if (
		symbol !== undefined &&
		declaration !== undefined &&
		ts.isVariableDeclaration(declaration) &&
		declaration.initializer !== undefined
	) {
		return (
			hasAssignedWaitOption({ ...props, symbol, callOptions }) ||
			inspectWaitOption({ ...props, expression: declaration.initializer }, visited, callOptions)
		);
	}
	// Passed-through options with declared budget fields also carry a budget.
	const expressionType = props.checker.getTypeAtLocation(expression);
	return props.optionNames.some((name): boolean => typeHasProperty(expressionType, name));
}

function typeHasProperty(type: ts.Type, name: string): boolean {
	return (
		type.getProperty(name) !== undefined ||
		(type.isUnion() && type.types.some((member): boolean => typeHasProperty(member, name)))
	);
}

function constantStringValue(expression: ts.Expression, checker: ts.TypeChecker): string | null {
	if (ts.isStringLiteralLike(expression)) return expression.text;
	const expressionType = checker.getTypeAtLocation(expression);
	return expressionType.isStringLiteral() ? expressionType.value : null;
}

function hasAssignedWaitOption(props: {
	readonly symbol: ts.Symbol;
	readonly callOptions: ts.Expression | undefined;
	readonly checker: ts.TypeChecker;
	readonly optionNames: readonly string[];
}): boolean {
	const callOptions = props.callOptions;
	if (callOptions === undefined) return false;
	const executionScope = enclosingExecutionScope(callOptions);
	let assigned = false;
	const visit = (node: ts.Node): void => {
		if (node.getStart() >= callOptions.getStart()) return;
		if (node !== executionScope && ts.isFunctionLike(node)) return;
		if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
			const target = node.left;
			if (ts.isPropertyAccessExpression(target) || ts.isElementAccessExpression(target)) {
				const name = ts.isPropertyAccessExpression(target)
					? target.name.text
					: constantStringValue(target.argumentExpression, props.checker);
				if (
					name !== null &&
					props.optionNames.includes(name) &&
					props.checker.getSymbolAtLocation(target.expression) === props.symbol
				)
					assigned = true;
			}
		}
		node.forEachChild(visit);
	};
	visit(executionScope);
	return assigned;
}

function enclosingExecutionScope(node: ts.Node): ts.Node {
	let scope = node.parent;
	while (!ts.isSourceFile(scope) && !ts.isFunctionLike(scope)) scope = scope.parent;
	return scope;
}
