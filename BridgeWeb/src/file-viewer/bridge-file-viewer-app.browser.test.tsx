// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
// oxlint-disable-next-line import/no-unassigned-import -- Browser suites assert shell behavior without testing lazy import timing.
import './bridge-file-viewer-shell.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.startup-suite.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.virtualizer-suite.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.selection-suite.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.demand-suite.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.reactivation-demand-suite.js';
// oxlint-disable-next-line import/no-unassigned-import -- Aggregates Browser Mode suites.
import './bridge-file-viewer-app.browser.refresh-demand-suite.js';
import { afterAll, beforeEach, vi } from 'vitest';

import { installBridgeFileViewerNoopResizeObserver } from './bridge-file-viewer-browser-test-harness.js';

const originalBridgeFileViewerResizeObserver = globalThis.ResizeObserver;

beforeEach(() => {
	installBridgeFileViewerNoopResizeObserver();
});

afterAll(() => {
	Object.assign(globalThis, { ResizeObserver: originalBridgeFileViewerResizeObserver });
});

// Register at the Browser Mode entry; the shared module owns the pure pass-through wrapper.
vi.mock('../components/ui/dropdown-menu.js', async (importOriginal) => {
	const original = await importOriginal<typeof import('../components/ui/dropdown-menu.js')>();
	const { withFileMenuCompletion } =
		await import('./bridge-file-viewer-menu-completion.browser.test-support.js');
	return withFileMenuCompletion(original);
});
