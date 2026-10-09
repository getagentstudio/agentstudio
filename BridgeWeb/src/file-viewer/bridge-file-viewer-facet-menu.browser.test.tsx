import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load the app CSS.
import '../app/bridge-app.css';
import { settleFileViewerMenuTransition } from './bridge-file-viewer-app-startup.browser.test-support.js';
import { actFrame } from './bridge-file-viewer-browser-test-harness.js';
import type { BridgeFileViewerFilterMode } from './bridge-file-viewer-contracts.js';
import { BridgeFileViewerFacetMenu } from './bridge-file-viewer-facet-menu.js';

describe('BridgeFileViewerFacetMenu Browser Mode', () => {
	test('exposes only the accepted exclusive category labels', async () => {
		// Arrange
		const filterModeChanges = vi.fn<(filterMode: BridgeFileViewerFilterMode) => void>();

		await render(
			<BridgeFileViewerFacetMenu
				filterMode="source"
				onFilterModeChange={filterModeChanges}
				onOpenChange={() => undefined}
				open
			/>,
		);

		await actFrame();
		await settleFileViewerMenuTransition();

		// Act
		const categoryRows = findMenuCheckboxItems('File category');

		// Assert
		expect(categoryRows.map(visibleRowLabel)).toEqual([
			'All',
			'Source code',
			'Tests',
			'Documentation',
			'Configuration',
			'Test data',
		]);
		for (const row of categoryRows) {
			expect(row.querySelector('[data-testid$="-option-badge"] svg')).not.toBeNull();
		}
		const categoryBadges = categoryRows.map((row) =>
			requireHTMLElement(row.querySelector('[data-testid$="-option-badge"]')),
		);
		const neutralBadge = categoryBadges[0];
		if (neutralBadge === undefined) throw new Error('All category badge missing');
		for (const badge of categoryBadges) {
			expect(getComputedStyle(badge).color).toBe(getComputedStyle(neutralBadge).color);
			expect(getComputedStyle(badge).backgroundColor).toBe(
				getComputedStyle(neutralBadge).backgroundColor,
			);
		}
		expect(
			categoryRows.map((row: HTMLElement): string | null => row.getAttribute('aria-checked')),
		).toEqual(['false', 'true', 'false', 'false', 'false', 'false']);
		expect(document.body.textContent).not.toContain('Binary');
		expect(document.body.textContent).not.toContain('Large');
		expect(document.body.textContent).not.toContain('Git status');
	});
});

function findMenuCheckboxItems(groupLabel: string): HTMLElement[] {
	const group = document.querySelector(`[role="group"][aria-label="${groupLabel}"]`);
	expect(group).not.toBeNull();
	return [...(group?.querySelectorAll('[role="menuitemcheckbox"]') ?? [])].map(
		(element: Element): HTMLElement => requireHTMLElement(element),
	);
}

function visibleRowLabel(row: HTMLElement): string {
	return row.querySelector('[data-testid$="-option-label"]')?.textContent?.trim() ?? '';
}

function requireHTMLElement(element: Element | null): HTMLElement {
	if (!(element instanceof HTMLElement)) {
		throw new Error('Expected a real Browser Mode element.');
	}
	return element;
}

// Register at the Browser Mode entry; the shared module owns the pure pass-through wrapper.
vi.mock('../components/ui/dropdown-menu.js', async (importOriginal) => {
	const original = await importOriginal<typeof import('../components/ui/dropdown-menu.js')>();
	const { withFileMenuCompletion } =
		await import('./bridge-file-viewer-menu-completion.browser.test-support.js');
	return withFileMenuCompletion(original);
});
