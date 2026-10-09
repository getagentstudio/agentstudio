import { execFile } from 'node:child_process';
import { mkdtemp, rm, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

import { expect, test } from 'vitest';

import { readExpectedReviewItemIds } from './product-only-real-router-regression.ts';

const execFileAsync = promisify(execFile);

test('Review oracle counts an untracked rename as the one native Git item', async () => {
	const worktreeRoot = await mkdtemp(join(tmpdir(), 'bridge-review-rename-oracle-'));
	const oldPath = join(worktreeRoot, 'view-credit-window.ts');
	const newPath = join(worktreeRoot, 'credit-window.ts');
	try {
		await git(worktreeRoot, ['init', '--quiet']);
		await git(worktreeRoot, ['config', 'user.name', 'Bridge test']);
		await git(worktreeRoot, ['config', 'user.email', 'bridge-test@example.invalid']);
		await git(worktreeRoot, ['config', 'commit.gpgsign', 'false']);
		const sharedLines = Array.from(
			{ length: 24 },
			(_, index): string => `export const sharedCreditRule${index} = ${index};`,
		).join('\n');
		await writeFile(oldPath, `${sharedLines}\nexport const formerRule = true;\n`);
		await git(worktreeRoot, ['add', '--', 'view-credit-window.ts']);
		await git(worktreeRoot, ['commit', '--quiet', '-m', 'base']);
		await unlink(oldPath);
		await writeFile(newPath, `${sharedLines}\nexport const currentRule = true;\n`);

		const itemIds = await readExpectedReviewItemIds({ reviewBase: 'HEAD', worktreeRoot });

		expect(itemIds).toHaveLength(1);
		expect(itemIds[0]).toMatch(/^item-/u);
	} finally {
		await rm(worktreeRoot, { recursive: true, force: true });
	}
});

async function git(worktreeRoot: string, arguments_: readonly string[]): Promise<void> {
	await execFileAsync('git', arguments_, { cwd: worktreeRoot });
}
