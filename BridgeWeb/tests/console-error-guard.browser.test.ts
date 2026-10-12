import { createElement, type ReactElement, useState } from 'react';
import { test } from 'vitest';
import { render } from 'vitest-browser-react';

import { defineConsoleErrorGuardProbe } from './console-error-guard-probe.ts';

let setActWarningProbeCount: ((count: number) => void) | null = null;

function ActWarningProbe(): ReactElement {
	const [count, setCount] = useState(0);
	setActWarningProbeCount = setCount;
	return createElement('output', null, String(count));
}

function dispatchActWarningProbeUpdate(): void {
	setActWarningProbeCount?.(1);
}

// The browser suite renders a real component and updates its state outside
// act(), so react-dom itself emits the warning the guard must fail on. The
// function name is the component name the probe expects.
defineConsoleErrorGuardProbe({
	suiteName: 'browser-integration',
	emitActWarning: async (): Promise<void> => {
		await render(createElement(ActWarningProbe));
		dispatchActWarningProbeUpdate();
	},
	expectedWriterFrame: 'dispatchActWarningProbeUpdate',
});

// The browser suite keeps its broad guard: any console.error fails the test.
test.fails('fails a browser test on an ordinary console.error', () => {
	console.error('Bridge browser diagnostic that is not a React act() warning');
});
