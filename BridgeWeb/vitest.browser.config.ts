import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { playwright } from '@vitest/browser-playwright';
import { defineConfig, type TestUserConfig } from 'vitest/config';

import { bridgeViteOptimizedDependencies } from './bridge-vite-optimized-dependencies.js';
import { everyConsoleErrorGuardScope } from './tests/console-error-guard-scope.ts';
import {
	browserBenchmarkTestTimeoutMilliseconds,
	browserBenchmarkExpectPollHangBoundMilliseconds,
	browserIntegrationTestTimeoutMilliseconds,
	browserExpectPollHangBoundMilliseconds,
} from './tests/vitest-hang-bounds.ts';

const bridgeWebPackageRoot = dirname(fileURLToPath(import.meta.url));
const repositoryTemporaryRoot = resolve(bridgeWebPackageRoot, '..', 'tmp');

const browserConfig = {
	enabled: true,
	provider: playwright({
		launchOptions: { channel: 'chrome' },
	}),
	headless: true,
	instances: [{ browser: 'chromium', name: 'integration-chromium' }],
	api: {
		host: '127.0.0.1',
		port: 63325,
	},
	viewport: {
		width: 1728,
		height: 972,
	},
	screenshotFailures: true,
	screenshotDirectory: resolve(repositoryTemporaryRoot, 'bridgeweb-vitest-screenshots'),
} satisfies NonNullable<TestUserConfig['browser']>;

export default defineConfig({
	plugins: [react()],
	resolve: {
		alias: {
			'@': `${bridgeWebPackageRoot}/src`,
		},
	},
	test: {
		globals: true,
		maxWorkers: '50%',
		tags: [
			{
				description: 'Scale-bound browser workloads run outside the per-commit correctness lane.',
				name: 'stress',
			},
		],
		projects: [
			{
				plugins: [react()],
				optimizeDeps: {
					include: [...bridgeViteOptimizedDependencies],
				},
				server: {
					fs: {
						allow: [bridgeWebPackageRoot, repositoryTemporaryRoot],
					},
				},
				resolve: {
					alias: {
						'@': `${bridgeWebPackageRoot}/src`,
					},
				},
				test: {
					name: 'integration-browser',
					provide: everyConsoleErrorGuardScope,
					setupFiles: ['./tests/console-error-guard.ts', './tests/vitest-browser-setup.ts'],
					browser: browserConfig,
					testTimeout: browserIntegrationTestTimeoutMilliseconds,
					expect: {
						poll: { timeout: browserExpectPollHangBoundMilliseconds },
					},
					include: [
						'src/**/*.browser.test.ts',
						'src/**/*.browser.test.tsx',
						'tests/**/*.browser.test.ts',
					],
					exclude: [
						'**/node_modules/**',
						'**/dist/**',
						'src/**/*.browser.benchmark.ts',
						'src/**/*.browser.benchmark.tsx',
					],
				},
			},
			{
				plugins: [react()],
				optimizeDeps: {
					include: [...bridgeViteOptimizedDependencies],
				},
				server: {
					fs: {
						allow: [bridgeWebPackageRoot, repositoryTemporaryRoot],
					},
				},
				resolve: {
					alias: {
						'@': `${bridgeWebPackageRoot}/src`,
					},
				},
				test: {
					name: 'benchmarks-browser',
					testTimeout: browserBenchmarkTestTimeoutMilliseconds,
					expect: {
						poll: { timeout: browserBenchmarkExpectPollHangBoundMilliseconds },
					},
					provide: everyConsoleErrorGuardScope,
					setupFiles: ['./tests/console-error-guard.ts', './tests/vitest-browser-setup.ts'],
					browser: {
						...browserConfig,
						api: {
							host: '127.0.0.1',
							port: 63326,
						},
						instances: [{ browser: 'chromium', name: 'benchmark-chromium' }],
					},
					benchmark: {
						include: ['src/**/*.browser.benchmark.ts', 'src/**/*.browser.benchmark.tsx'],
					},
					include: ['src/**/*.browser.benchmark.ts', 'src/**/*.browser.benchmark.tsx'],
					exclude: ['**/node_modules/**', '**/dist/**'],
					sequence: {
						shuffle: false,
					},
				},
			},
		],
	},
});
