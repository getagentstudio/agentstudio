import { afterEach, beforeEach, inject } from 'vitest';

import type { ConsoleErrorGuardScope } from './console-error-guard-scope.ts';
import { isReactActWarning } from './react-act-warning.ts';

// One console.error guard for every BridgeWeb Vitest suite (unit, node-integration,
// browser-integration and E2E). Each config declares its scope (see
// ./console-error-guard-scope.ts): the browser suite fails on every console.error,
// the node suites only on React act() warnings. The failure carries the
// formatted message, which names the component.
const guardScope: ConsoleErrorGuardScope | undefined = inject('consoleErrorGuardScope');
if (guardScope === undefined) {
	throw new Error(
		'BridgeWeb console error guard needs `provide: { consoleErrorGuardScope }` in the Vitest config.',
	);
}
const allowedConsoleErrorSubstrings: readonly string[] = [
	'flushSync was called from inside a lifecycle method',
];

let guardedConsoleErrorMessages: string[] = [];
let originalConsoleError: typeof console.error | null = null;

beforeEach((): void => {
	installConsoleErrorGuard();
});

afterEach((): void => {
	const failureMessages = uninstallConsoleErrorGuard();
	if (failureMessages.length > 0) {
		throw new Error(`BridgeWeb console error guard tripped:\n${failureMessages.join('\n')}`);
	}
});

function installConsoleErrorGuard(): void {
	// A previous test's afterEach can stop before this guard's afterEach runs when
	// an earlier hook throws; restore first so wrappers never stack.
	uninstallConsoleErrorGuard();
	guardedConsoleErrorMessages = [];
	const consoleErrorBeforeGuard = console.error;
	originalConsoleError = consoleErrorBeforeGuard;
	console.error = (...args: readonly unknown[]): void => {
		const message = formatConsoleArguments(args);
		if (isGuardedConsoleError(message)) {
			const writerStack = isReactActWarning(message) ? captureReactActWriterStack() : undefined;
			guardedConsoleErrorMessages.push(
				`console.error: ${message}${writerStack === undefined ? '' : `\n${writerStack}`}`,
			);
		}
		consoleErrorBeforeGuard(...args);
	};
}

function uninstallConsoleErrorGuard(): readonly string[] {
	if (originalConsoleError !== null) {
		console.error = originalConsoleError;
		originalConsoleError = null;
	}
	const failureMessages = guardedConsoleErrorMessages;
	guardedConsoleErrorMessages = [];
	return failureMessages;
}

function isGuardedConsoleError(message: string): boolean {
	if (guardScope === 'react-act-warnings') {
		return isReactActWarning(message);
	}
	return !allowedConsoleErrorSubstrings.some((allowedSubstring: string): boolean =>
		message.includes(allowedSubstring),
	);
}

// React passes the component name as a printf-style argument ("An update to %s
// inside a test was not wrapped in act(...)"), so substitute placeholders the
// way the console does; otherwise the failure would not name the component.
function formatConsoleArguments(args: readonly unknown[]): string {
	const [firstArgument, ...restArguments] = args;
	if (typeof firstArgument !== 'string') {
		return args.map((arg: unknown): string => stringifyGuardValue(arg)).join(' ');
	}
	const remainingArguments = [...restArguments];
	const formattedTemplate = firstArgument.replace(
		/%[sdifoOc%]/gu,
		(placeholder: string): string => {
			if (placeholder === '%%') {
				return '%';
			}
			if (remainingArguments.length === 0) {
				return placeholder;
			}
			const substitutedArgument = remainingArguments.shift();
			return placeholder === '%c' ? '' : stringifyGuardValue(substitutedArgument);
		},
	);
	return [
		formattedTemplate,
		...remainingArguments.map((arg: unknown): string => stringifyGuardValue(arg)),
	].join(' ');
}

function stringifyGuardValue(value: unknown): string {
	if (value instanceof Error) {
		return `${value.name}: ${value.message}`;
	}
	if (typeof value === 'string') {
		return value;
	}
	try {
		return JSON.stringify(value) ?? String(value);
	} catch {
		// Circular or otherwise unserializable values still need a readable failure.
		return String(value);
	}
}

function captureReactActWriterStack(): string | undefined {
	const previousLimit = Error.stackTraceLimit;
	try {
		Error.stackTraceLimit = Math.max(previousLimit ?? 10, 50);
		return new Error('React act warning writer stack').stack;
	} finally {
		Error.stackTraceLimit = previousLimit;
	}
}
