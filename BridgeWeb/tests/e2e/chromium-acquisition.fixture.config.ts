import { defineConfig } from 'vitest/config';
export default defineConfig({
	test: {
		include: ['tests/e2e/chromium-acquisition.fixture.ts'],
		runner: './tests/e2e/bridge-web-e2e-runner.ts',
		// This fixture's runner hang bound deliberately expires a stuck launch.
		testTimeout: 3_000,
		fileParallelism: false,
	},
});
