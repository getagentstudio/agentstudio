import { defineConfig } from 'vitest/config';

import { reactActWarningGuardScope } from './tests/console-error-guard-scope.ts';
import {
	endToEndExpectPollHangBoundMilliseconds,
	endToEndHookTimeoutMilliseconds,
	endToEndTestTimeoutMilliseconds,
} from './tests/vitest-hang-bounds.ts';

export default defineConfig({
	test: {
		environment: 'node',
		fileParallelism: false,
		include: [
			'src/**/*.e2e.test.ts',
			'src/**/*.e2e.test.tsx',
			'tests/e2e/**/*.e2e.test.ts',
			'tests/e2e/**/*.e2e.test.tsx',
		],
		provide: reactActWarningGuardScope,
		setupFiles: [
			'./tests/console-error-guard.ts',
			'./tests/e2e/bridge-viewer-vite-e2e-test-signal.ts',
		],
		// The runner's hang bound, and the only clock these journeys are allowed; see
		// tests/vitest-hang-bounds.ts.
		testTimeout: endToEndTestTimeoutMilliseconds,
		hookTimeout: endToEndHookTimeoutMilliseconds,
		expect: {
			poll: { timeout: endToEndExpectPollHangBoundMilliseconds },
		},
	},
});
