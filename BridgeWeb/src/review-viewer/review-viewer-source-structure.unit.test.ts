import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, test } from 'vitest';

import {
	bridgeReviewNavigationTargetForCommand,
	resolveBridgeReviewNavigationTarget,
} from '../app/bridge-app-review-navigation-controller.js';
import {
	commitBridgeReviewPresentationSelection,
	scheduleReviewMarkFileViewedCommand,
} from '../app/bridge-app-review-selection-controller.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';

const recoveredReviewSourcePaths = [
	'../app/bridge-app-review-navigation-controller.ts',
	'../app/bridge-app-review-selection-controller.ts',
	'../app/bridge-app-review-viewer-shell-boundary.tsx',
] as const;

const forbiddenRecoveredAuthorityTokens = [
	'bridge-app-review-controller',
	'bridge-viewer-mocked-backend',
	'review-viewer/state/review-viewer-store',
	'review-viewer/workers/projection',
	'review-viewer/workers/shared-rpc',
	'use-review-projection-coordinator',
	'zustand',
] as const;

describe('Review viewer S1a recovery source structure', () => {
	test('S1a restores the Review presentation boundary and local controllers', () => {
		const missingSourcePaths = recoveredReviewSourcePaths.filter(
			(relativePath): boolean => !sourceFileExists(relativePath),
		);

		expect(
			missingSourcePaths,
			'S1A REVIEW RECOVERY MISSING: restore the presentation boundary and local controllers without obsolete authority.',
		).toEqual([]);
	});

	test('recovered Review presentation files cannot import obsolete authority', () => {
		const violations = recoveredReviewSourcePaths.flatMap((relativePath): readonly string[] => {
			const source = readOptionalSource(relativePath).toLowerCase();
			return forbiddenRecoveredAuthorityTokens
				.filter((token): boolean => source.includes(token))
				.map((token): string => `${relativePath}: ${token}`);
		});

		expect(violations).toEqual([]);
	});

	test('keeps Review main-thread production sources off direct Zustand subscriptions', () => {
		const forbiddenTokens = [
			"from 'zustand",
			'from "zustand',
			'useStore(',
			'useStoreWithEqualityFn(',
			'createStore(',
			'createWithEqualityFn(',
			'subscribeWithSelector',
		] as const;
		const violations = readReviewMainThreadProductionSources().flatMap((entry): readonly string[] =>
			forbiddenTokens
				.filter((token): boolean => entry.source.includes(token))
				.map((token): string => `${entry.relativePath}: ${token}`),
		);

		expect(violations).toEqual([]);
	});

	test('keeps the recovered shell presentation boundary lazily mounted', () => {
		const boundarySource = readOptionalSource('../app/bridge-app-review-viewer-shell-boundary.tsx');

		expect(boundarySource).toContain('BridgeReviewViewerPresentationState');
		expect(boundarySource).toContain('ReviewViewerShellProps');
		expect(boundarySource).toContain('LazyReviewViewerShell');
		expect(boundarySource).toContain('<Suspense');
		expect(boundarySource).not.toContain('BridgeReviewPackage');
		expect(boundarySource).not.toContain('BridgeMainRenderSnapshotStore');
		expect(boundarySource).not.toContain('fetch(');
	});

	test('keeps typed local selection before post-paint worker intent scheduling', () => {
		const selectionSource = readOptionalSource('../app/bridge-app-review-selection-controller.ts');
		const selectionCommitSource = sourceBetween(
			selectionSource,
			'export function commitBridgeReviewPresentationSelection',
			'export function scheduleReviewMarkFileViewedCommand',
		);

		expect(selectionCommitSource).toContain('commitLocalSelection(props.itemId)');
		expect(selectionCommitSource).toContain(
			'scheduleSelectIntentAfterLocalPaint(props.itemId, props.selectedSource)',
		);
		expect(selectionCommitSource.indexOf('commitLocalSelection(props.itemId)')).toBeLessThan(
			selectionCommitSource.indexOf(
				'scheduleSelectIntentAfterLocalPaint(props.itemId, props.selectedSource)',
			),
		);
		expect(selectionSource).toContain('selectIntentScheduler.cancelPending()');
		expect(selectionSource).toContain('useLayoutEffect(');
	});

	test('keeps navigation idempotence and projection reconciliation local', () => {
		const navigationSource = readOptionalSource(
			'../app/bridge-app-review-navigation-controller.ts',
		);

		expect(navigationSource).toContain('consumedNavigationCommandIdsRef');
		expect(navigationSource).toContain('notifyUserSelection');
		expect(navigationSource).toContain('resolveBridgeReviewNavigationTarget');
		expect(navigationSource).toContain('onTargetOutsideAcceptedProjection');
		expect(navigationSource).toContain('orderedItemIds[0]');
		expect(navigationSource).not.toContain('BridgeReviewPackage');
	});

	test('has no direct page-event path for Review selection', () => {
		const controlListenerSource = readOptionalSource(
			'../app/use-bridge-review-control-event-listeners.ts',
		);

		expect(controlListenerSource).not.toContain('__bridge_select_review_item');
	});

	test('resolves explicit Review navigation only inside the accepted projection', () => {
		const navigationCommand = reviewNavigationCommand('review-item-two');
		const acceptedResolution = resolveBridgeReviewNavigationTarget({
			getReviewItem: (): undefined => undefined,
			navigationCommand,
			orderedItemIds: ['review-item-one', 'review-item-two'],
		});
		const outsideResolution = resolveBridgeReviewNavigationTarget({
			getReviewItem: (): undefined => undefined,
			navigationCommand,
			orderedItemIds: ['review-item-one'],
		});

		expect(acceptedResolution).toMatchObject({
			itemId: 'review-item-two',
			status: 'accepted',
		});
		expect(outsideResolution).toMatchObject({
			status: 'outsideAcceptedProjection',
			target: { itemId: 'review-item-two' },
		});
		expect(bridgeReviewNavigationTargetForCommand(navigationCommand)).toMatchObject({
			commandId: navigationCommand.commandId,
			itemId: 'review-item-two',
		});
	});

	test('commits local Review selection before scheduling the typed worker intent', () => {
		const calls: string[] = [];
		const accepted = commitBridgeReviewPresentationSelection({
			commitLocalSelection: (itemId): void => {
				calls.push(`local:${itemId}`);
			},
			currentSelectedItemId: null,
			hasReviewItem: (): boolean => true,
			isActive: true,
			itemId: 'review-item-two',
			scheduleSelectIntentAfterLocalPaint: (itemId, selectedSource): void => {
				calls.push(`scheduled-intent:${itemId}:${selectedSource}`);
			},
			selectedSource: 'keyboard',
		});

		expect(accepted).toBe(true);
		expect(calls).toEqual(['local:review-item-two', 'scheduled-intent:review-item-two:keyboard']);
	});

	test('defers mark-viewed intent and reports delivery refusal', async () => {
		const markedItemIds: string[] = [];
		let deliveryFailureCount = 0;
		scheduleReviewMarkFileViewedCommand({
			itemId: 'review-item-two',
			markFileViewed: (itemId): false => {
				markedItemIds.push(itemId);
				return false;
			},
			onDeliveryFailure: (): void => {
				deliveryFailureCount += 1;
			},
		});

		expect(markedItemIds).toEqual([]);
		await Promise.resolve();
		expect(markedItemIds).toEqual(['review-item-two']);
		expect(deliveryFailureCount).toBe(1);
	});

	test('mounts exactly one recovered Review shell at the S1b/J1 cutover', () => {
		const modeSource = readSource('../app/bridge-app-review-viewer-mode.tsx');

		expect(modeSource).toContain('BridgeReviewViewerShellBoundary');
		expect(modeSource).toContain('bridgeReviewPresentationSnapshotForDisplay');
		expect(modeSource).not.toContain('BridgeReviewDirectViewerShell');
		expect(modeSource.match(/<BridgeReviewViewerShellBoundary/gu)).toHaveLength(1);
	});

	test('keeps Pierre imports out of Review mode and presentation-boundary surfaces', () => {
		const forbiddenPierreOwners = [
			'../app/bridge-app-review-viewer-mode.tsx',
			'../app/bridge-app-review-viewer-shell-boundary.tsx',
			'./shell/review-viewer-shell.tsx',
		].filter((relativePath): boolean => readSource(relativePath).includes('@pierre/'));

		expect(forbiddenPierreOwners).toEqual([]);
	});

	test('keeps Review consumers off Pierre immediate render re-entry', () => {
		const violations = readReviewMainThreadProductionSources()
			.filter((entry): boolean => entry.source.includes('.render(true)'))
			.map((entry): string => entry.relativePath);

		expect(violations).toEqual([]);
	});

	test('keeps streamed metadata append from mutating local tree disclosure', () => {
		const treePanelSource = readSource('./trees/bridge-trees-panel.tsx');

		expect(treePanelSource).not.toContain("updatePlan?.kind === 'appendOnly'");
		expect(treePanelSource).not.toContain('revealAppendedPathAncestors');
	});

	test('keeps Review TypeScript and TSX files under one thousand lines', () => {
		const oversizedSources = readReviewViewerSourceFiles()
			.filter((entry): boolean => entry.lineCount > 1000)
			.map((entry): string => `${entry.relativePath}: ${entry.lineCount}`);

		expect(oversizedSources).toEqual([]);
	});
});

