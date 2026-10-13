import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import { describe, expect, onTestFinished, test } from 'vitest';

import type { StyleSystemReport } from './check-bridgeweb-style-system-model.ts';
import { checkBridgeWebStyleSystem } from './check-bridgeweb-style-system.ts';

const canonicalCss = `
:root {
	/* @design-primitives:start */
	--palette-canvas: #282c34;
	/* @design-primitives:end */
	--background: var(--palette-canvas);
}
@layer base { button, input, textarea { font: inherit; } }
`;

const canonicalMirror = `
export const bridgeDesignPalette = {
	'--palette-canvas': '#282c34',
} as const satisfies Readonly<Record<\`--palette-\${string}\`, string>>;
`;

describe('BridgeWeb style-system embedded CSS policy', () => {
	test('preserves named-color fallback tokens while ignoring custom-property identifiers', async () => {
		const report = await checkFixture({
			'src/app/fallbacks.css': `
				.safe { color: var(--status-red); }
				.unsafe { color: var(--foreground, red); }
			`,
		});

		expect(rulePaths(report, 'raw-color')).toEqual(['src/app/fallbacks.css']);
	});

	test('analyzes imported unsafeCSS control recipes and fails unresolved consumed CSS closed', async () => {
		const report = await checkFixture({
			'src/app/shared-css.ts': `export const sharedCss = 'button { padding: 12px; }';`,
			'src/app/options.ts': `
				import { sharedCss } from './shared-css.js';
				export const imported = { unsafeCSS: sharedCss };
				export const unresolved = (recipe: string) => ({ unsafeCSS: recipe });
			`,
		});

		expect(rulePaths(report, 'control-style-override')).toEqual(['src/app/options.ts']);
		expect(rulePaths(report, 'evaluation-failure')).toEqual(['src/app/options.ts']);
	});

	test('classifies tab and option roles and fails computed spread keys closed', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/computed-controls.tsx': `
				import { Button } from '../components/ui/button.js';
				const propertyName = 'className';
				type ComputedProps = { [propertyName]?: string };
				export const Roles = () => <><div role="tab" className="h-9" /><div role={'option'} className="bg-primary" /></>;
				export const StaticSpread = () => <Button {...{ [propertyName]: 'h-9' }} />;
				export const TypedSpread = (props: ComputedProps) => <Button {...props} />;
			`,
		});

		expect(rulePaths(report, 'control-style-override')).toHaveLength(2);
		expect(rulePaths(report, 'unknown-control-classes')).toHaveLength(2);
	});

	test('maps embedded CSS findings to the unsafeCSS property and retains embedded coordinates', async () => {
		const report = await checkFixture({
			'src/app/located-options.ts': `
				export const options = {
					name: 'located',
					unsafeCSS: \`
						.panel { display: block; }
						button { padding: 12px; }
					\`,
				};
			`,
		});
		const finding = report.findings.find(({ ruleId }) => ruleId === 'control-style-override');

		expect(finding).toEqual(
			expect.objectContaining({ line: 4, message: expect.stringContaining('embedded CSS 3:16') }),
		);
	});

	test('classifies every CSS role-based control selector', async () => {
		const report = await checkFixture({
			'src/app/role-controls.css': `
				[role='tab'] { padding: 12px; }
				[role='option'] { padding: 12px; }
				[role='checkbox'] { padding: 12px; }
				[role='radio'] { padding: 12px; }
				[role='switch'] { padding: 12px; }
				[role='menuitemcheckbox'] { padding: 12px; }
				[role='menuitemradio'] { padding: 12px; }
			`,
		});

		expect(rulePaths(report, 'control-style-override')).toHaveLength(7);
	});

	test('rejects helper-returned appearance and palette class literals without matching prose', async () => {
		const report = await checkFixture({
			'src/app/helper-classes.ts': `
				export function appearanceClassName(): string { return 'dark:bg-background'; }
				export function paletteClassName(): string { return 'hover:text-red-500'; }
				export const ordinaryDescription = 'Keep the dark appearance stable.';
			`,
		});

		expect(rulePaths(report, 'appearance-conditional')).toEqual(['src/app/helper-classes.ts']);
		expect(rulePaths(report, 'raw-color')).toEqual(['src/app/helper-classes.ts']);
	});

	test('checks literal-valued template interpolations while suppressing only template-owned fragments', async () => {
		const report = await checkFixture({
			'src/app/interpolated-classes.ts': `
				export const appearance = \`prefix \${'dark:bg-background'} suffix\`;
			`,
		});

		expect(rulePaths(report, 'appearance-conditional')).toEqual([
			'src/app/interpolated-classes.ts',
		]);
	});
});

async function checkFixture(files: Readonly<Record<string, string>>): Promise<StyleSystemReport> {
	const packageRootPath = await mkdtemp(join(tmpdir(), 'bridge-style-policy-'));
	onTestFinished(async (): Promise<void> => {
		await rm(packageRootPath, { recursive: true, force: true });
	});
	await Promise.all(
		Object.entries({
			'src/app/bridge-app.css': canonicalCss,
			'src/design-tokens/bridge-design-palette.ts': canonicalMirror,
			...files,
		}).map(async ([relativePath, sourceText]) => {
			const filePath = join(packageRootPath, relativePath);
			await mkdir(dirname(filePath), { recursive: true });
			await writeFile(filePath, sourceText);
		}),
	);
	return checkBridgeWebStyleSystem({ packageRootPath });
}

function rulePaths(
	report: Awaited<ReturnType<typeof checkBridgeWebStyleSystem>>,
	ruleId: string,
): readonly string[] {
	return report.findings
		.filter((finding) => finding.ruleId === ruleId)
		.map(({ relativePath }) => relativePath);
}
