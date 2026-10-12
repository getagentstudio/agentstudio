import { basename, join } from 'node:path';

import { loadDebtLedger, reconcileDebtLedger } from './check-bridgeweb-architecture-debt-ledger.ts';
import type { ArchitectureViolation } from './check-bridgeweb-architecture.ts';

interface LintedArchitectureFile {
	readonly relativePath: string;
}

export async function reconcileArchitectureLedgers(props: {
	readonly packageRootPath: string;
	readonly parsedSourceFiles: readonly LintedArchitectureFile[];
	readonly repositoryPathPrefix: string;
	readonly standardSites: readonly ArchitectureViolation[];
	readonly waitBudgetSites: readonly ArchitectureViolation[];
	readonly isLedgerRuleId: (value: string) => value is ArchitectureViolation['ruleId'];
}): Promise<readonly ArchitectureViolation[]> {
	const standardLedgerPath = 'architecture-debt-ledger.tsv';
	const waitBudgetLedgerPath = 'architecture-debt-ledger-wait-budgets.tsv';
	const [standardLedger, waitBudgetLedger] = await Promise.all([
		loadDebtLedger({
			filePath: join(props.packageRootPath, standardLedgerPath),
			isLedgerRuleId: (value): value is ArchitectureViolation['ruleId'] =>
				props.isLedgerRuleId(value) && value === 'no-timed-wait-in-tests',
			sourcePath: `${props.repositoryPathPrefix}${standardLedgerPath}`,
		}),
		loadDebtLedger({
			filePath: join(props.packageRootPath, waitBudgetLedgerPath),
			isLedgerRuleId: (value): value is ArchitectureViolation['ruleId'] =>
				props.isLedgerRuleId(value) && value !== 'no-timed-wait-in-tests',
			sourcePath: `${props.repositoryPathPrefix}${waitBudgetLedgerPath}`,
		}),
	]);
	const lintedPaths = new Set(props.parsedSourceFiles.map((file): string => file.relativePath));
	const reconcile = (
		ledger: Awaited<typeof standardLedger>,
		sites: readonly ArchitectureViolation[],
	): readonly ArchitectureViolation[] =>
		reconcileDebtLedger(
			{
				ledger,
				lintedPaths,
				repositoryPathPrefix: props.repositoryPathPrefix,
				sites,
			},
			(entry, message): ArchitectureViolation => ({
				column: 1,
				line: entry.line,
				message,
				relativePath: basename(ledger.sourcePath),
				ruleId: entry.ruleId,
			}),
		);
	return [
		...reconcile(standardLedger, props.standardSites),
		...reconcile(waitBudgetLedger, props.waitBudgetSites),
	];
}
