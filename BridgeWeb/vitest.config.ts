import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

import { reactActWarningGuardScope } from './tests/console-error-guard-scope.ts';
import {
	unitHookTimeoutMilliseconds,
	unitTestTimeoutMilliseconds,
} from './tests/vitest-hang-bounds.ts';

const bridgeWebPackageRoot = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
	plugins: [react()],
	resolve: {
		alias: {
			'@': `${bridgeWebPackageRoot}/src`,
		},
	},
	test: {
		environment: 'node',
		globals: true,
		include: [
			'scripts/**/*.unit.test.ts',
			'src/**/*.unit.test.ts',
			'src/**/*.unit.test.tsx',
			'tests/**/*.unit.test.ts',
		],
		provide: reactActWarningGuardScope,
		setupFiles: ['./tests/console-error-guard.ts'],
		testTimeout: unitTestTimeoutMilliseconds,
		hookTimeout: unitHookTimeoutMilliseconds,
		exclude: ['**/node_modules/**', '**/dist/**'],
	},
});