function readSource(relativePath: string): string {
	return readFileSync(fileURLToPath(new URL(relativePath, import.meta.url)), 'utf8');
}

function readOptionalSource(relativePath: string): string {
	return sourceFileExists(relativePath) ? readSource(relativePath) : '';
}

function sourceFileExists(relativePath: string): boolean {
	return existsSync(fileURLToPath(new URL(relativePath, import.meta.url)));
}

function readReviewMainThreadProductionSources(): readonly {
	readonly relativePath: string;
	readonly source: string;
}[] {
	const appRootPath = fileURLToPath(new URL('../app/', import.meta.url));
	const reviewRootPath = fileURLToPath(new URL('./', import.meta.url));
	const appSources = readSourceTextEntries(appRootPath, '../app').filter(
		(entry): boolean =>
			entry.relativePath.startsWith('../app/bridge-app-review-') ||
			entry.relativePath.startsWith('../app/use-bridge-review-'),
	);
	const reviewSources = readSourceTextEntries(reviewRootPath, '.').filter((entry): boolean =>
		isReviewViewerMainThreadProductionSource(entry.relativePath),
	);
	return [...appSources, ...reviewSources];
}

function isReviewViewerMainThreadProductionSource(relativePath: string): boolean {
	return (
		!relativePath.includes('.test.') &&
		!relativePath.startsWith('test-support/') &&
		!relativePath.startsWith('workers/')
	);
}

