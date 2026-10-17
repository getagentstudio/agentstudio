import { act, useRef, useState, type ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	BridgeViewerContextPanelProvider,
	BridgeViewerContextPanelViewport,
} from '../app/bridge-viewer-context-panel-host.js';
import { BridgeViewerContextPanel } from '../app/bridge-viewer-context-panel.js';
import { Alert } from '../components/ui/alert.js';
import { Drawer } from '../components/ui/drawer.js';
import {
	WorktreeAnnotationShareModeRow,
	WorktreeAnnotationShareTrigger,
	type WorktreeAnnotationShareScope,
} from './worktree-annotation-share-mode.js';

describe('worktree annotation Annotations presentation', () => {
	test('renders ordinary Share body content before History', async () => {
		const rendered = await render(
			<Drawer>
				<div className="h-[240px] w-[320px]">
					<WorktreeAnnotationShareModeRow
						error={null}
						history={<div data-testid="share-history">History content</div>}
						isOutputPending={false}
						membership={{ allCount: 1, kind: 'ready', pendingCount: 1 }}
						onCopy={vi.fn()}
						onDone={vi.fn()}
						onExport={vi.fn()}
						onScopeChange={vi.fn()}
						scope="pending"
						{...{
							children: (
								<div className="h-[360px]" data-testid="share-preview-body">
									Preview content
								</div>
							),
						}}
					/>
				</div>
			</Drawer>,
		);

		const previewBody = rendered.getByTestId('share-preview-body').element();
		const history = rendered.getByTestId('share-history').element();
		expect(
			previewBody.compareDocumentPosition(history) & Node.DOCUMENT_POSITION_FOLLOWING,
		).not.toBe(0);
		const shareMode = rendered.getByRole('region', { name: 'Annotations' }).element();
		const body = shareMode.querySelector<HTMLElement>('.overflow-y-auto');
		const footer = shareMode.querySelector<HTMLElement>('[data-slot="drawer-footer"]');
		if (body === null || footer === null) throw new Error('Expected a scrollable body and footer.');
		expect(body.scrollHeight).toBeGreaterThan(body.clientHeight);
		expect(Math.round(body.getBoundingClientRect().bottom)).toBeLessThanOrEqual(
			Math.round(footer.getBoundingClientRect().top),
		);
		expect(footer.getBoundingClientRect().bottom).toBeLessThanOrEqual(
			shareMode.getBoundingClientRect().bottom,
		);
	});

	test('uses the owned action surface without a route-local color', async () => {
		const rendered = await render(
			<Drawer>
				<div>
					<Alert data-testid="loading-status-surface">Loading comparison…</Alert>
					<WorktreeAnnotationShareModeRow
						error={null}
						history={null}
						isOutputPending={false}
						membership={{ allCount: 11, kind: 'ready', pendingCount: 4 }}
						onCopy={vi.fn()}
						onDone={vi.fn()}
						onExport={vi.fn()}
						onScopeChange={vi.fn()}
						scope="pending"
					/>
				</div>
			</Drawer>,
		);

		const loadingSurface = rendered.getByTestId('loading-status-surface').element();
		const shareSurface = rendered.getByRole('region', { name: 'Annotations' }).element();
		expect(getComputedStyle(shareSurface).backgroundColor).toBe('rgba(0, 0, 0, 0)');
		expect(getComputedStyle(loadingSurface).backgroundColor).not.toBe('rgba(0, 0, 0, 0)');
	});

	test('shows saved export actions and routes folder choices through the owned menu', async () => {
		const onChangeFolder = vi.fn();
		const onExportTo = vi.fn<(scope: WorktreeAnnotationShareScope) => void>();
		const onReveal = vi.fn();
		const rendered = await render(
			<Drawer>
				<WorktreeAnnotationShareModeRow
					error="The export folder no longer exists."
					errorCanChooseFolder
					history={null}
					isOutputPending={false}
					membership={{ allCount: 1, kind: 'ready', pendingCount: 1 }}
					onChangeFolder={onChangeFolder}
					onCopy={vi.fn()}
					onDone={vi.fn()}
					onExport={vi.fn()}
					onExportTo={onExportTo}
					onReveal={onReveal}
					onScopeChange={vi.fn()}
					savedFilename="AgentStudio Review Comments 2026-09-29.json"
					scope="all"
				/>
			</Drawer>,
		);

		await expect.element(rendered.getByRole('status')).toHaveTextContent('Saved to AgentStudio');
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Reveal in Finder' }).click(),
		);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Choose folder…' }).click(),
		);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Export options' }).click(),
		);
		await performBrowserAction(() =>
			rendered.getByRole('menuitem', { name: 'Export to…' }).click(),
		);
		expect(onReveal).toHaveBeenCalledOnce();
		expect(onChangeFolder).toHaveBeenCalledOnce();
		expect(onExportTo).toHaveBeenCalledWith('all');
		await page.screenshot({
			element: rendered.getByRole('region', { name: 'Annotations' }).element(),
			path: '../../../tmp/bridgeweb-n9-export-drawer.png',
		});
	});

	test('opens one floating Pending/All shelf without selection UI', async () => {
		const onCopy = vi.fn<(scope: WorktreeAnnotationShareScope) => void>();
		const onExport = vi.fn<(scope: WorktreeAnnotationShareScope) => void>();
		const rendered = await render(<ShareModeFixture onCopy={onCopy} onExport={onExport} />);
		const shareTrigger = rendered.getByRole('button', { name: 'Annotations', exact: true });
		expect(shareTrigger.element().textContent).toBe('Annotations');
		expect(shareTrigger.element().querySelector('.lucide-messages-square')).not.toBeNull();
		expect(shareTrigger.element().classList).toContain('border-border');
		expect(shareTrigger.element().getAttribute('data-slot')).toBe('drawer-trigger');
		expect(shareTrigger.element().getAttribute('data-tooltip')).toBe('Annotations');
		expect(shareTrigger.element().getBoundingClientRect().width).toBeGreaterThan(80);
		expect(shareTrigger.element().getBoundingClientRect().height).toBe(24);

		await performBrowserAction(() => shareTrigger.click());
		const shareMode = rendered.getByRole('region', { name: 'Annotations' });
		await expect.element(shareMode).toBeVisible();
		expect(shareMode.element().textContent).toContain('Annotations');
		expect(shareMode.element().textContent).not.toContain('Share annotations');
		expect(shareMode.element().textContent).toContain('Copy');
		expect(shareMode.element().textContent).not.toContain('Copy Markdown');
		expect(shareMode.element().textContent).toContain('Export');
		expect(shareMode.element().textContent).not.toContain('Export JSON');
		expect(shareMode.element().querySelector('.lucide-share-2')).toBeNull();
		expect(shareMode.element().querySelector('.lucide-copy')).not.toBeNull();
		expect(
			rendered.getByRole('button', { name: 'Export JSON' }).element().querySelector('svg'),
		).not.toBeNull();
		expect(shareMode.element().querySelector('.lucide-x')).not.toBeNull();
		await expect.element(rendered.getByRole('button', { name: 'Close Annotations' })).toBeVisible();
		await expect
			.element(rendered.getByRole('button', { name: 'Pending comments, 4' }))
			.toHaveAttribute('aria-pressed', 'true');
		await expect
			.element(rendered.getByRole('button', { name: 'Pending comments, 4' }))
			.toHaveFocus();
		await expect.element(rendered.getByRole('button', { name: 'All comments, 11' })).toBeVisible();
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeEnabled();
		await expect.element(rendered.getByRole('button', { name: 'Export JSON' })).toBeEnabled();
		const copyButton = rendered.getByRole('button', { name: 'Copy Markdown' }).element();
		const exportButton = rendered.getByRole('button', { name: 'Export JSON' }).element();
		const copyBounds = copyButton.getBoundingClientRect();
		const exportBounds = exportButton.getBoundingClientRect();
		const header = shareMode.element().querySelector('[data-slot="drawer-header"]');
		const footer = shareMode.element().querySelector('[data-slot="drawer-footer"]');
		const titleIcon = header?.querySelector('svg');
		if (header === null || footer === null || titleIcon === undefined || titleIcon === null) {
			throw new Error('Expected the shared drawer frame and title icon.');
		}
		expect(getComputedStyle(header).padding).toBe('8px');
		expect(getComputedStyle(footer).padding).toBe('8px');
		const body = header.nextElementSibling;
		if (body === null) throw new Error('Expected the drawer body after its header.');
		expect(getComputedStyle(body).padding).toBe('8px');
		const title = rendered.getByRole('heading', { name: 'Annotations' }).element();
		expect(getComputedStyle(title).fontSize).toBe('14px');
		expect(getComputedStyle(title).lineHeight).toBe('20px');
		expect(titleIcon.closest('button')).not.toBeNull();
		expect(titleIcon.getBoundingClientRect().width).toBe(12);
		for (const name of ['Pending comments, 4', 'All comments, 11']) {
			const segment = rendered.getByRole('button', { name }).element();
			const icon = segment.querySelector('svg');
			if (icon === null) throw new Error('Expected matching outline icons for both scopes.');
			expect(segment.getBoundingClientRect().height).toBe(20);
			expect(icon.getBoundingClientRect().width).toBe(12);
			expect(getComputedStyle(segment).columnGap).toBe('4px');
		}
		expect(Math.round(copyBounds.height)).toBe(24);
		expect(Math.round(exportBounds.height)).toBe(24);
		expect(Math.round(copyBounds.top)).toBe(Math.round(exportBounds.top));
		expect(Math.round(exportBounds.left - copyBounds.right)).toBe(8);
		expect(getComputedStyle(copyButton).backgroundColor).toBe(
			getComputedStyle(exportButton).backgroundColor,
		);
		expect(getComputedStyle(copyButton).borderColor).toBe(
			getComputedStyle(exportButton).borderColor,
		);
		expect(document.querySelector('[data-slot="drawer-popup"]')).toBe(
			rendered.getByTestId('worktree-annotation-share-shelf').element(),
		);
		expect(document.querySelector('[role="checkbox"]')).toBeNull();
		expect(shareMode.element().querySelector('[data-slot="scroll-area"]')).toBeNull();
		expect(shareMode.element().textContent).not.toContain('selected');
		await page.screenshot({
			element: shareMode.element(),
			path: '../../../tmp/bridgeweb-worktree-annotation-share-mode.png',
		});

		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'All comments, 11' }).click(),
		);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Copy Markdown' }).click(),
		);
		await performBrowserAction(() => rendered.getByRole('button', { name: 'Export JSON' }).click());

		expect(onCopy).toHaveBeenCalledWith('all');
		expect(onExport).toHaveBeenCalledWith('all');
	});

	test('disables empty output and closes with Done or Escape without an effect', async () => {
		const onCopy = vi.fn<(scope: WorktreeAnnotationShareScope) => void>();
		const onExport = vi.fn<(scope: WorktreeAnnotationShareScope) => void>();
		const rendered = await render(
			<ShareModeFixture allCount={0} pendingCount={0} onCopy={onCopy} onExport={onExport} />,
		);

		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Annotations', exact: true }).element());
		});
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeDisabled();
		await expect.element(rendered.getByRole('button', { name: 'Export JSON' })).toBeDisabled();
		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Close Annotations' }).element());
		});
		await expect
			.element(rendered.getByRole('region', { name: 'Annotations' }))
			.not.toBeInTheDocument();

		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Annotations', exact: true }).element());
		});
		const shareMode = rendered.getByRole('region', { name: 'Annotations' });
		await performBrowserAction(async (): Promise<void> => {
			rendered
				.getByRole('button', { name: 'Pending comments, 0' })
				.element()
				.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }));
		});
		await expect.element(shareMode).not.toBeInTheDocument();
		expect(onCopy).not.toHaveBeenCalled();
		expect(onExport).not.toHaveBeenCalled();
	});

	test('retains failure feedback inside the viewer-local right drawer', async () => {
		const rendered = await render(
			<div className="w-[420px]">
				<ShareModeFixture error="Export failed. No comments were handled." />
			</div>,
		);

		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await expect
			.element(rendered.getByRole('alert'))
			.toHaveTextContent('Export failed. No comments were handled.');
		expect(
			rendered.getByTestId('worktree-annotation-share-shelf').element().getBoundingClientRect()
				.width,
		).toBeCloseTo(Math.min(480, 420 - 32), 0);
	});
});

