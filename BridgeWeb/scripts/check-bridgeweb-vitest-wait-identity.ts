import ts from 'typescript';

type VitestBindingIdentity =
	| 'namespace'
	| 'vi'
	| 'expect'
	| 'waitFor'
	| 'waitUntil'
	| 'poll'
	| 'element';

export function resolveVitestWaitIdentity(
	expression: ts.Expression,
	checker: ts.TypeChecker,
): VitestBindingIdentity | null {
	return resolveBindingIdentity(expression, checker, new Set<ts.Node>());
}

function resolveBindingIdentity(
	expression: ts.Expression,
	checker: ts.TypeChecker,
	visited: Set<ts.Node>,
): VitestBindingIdentity | null {
	if (visited.has(expression)) return null;
	visited.add(expression);
	if (ts.isParenthesizedExpression(expression) || ts.isAsExpression(expression)) {
		return resolveBindingIdentity(expression.expression, checker, visited);
	}
	if (ts.isPropertyAccessExpression(expression)) {
		return memberIdentity(
			resolveBindingIdentity(expression.expression, checker, visited),
			expression.name.text,
		);
	}
	if (!ts.isIdentifier(expression)) return null;
	for (const declaration of checker.getSymbolAtLocation(expression)?.declarations ?? []) {
		if (ts.isImportSpecifier(declaration) || ts.isNamespaceImport(declaration)) {
			let parent: ts.Node = declaration.parent;
			while (!ts.isImportDeclaration(parent)) parent = parent.parent;
			if (!ts.isStringLiteral(parent.moduleSpecifier) || parent.moduleSpecifier.text !== 'vitest')
				continue;
			if (ts.isNamespaceImport(declaration)) return 'namespace';
			return memberIdentity('namespace', (declaration.propertyName ?? declaration.name).text);
		}
		if (ts.isVariableDeclaration(declaration)) {
			if (declaration.initializer !== undefined) {
				return resolveBindingIdentity(declaration.initializer, checker, visited);
			}
			// Only Vitest's installed global declarations establish bare API identity.
			if (
				declaration.getSourceFile().fileName.replaceAll('\\', '/').endsWith('/vitest/globals.d.ts')
			) {
				return memberIdentity('namespace', expression.text);
			}
		}
		if (ts.isBindingElement(declaration) && ts.isObjectBindingPattern(declaration.parent)) {
			const variable = declaration.parent.parent;
			const name = declaration.propertyName ?? declaration.name;
			if (
				ts.isVariableDeclaration(variable) &&
				variable.initializer !== undefined &&
				(ts.isIdentifier(name) || ts.isStringLiteralLike(name))
			) {
				return memberIdentity(
					resolveBindingIdentity(variable.initializer, checker, visited),
					name.text,
				);
			}
		}
	}
	return null;
}

function memberIdentity(
	owner: VitestBindingIdentity | null,
	name: string,
): VitestBindingIdentity | null {
	if (owner === 'namespace' && (name === 'vi' || name === 'vitest')) return 'vi';
	if (owner === 'namespace' && name === 'expect') return 'expect';
	if (owner === 'vi' && (name === 'waitFor' || name === 'waitUntil')) return name;
	if (owner === 'expect' && (name === 'poll' || name === 'element')) return name;
	return null;
}