function readReviewViewerSourceFiles(): readonly {
	readonly lineCount: number;
	readonly relativePath: string;
}[] {
	return readSourceEntries(fileURLToPath(new URL('./', import.meta.url)), '');
}

function readSourceEntries(
	absoluteDirectoryPath: string,
	relativeDirectoryPath: string,
): readonly { readonly lineCount: number; readonly relativePath: string }[] {
	return readdirSync(absoluteDirectoryPath, { withFileTypes: true }).flatMap((entry) => {
		const relativePath = join(relativeDirectoryPath, entry.name);
		const absolutePath = join(absoluteDirectoryPath, entry.name);
		if (entry.isDirectory()) {
			return readSourceEntries(absolutePath, relativePath);
		}
		if (!entry.isFile() || (!entry.name.endsWith('.ts') && !entry.name.endsWith('.tsx'))) {
			return [];
		}
		return [
			{
				lineCount: readFileSync(absolutePath, 'utf8').split('\n').length,
				relativePath,
			},
		];
	});
}

function readSourceTextEntries(
	absoluteDirectoryPath: string,
	relativeDirectoryPath: string,
): readonly { readonly relativePath: string; readonly source: string }[] {
	return readdirSync(absoluteDirectoryPath, { withFileTypes: true }).flatMap((entry) => {
		const relativePath = join(relativeDirectoryPath, entry.name);
		const absolutePath = join(absoluteDirectoryPath, entry.name);
		if (entry.isDirectory()) {
			return readSourceTextEntries(absolutePath, relativePath);
		}
		if (!entry.isFile() || (!entry.name.endsWith('.ts') && !entry.name.endsWith('.tsx'))) {
			return [];
		}
		return [{ relativePath, source: readFileSync(absolutePath, 'utf8') }];
	});
}

function sourceBetween(source: string, startToken: string, endToken: string): string {
	const startIndex = source.indexOf(startToken);
	const endIndex = source.indexOf(endToken, Math.max(0, startIndex));
	return startIndex < 0 || endIndex < 0 ? '' : source.slice(startIndex, endIndex);
}

function reviewNavigationCommand(
	reviewItemId: string,
): Extract<
	BridgeProductNavigationCommand,
	{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
> {
	return {
		bindingRevision: 1,
		commandId: 'review-navigation-command',
		commandKind: 'activateTarget',
		source: {
			generation: 1,
			metadataSourceId: 'review-fixture',
			packageId: 'review-package',
			sourceKind: 'review',
		},
		surface: 'review',
		target: {
			reviewItemId,
			targetKind: 'review',
		},
	};
}