function ShareModeFixture(props: {
	readonly allCount?: number;
	readonly error?: string | null;
	readonly pendingCount?: number;
	readonly onCopy?: (scope: WorktreeAnnotationShareScope) => void;
	readonly onExport?: (scope: WorktreeAnnotationShareScope) => void;
}): ReactElement {
	const [isOpen, setIsOpen] = useState(false);
	const [scope, setScope] = useState<WorktreeAnnotationShareScope>('pending');
	const triggerRef = useRef<HTMLButtonElement | null>(null);
	return (
		<BridgeViewerContextPanelProvider>
			<div className="grid h-[500px] w-[420px] grid-rows-[auto_minmax(0,1fr)]">
				<Drawer onOpenChange={setIsOpen} open={isOpen} modal={false} swipeDirection="right">
					<div data-bridge-viewer-content-topbar="true">
						<WorktreeAnnotationShareTrigger buttonRef={triggerRef} disabled={false} open={isOpen} />
					</div>
					<BridgeViewerContextPanelViewport testId="share-mode-context-panel-viewport">
						<div className="h-full" />
					</BridgeViewerContextPanelViewport>
					<BridgeViewerContextPanel
						ariaLabel="Annotations"
						width="wide"
						finalFocus={triggerRef}
						height="half"
						testId="worktree-annotation-share-shelf"
					>
						<WorktreeAnnotationShareModeRow
							error={props.error ?? null}
							history={null}
							isOutputPending={false}
							membership={{
								allCount: props.allCount ?? 11,
								kind: 'ready',
								pendingCount: props.pendingCount ?? 4,
							}}
							onCopy={(selectedScope) => props.onCopy?.(selectedScope)}
							onDone={() => setIsOpen(false)}
							onExport={(selectedScope) => props.onExport?.(selectedScope)}
							onScopeChange={setScope}
							scope={scope}
						/>
					</BridgeViewerContextPanel>
				</Drawer>
			</div>
		</BridgeViewerContextPanelProvider>
	);
}

