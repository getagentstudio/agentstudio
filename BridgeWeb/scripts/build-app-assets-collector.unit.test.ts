import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, onTestFinished, test } from 'vitest';

import { collectBuiltBundleAssets } from './build-app-assets-collector.ts';

describe('BridgeWeb app asset collector', () => {
	test('selects the app entrypoint while preserving auxiliary Shiki chunks', async () => {
		const tempDirectory = await createAssetFixtureDirectory();
		const assetsDirectoryPath = join(tempDirectory, 'assets');
		await mkdir(assetsDirectoryPath, { recursive: true });
		await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./swift-abc.js";\n');
		await writeFile(join(assetsDirectoryPath, 'swift-abc.js'), 'export const lang = "swift";\n');
		await writeFile(
			join(assetsDirectoryPath, 'github-dark-abc.js'),
			'export const theme = "dark";\n',
		);
		await writeFile(join(assetsDirectoryPath, 'bridge-app.css'), ':root { color: white; }\n');

		const assets = await collectBuiltBundleAssets({
			appDirectoryPath: tempDirectory,
			assetsDirectoryPath,
			entrypointName: 'bridge-app',
		});

		expect(assets.mainScript).toBe('assets/bridge-app.js');
		expect(assets.auxiliaryScripts).toEqual(['assets/github-dark-abc.js', 'assets/swift-abc.js']);
		expect(assets.styles).toEqual(['assets/bridge-app.css']);
	});

	test('rejects chunks that still import runtime packages by name', async () => {
		const tempDirectory = await createAssetFixtureDirectory();
		const assetsDirectoryPath = join(tempDirectory, 'assets');
		await mkdir(assetsDirectoryPath, { recursive: true });
		await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./bad-chunk.js";\n');
		await writeFile(
			join(assetsDirectoryPath, 'bad-chunk.js'),
			'import { CodeView } from "@pierre/diffs";\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).rejects.toThrow(/runtime packages/);
	});

	test('rejects any unresolved bare module import in packaged app chunks', async () => {
		await Promise.all(
			[
				'import "@shikijs/core";\n',
				'import DOMPurify from "dompurify";\n',
				'export { Button } from "@base-ui/react/button";\n',
				'void import("lucide-react");\n',
			].map(async (badImportSource): Promise<void> => {
				const tempDirectory = await createAssetFixtureDirectory();
				const assetsDirectoryPath = join(tempDirectory, 'assets');
				await mkdir(assetsDirectoryPath, { recursive: true });
				await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./bad-chunk.js";\n');
				await writeFile(join(assetsDirectoryPath, 'bad-chunk.js'), badImportSource);

				await expect(
					collectBuiltBundleAssets({
						appDirectoryPath: tempDirectory,
						assetsDirectoryPath,
						entrypointName: 'bridge-app',
					}),
				).rejects.toThrow(/runtime packages/);
			}),
		);
	});

	test('rejects chunks with external dynamic imports or worker URLs', async () => {
		const tempDirectory = await createAssetFixtureDirectory();
		const assetsDirectoryPath = join(tempDirectory, 'assets');
		await mkdir(assetsDirectoryPath, { recursive: true });
		await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./bad-chunk.js";\n');
		await writeFile(
			join(assetsDirectoryPath, 'bad-chunk.js'),
			'void import("https://example.invalid/module.js");\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).rejects.toThrow(/external runtime import/);

		await writeFile(
			join(assetsDirectoryPath, 'bad-chunk.js'),
			'const worker = new Worker("https://example.invalid/worker.js");\nvoid worker;\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).rejects.toThrow(/external runtime import/);

		await writeFile(
			join(assetsDirectoryPath, 'bad-chunk.js'),
			'const workerUrl = "https://example.invalid/worker.js";\nconst worker = new Worker(workerUrl);\nvoid worker;\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).rejects.toThrow(/external runtime import/);
	});

	test('allows blob-backed worker variables created inside packaged app chunks', async () => {
		const tempDirectory = await createAssetFixtureDirectory();
		const assetsDirectoryPath = join(tempDirectory, 'assets');
		await mkdir(assetsDirectoryPath, { recursive: true });
		await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./worker-chunk.js";\n');
		await writeFile(
			join(assetsDirectoryPath, 'worker-chunk.js'),
			'let workerUrl = null;\nworkerUrl = URL.createObjectURL(new Blob([""]));\nconst worker = new Worker(workerUrl, { type: "module" });\nvoid worker;\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).resolves.toEqual({
			mainScript: 'assets/bridge-app.js',
			auxiliaryScripts: ['assets/worker-chunk.js'],
			styles: [],
		});
	});

	test('allows intentional Catppuccin Mocha theme metadata in packaged app chunks', async () => {
		const tempDirectory = await createAssetFixtureDirectory();
		const assetsDirectoryPath = join(tempDirectory, 'assets');
		await mkdir(assetsDirectoryPath, { recursive: true });
		await writeFile(join(assetsDirectoryPath, 'bridge-app.js'), 'import "./theme.js";\n');
		await writeFile(
			join(assetsDirectoryPath, 'theme.js'),
			'export const themeName = "catppuccin-mocha";\n',
		);

		await expect(
			collectBuiltBundleAssets({
				appDirectoryPath: tempDirectory,
				assetsDirectoryPath,
				entrypointName: 'bridge-app',
			}),
		).resolves.toEqual({
			mainScript: 'assets/bridge-app.js',
			auxiliaryScripts: ['assets/theme.js'],
			styles: [],
		});
	});
});

async function createAssetFixtureDirectory(): Promise<string> {
	const tempDirectory = await mkdtemp(join(tmpdir(), 'bridge-built-assets-'));
	onTestFinished(async (): Promise<void> => {
		await rm(tempDirectory, { recursive: true, force: true });
	});
	return tempDirectory;
}
