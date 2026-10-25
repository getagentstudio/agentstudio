import { defineConfig } from 'vitest/config';

import { nodeIntegrationTestTimeoutMilliseconds } from '../vitest-hang-bounds.ts';
export default defineConfig({
	test: {
		include: ['tests/e2e/chromium-acquisition.fixture.ts'],
		runner: './tests/e2e/bridge-web-e2e-runner.ts',
		testTimeout: nodeIntegrationTestTimeoutMilliseconds,
		fileParallelism: false,
	},
});