async function performBrowserAction(action: () => Promise<void> | void): Promise<void> {
	const shelfBeforeAction = document.querySelector<HTMLElement>(
		'[data-testid="worktree-annotation-share-shelf"]',
	);
	const menuBeforeAction = document.querySelector<HTMLElement>(
		'[data-slot="dropdown-menu-content"]',
	);
	await act(async (): Promise<void> => {
		await action();
		await Promise.resolve();
		await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
		await settleClosingShareShelf(shelfBeforeAction);
		await settleClosingDropdownMenu(menuBeforeAction);
	});
}

async function settleClosingDropdownMenu(menu: HTMLElement | null): Promise<void> {
	if (menu === null || !menu.hasAttribute('data-closed')) return;
	await Promise.all(
		menu.getAnimations({ subtree: true }).map(async (animation): Promise<void> => {
			try {
				await animation.finished;
			} catch {
				// A closing menu can replace its preceding animation.
			}
		}),
	);
}

async function settleClosingShareShelf(shelf: HTMLElement | null): Promise<void> {
	if (shelf === null || !shelf.hasAttribute('data-ending-style')) return;
	await Promise.all(
		shelf.getAnimations({ subtree: true }).map(async (animation): Promise<void> => {
			try {
				await animation.finished;
			} catch {
				// Reversing an in-flight transition cancels its predecessor.
			}
		}),
	);
}

function clickHtmlButton(element: HTMLElement | SVGElement): void {
	if (!(element instanceof HTMLButtonElement)) throw new Error('Expected an HTML button.');
	element.click();
}
