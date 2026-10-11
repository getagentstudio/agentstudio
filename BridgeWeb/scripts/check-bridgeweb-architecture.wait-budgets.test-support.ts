import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { dirname } from 'node:path';

import { expect, test } from 'vitest';

import {
	checkBridgeWebArchitecture,
	type ArchitectureViolation,
} from './check-bridgeweb-architecture.ts';

// Fixtures resolve the same installed 1.61.0 declaration file as the real
// package. They never execute Playwright or the planted source snippets.
const require = createRequire(import.meta.url);
const playwrightRequire = createRequire(require.resolve('playwright'));
const playwrightTypes = join(
	dirname(playwrightRequire.resolve('playwright-core')),
	'types/types.d.ts',
);

export function registerWaitBudgetArchitectureFixtures(): void {
	test('V3 budgets use constant computed keys', async (): Promise<void> => {
		const violations = await inspectFixture({
			'tests/e2e/waits.e2e.test.ts': `
				import type { Locator, Page } from 'playwright';
				declare const locator: Locator, page: Page;
				const timeoutKey = 'timeout'; const intervalKey = 'interval';
				locator.click({ [timeoutKey]: 1000 });
				expect.poll(() => true, { [intervalKey]: 10 });
				page.evaluate((data) => data.timeout, { [timeoutKey]: 1000 });
				locator.click({});
			`,
		});
		expect(violations.map((site): string => site.ruleId)).toEqual([
			'no-playwright-timeout-options',
			'no-vitest-wait-options',
		]);
	});

	test('V3 budgets assigned to options before a call retain payload and unbounded negatives', async (): Promise<void> => {
		const violations = await inspectFixture({
			'tests/e2e/waits.e2e.test.ts': `
				import type { Locator, Page } from 'playwright';
				declare const locator: Locator, page: Page;
				const options: Parameters<Locator['click']>[0] = {};
				options.timeout = 1000;
				locator.click(options);
				page.evaluate((data) => data.timeout, options);
				const unbounded: Parameters<Locator['click']>[0] = {};
				locator.click(unbounded);
				unbounded.timeout = 1000;
				const pollOptions: { interval?: number } = {};
				pollOptions.interval = 10;
				expect.poll(() => true, pollOptions);
			`,
		});
		expect(violations.map((site): string => site.ruleId)).toEqual([
			'no-playwright-timeout-options',
			'no-vitest-wait-options',
		]);
	});

	test('V4 Vitest aliases namespaces and destructured waits preserve provenance', async (): Promise<void> => {
		const violations = await inspectFixture({
			'src/waits.unit.test.ts': `
				import { vi, expect } from 'vitest';
				import * as v from 'vitest';
				const tools = vi; tools.waitFor(() => true);
				const checkCondition = expect; checkCondition.poll(() => true, { timeout: 1 });
				v.vi.waitUntil(() => true);
				v.expect.element(null, { interval: 1 });
				const { waitUntil } = vi; waitUntil(() => true);
				const { waitFor: awaitCondition } = v.vi; awaitCondition(() => true, 5000);
				const { poll } = expect; poll(() => true, { timeout: 1 });
			`,
		});
		expect(
			violations.filter((site): boolean => site.ruleId === 'no-vitest-wait-calls'),
		).toHaveLength(4);
		expect(
			violations.filter((site): boolean => site.ruleId === 'no-vitest-wait-options'),
		).toHaveLength(4);
	});

	test('V4 unrelated vi and imports are not Vitest wait APIs', async (): Promise<void> => {
		const violations = await inspectFixture({
			'src/waits.unit.test.ts': `
				import { expect as otherExpect } from './unrelated.ts';
				const vi = { waitFor: (fn) => fn(), waitUntil: (fn) => fn() };
				vi.waitFor(() => true, { timeout: 1 });
				const tools = vi; tools.waitUntil(() => true);
				const { waitUntil } = vi; waitUntil(() => true);
				otherExpect.poll(() => true, { timeout: 1 });
			`,
			'src/unrelated.ts': `export const expect = { poll: (fn) => fn() };`,
		});
		expect(violations).toEqual([]);
	});

	test('no-vitest-wait-options catches every named wait API and indirect budgets', async (): Promise<void> => {
		const forbidden = [
			'expect.poll(() => true, { timeout: 1 })',
			'expect.poll(() => true, { interval: 1 })',
			'expect.element(null, { timeout: 1 })',
			'expect.element(null, { interval: 1 })',
			'vi.waitFor(() => true, { timeout: 1 })',
			'vi.waitUntil(() => true, { interval: 1 })',
			'vi.waitFor(() => true, 5000)',
			'vi.waitUntil(() => true, 5000)',
			'vi.waitFor(() => true, numericBudget)',
			'expect.poll(() => true, budgetOptions)',
			'expect.element(null, { ...budgetOptions })',
		];
		const violations = await inspectFixture({
			'src/waits.unit.test.ts': `const budgetOptions = { timeout: 1 }; const numericBudget = 5000;\n${forbidden.join(';\n')};`,
		});
		expect(
			violations.filter((site): boolean => site.ruleId === 'no-vitest-wait-options'),
		).toHaveLength(forbidden.length);
	});

	test('no-vitest-wait-calls reports both calls without options', async (): Promise<void> => {
		const violations = await inspectFixture({
			'src/waits.unit.test.ts': `import { vi as tools } from 'vitest'; vi.waitFor(() => true); tools.waitUntil(() => true);`,
		});
		expect(violations.map((site): string => site.ruleId)).toEqual([
			'no-vitest-wait-calls',
			'no-vitest-wait-calls',
		]);
	});

	test('no-playwright-timeout-options separates payloads from API options and unrelated receivers', async (): Promise<void> => {
		const violations = await inspectFixture({
			'tests/e2e/waits.e2e.test.ts': `
				import { chromium, type Page, type Frame, type Locator, type ElementHandle } from 'playwright';
				declare const page: Page, frame: Frame, locator: Locator, element: ElementHandle;
				const options = { timeout: 1 };
				page.waitForFunction((data) => data.timeout, { timeout: 2 }, { timeout: 3 });
				frame.waitForFunction((data) => data.timeout, { timeout: 2 }, options);
				page.evaluate((data) => data.timeout, { timeout: 4 });
				page.evaluateHandle((data) => data.timeout, { timeout: 4 });
				locator.evaluateAll((elements, data) => data.timeout, { timeout: 4 });
				locator.evaluate((element, data) => data.timeout, { timeout: 4 }, options);
				locator.evaluate((element) => element.id, { timeout: 4 });
				locator.evaluate<string>((element) => element.id, { timeout: 4 });
				locator.check({ ...options }); locator.clear(options);
				locator.setChecked(true, { timeout: 5 }); locator.boundingBox({ timeout: 1 ?? 2 });
				page.setChecked('input', true, options);
				locator.blur(options); locator.pressSequentially('text', options); locator.selectText(options);
				element.waitForElementState('visible', options); page.screenshot(options);
				page.dragAndDrop('#from', '#to', options); chromium.launch(options);
				page.selectOption('select', { timeout: 4 });
				locator.selectOption({ timeout: 4 });
				const unrelated = { click: (data: { timeout: number }) => data.timeout };
				unrelated.click({ timeout: 1 });
			`,
		});
		expect(
			violations.filter((site): boolean => site.ruleId === 'no-playwright-timeout-options'),
		).toHaveLength(15);
	});

	test('wait-budget rules accept unbounded conditions and exclude non-test production code', async (): Promise<void> => {
		const violations = await inspectFixture({
			'vite.config.ts': `import './src/product.ts';`,
			'src/product.ts': `expect.poll(() => true, { timeout: 1 }); vi.waitFor(() => true);`,
			'src/waits.unit.test.ts': `import './product.ts'; expect.poll(() => true); expect.element(null, { message: 'ready' });`,
			'src/unreachable.ts': `vi.waitUntil(() => true);`,
			'tests/e2e/waits.e2e.test.ts': `
				import type { Page, Locator } from 'playwright'; declare const page: Page, locator: Locator;
				page.waitForFunction((data) => data.timeout, { timeout: 4 });
				locator.check(); page.goto('about:blank', { waitUntil: 'load' });
			`,
		});
		expect(violations).toEqual([]);
	});

	test('wait-budget reconciliation owns its separate ledger and shrinks independently', async (): Promise<void> => {
		const files = {
			'src/waits.unit.test.ts': `vi.waitFor(() => true);`,
			'architecture-debt-ledger-wait-budgets.tsv':
				'rule_id\tpath\tcount\nno-vitest-wait-calls\tBridgeWeb/src/waits.unit.test.ts\t1\n',
		};
		expect(await inspectFixture(files)).toEqual([]);
		const paidOff = await inspectFixture({ ...files, 'src/waits.unit.test.ts': 'export {};' });
		expect(paidOff).toHaveLength(1);
		expect(paidOff[0]?.message).toContain('none remain; remove the row');
	});
}

