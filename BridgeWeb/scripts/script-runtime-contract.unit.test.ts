import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, test } from 'vitest';

const packageRootPath = new URL('../', import.meta.url);

describe('script runtime contract', () => {
	test('keeps BridgeWeb scripts in TypeScript', async () => {
		const scriptFileNames = await readScriptFileNames(new URL('scripts/', packageRootPath));
		const scriptExtensions = scriptFileNames
			.filter((fileName: string): boolean => !fileName.endsWith('.unit.test.ts'))
			.map((fileName: string): string => fileName.slice(fileName.lastIndexOf('.')))
			.toSorted();

		expect(scriptExtensions.every((extension: string): boolean => extension === '.ts')).toBe(true);
	});

	test('runs TypeScript scripts through Node type stripping', async () => {
		const scripts = await readPackageScripts();

		expect(scripts['build']).toBe('node --experimental-strip-types scripts/build-app.ts');
		expect(scripts['audit:assets']).toBe(
			'node --experimental-strip-types scripts/audit-dependencies-and-assets.ts',
		);
		expect(scripts['check']).toContain(
			'node --experimental-strip-types scripts/check-bridgeweb-architecture.ts',
		);
		expect(scripts['benchmark:viewer']).toBe('vitest --config vitest.benchmark.config.ts run');
	});

	test('bounds Go execution only at the type-aware lint owner', async () => {
		const scripts = await readPackageScripts();

		expect(scripts['lint:types']).toBe('GOMAXPROCS=1 oxlint --type-aware');
		expect(scripts['lint']).toBe('oxlint');
		expect(
			Object.entries(scripts)
				.filter(([, command]): boolean => command.includes('oxlint --type-aware'))
				.map(([scriptName]): string => scriptName),
		).toEqual(['lint:types']);
	});

	test('aggregate checks route through the bounded type-aware lint owner', async () => {
		const scripts = await readPackageScripts();

		expect(scripts['check']?.split(' && ')[0]).toBe('pnpm run lint:types');
	});

	test('keeps the required stress E2E isolated from ordinary product journeys', async () => {
		// Arrange
		const scripts = await readPackageScripts();

		// Act
		const preparedE2E = scripts['test:e2e:prepared'];
		const ordinaryE2E = scripts['test:e2e:prepared:ordinary'];
		const stressE2E = scripts['test:e2e:prepared:stress'];

		// Assert
		expect(scripts['test:e2e']).toBe(
			'pnpm run build:swift-dev-server && pnpm run test:e2e:prepared',
		);
		expect(preparedE2E).toBe(
			'pnpm run test:e2e:prepared:stress && pnpm run test:e2e:prepared:ordinary',
		);
		expect(stressE2E).toContain('bridge-viewer-vite-annotation-backpressure.e2e.test.ts');
		expect(ordinaryE2E).toContain(
			'--exclude tests/e2e/bridge-viewer-vite-annotation-backpressure.e2e.test.ts',
		);
	});

	test('loads the Bridge app Tailwind stylesheet from the WebKit entrypoint', async () => {
		const bootstrapSource = await readFile(
			new URL('src/app/bridge-app-bootstrap.tsx', packageRootPath),
			'utf8',
		);

		expect(bootstrapSource).toContain("import './bridge-app.css';");
	});
});

async function readScriptFileNames(directoryUrl: URL): Promise<readonly string[]> {
	const entries = await readdir(directoryUrl, { withFileTypes: true });
	const fileNames: string[] = [];

	const childDirectoryFileNameGroups = await Promise.all(
		entries
			.filter((entry): boolean => entry.isDirectory())
			.map(async (entry): Promise<readonly string[]> => {
				const childFileNames = await readScriptFileNames(new URL(`${entry.name}/`, directoryUrl));
				return childFileNames.map(
					(childFileName: string): string => `${entry.name}/${childFileName}`,
				);
			}),
	);

	for (const entry of entries) {
		if (!entry.isDirectory()) {
			fileNames.push(entry.name);
		}
	}
	for (const childFileNameGroup of childDirectoryFileNameGroups) {
		fileNames.push(...childFileNameGroup);
	}

	return fileNames;
}

async function readPackageScripts(): Promise<Record<string, string>> {
	const packageJson: unknown = JSON.parse(
		await readFile(join(fileURLToPath(packageRootPath), 'package.json'), 'utf8'),
	);

	if (!isRecord(packageJson) || !isStringRecord(packageJson['scripts'])) {
		throw new Error('package.json scripts must be a string record');
	}

	return packageJson['scripts'];
}

function isStringRecord(value: unknown): value is Record<string, string> {
	if (!isRecord(value)) {
		return false;
	}

	return Object.values(value).every((entry: unknown): boolean => typeof entry === 'string');
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