async function inspectFixture(
	files: Readonly<Record<string, string>>,
): Promise<readonly ArchitectureViolation[]> {
	const packageRootPath = await mkdtemp(join(tmpdir(), 'bridgeweb-wait-budgets-'));
	const packageFiles = {
		'tsconfig.json': JSON.stringify({
			compilerOptions: {
				module: 'NodeNext',
				moduleResolution: 'NodeNext',
				noEmit: true,
				paths: {
					playwright: [playwrightTypes],
					vitest: [join(dirname(require.resolve('vitest/package.json')), 'dist/index.d.ts')],
				},
				types: [join(dirname(require.resolve('vitest/package.json')), 'globals.d.ts')],
			},
		}),
		'vitest.config.ts': `export default { test: { include: ['src/**/*.unit.test.ts'] } };`,
		'vitest.e2e.config.ts': `export default { test: { include: ['tests/e2e/**/*.e2e.test.ts'] } };`,
		...files,
	};
	try {
		await Promise.all(
			Object.entries(packageFiles).map(async ([relativePath, content]): Promise<void> => {
				const filePath = join(packageRootPath, relativePath);
				await mkdir(join(filePath, '..'), { recursive: true });
				await writeFile(filePath, content, 'utf8');
			}),
		);
		return (await checkBridgeWebArchitecture({ packageRootPath })).violations;
	} finally {
		await rm(packageRootPath, { force: true, recursive: true });
	}
}
