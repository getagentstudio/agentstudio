import { act, type ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { BridgePaneFailureSummarySlot } from '../app/bridge-pane-failure-summary-slot.js';
import {
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import { WorktreeAnnotationOutputHistoryControl } from './worktree-annotation-output-history-control.js';
import { WorktreeAnnotationRecoveryNotice } from './worktree-annotation-recovery-notice.js';
import type { WorktreeAnnotationOutputHistorySummary } from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationProjection,
	WorktreeAnnotationSurfaceProvider,
} from './worktree-annotation-surface-provider.js';

describe('worktree annotation recovery and rail history controls', () => {
	test('shows one Comments Retry for a failed annotation view and keeps the last good projection', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		surface.client.renderStore.applyViewRecoveryStatusEvent({
			wireVersion: 1,
			direction: 'serverWorkerToMain',
			transferDescriptors: [],
			kind: 'viewRecoveryStatus',
			view: { kind: 'file.annotations', subscriptionId: 'file-comments-retry-1' },
			status: 'failedRetryable',
		});
		const rendered = await render(<RecoveryAndHistoryFixture surface={surface} />);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				revision: 1,
				sessions: [annotationSessionSummary({ revision: 1, sessionId: annotationSessionId })],
			});
			await Promise.resolve();
		});

		await expect.element(rendered.getByText("Comments couldn't load.")).toBeVisible();
		await expect
			.element(rendered.getByText(`Last good comments: ${annotationSessionId}`))
			.toBeVisible();
		expect(document.querySelectorAll('button[aria-label="Retry"]')).toHaveLength(1);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Retry' }).click();
		});
		await expect
			.element(rendered.getByText(`Last good comments: ${annotationSessionId}`))
			.toBeVisible();
		expect(surface.sentRecoveryCommands.map((command) => command.command)).toEqual([
			'viewRecoveryRetry',
			'annotationProjectionRetry',
		]);
		await page.screenshot({ path: '../../../tmp/bridgeweb-comments-view-retry.png' });
	});

	test('shows a compact recovered-degraded warning and acknowledges through the strict operation', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await render(<RecoveryAndHistoryFixture surface={surface} />);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				recoveryStatus: 'recovered_degraded',
				revision: 1,
				sessions: [],
			});
			await Promise.resolve();
		});

		await expect
			.element(rendered.getByText('Comments recovered with missing local history'))
			.toBeVisible();
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Acknowledge' }).click();
			await settleInteraction();
		});

		expect(surface.sentOperations.findLast((): boolean => true)).toEqual({
			kind: 'recovery.acknowledge',
		});
	});

	test('blocks duplicate unhandle clicks and shows pending and committed feedback', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<RecoveryAndHistoryFixture surface={surface} />);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				outputHistory: [outputHistorySummary()],
				revision: 2,
				sessions: [annotationSessionSummary({ revision: 2, sessionId: annotationSessionId })],
			});
			await settleInteraction();
		});
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'History (1)' }).click();
			await settleInteraction();
		});
		const unhandle = rendered.getByRole('button', { name: 'Mark as not handled' }).element();
		await act(async (): Promise<void> => {
			clickHtmlButton(unhandle);
			clickHtmlButton(unhandle);
			await settleInteraction();
		});
		expect(
			surface.sentOperations.filter((operation) => operation.kind === 'output.handled.clear'),
		).toHaveLength(1);
		await expect.element(unhandle).toBeDisabled();
		await expect.element(unhandle).toHaveTextContent('Updating…');
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted();
			await settleInteraction();
		});
		await expect
			.element(rendered.getByText('Annotations marked as not handled.', { exact: true }))
			.toBeVisible();
		await expect.element(unhandle).toBeEnabled();
	});

	test('keeps inspection failure in its card and allows retry', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<RecoveryAndHistoryFixture surface={surface} />);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				outputHistory: [outputHistorySummary()],
				revision: 2,
				sessions: [annotationSessionSummary({ revision: 2, sessionId: annotationSessionId })],
			});
			await settleInteraction();
		});
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'History (1)' }).click();
			await settleInteraction();
		});
		const send = vi.spyOn(surface.client, 'send');
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Inspect output attempt 1' }).click();
			await settleInteraction();
		});
		const request = send.mock.results.at(-1);
		if (request?.type !== 'return') throw new Error('Expected an inspection worker request');
		await act(async (): Promise<void> => {
			surface.publishHealth(request.value, 'degraded');
			await settleInteraction();
		});
		await expect.element(rendered.getByRole('alert')).toBeVisible();
		await expect
			.element(rendered.getByRole('button', { name: 'Inspect output attempt 1' }))
			.toBeEnabled();
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Inspect output attempt 1' }).click();
			await settleInteraction();
			surface.settleMostRecentInspection({
				attemptId: outputHistorySummary().attemptId,
				content: 'Saved output after retry',
				outputKind: 'clipboard_markdown',
			});
			await settleInteraction();
		});
		await expect
			.element(rendered.getByText('Saved output after retry', { exact: true }))
			.toBeVisible();
		await expect.element(rendered.getByRole('alert')).not.toBeInTheDocument();
		send.mockRestore();
	});

	test.each([180, 480])(
		'shows durable history with owned hierarchy and actions at %spx',
		async (width) => {
			const surface = new RecordingAnnotationBrowserSurface('review');
			const rendered = await render(<RecoveryAndHistoryFixture surface={surface} width={width} />);
			await act(async (): Promise<void> => {
				surface.publishProjectionState({ expectedThreadCount: 0, revision: 1, sessions: [] });
				await Promise.resolve();
			});
			await expect
				.element(rendered.getByRole('button', { name: 'History (1)' }))
				.not.toBeInTheDocument();

			await act(async (): Promise<void> => {
				surface.publishProjectionState({
					expectedThreadCount: 0,
					outputHistory: [outputHistorySummary()],
					revision: 2,
					sessions: [annotationSessionSummary({ revision: 2, sessionId: annotationSessionId })],
				});
				await Promise.resolve();
			});
			expect(rendered.getByTestId('annotation-output-history-entry').all()).toHaveLength(0);
			expect(
				getComputedStyle(rendered.getByRole('button', { name: 'History (1)' }).element()).fontSize,
			).toBe('13px');
			await expect.element(rendered.getByRole('heading', { name: 'History (1)' })).toBeVisible();
			await act(async (): Promise<void> => {
				clickHtmlButton(rendered.getByRole('button', { name: 'History (1)' }).element());
				await Promise.resolve();
			});
			const historyPanel = document.querySelector<HTMLElement>('[data-slot="collapsible-content"]');
			if (historyPanel === null) throw new Error('Expected the expanded History panel.');
			await settleCollapsibleMotion(historyPanel);
			await expect.element(rendered.getByText('Clipboard Markdown', { exact: true })).toBeVisible();
			expect(document.body.textContent).not.toContain('Inspect or repeat exact durable output.');
			const historySection = document.querySelector<HTMLElement>('[aria-label="Output history"]');
			if (historySection === null) throw new Error('Expected the History section.');
			expect(historySection.classList).not.toContain('border-t');
			const historyEntry = rendered.getByTestId('annotation-output-history-entry').element();
			expect(historyEntry.getAttribute('data-slot')).toBe('card');
			expect(historyEntry.classList).toContain('bg-card');
			expect(historyEntry.classList).toContain('border-border');
			expect(historyEntry.classList).toContain('rounded-lg');
			const title = rendered.getByText('Clipboard Markdown', { exact: true }).element();
			expect(historyEntry.getAttribute('aria-labelledby')).toBe(title.id);
			const time = document.querySelector<HTMLTimeElement>(
				'time[datetime="2026-08-17T10:00:00.000Z"]',
			);
			if (time === null) throw new Error('Expected the native output attempt time.');
			const outcome = rendered.getByText('Copied', { exact: true }).element();
			expect(time.parentElement?.nextElementSibling?.contains(outcome)).toBe(true);
			expect(getComputedStyle(title).fontSize).toBe('13px');
			await expect.element(rendered.getByText('1 annotation', { exact: true })).toBeVisible();
			expect(getComputedStyle(time).fontSize).toBe('12px');
			const footer = historyEntry.querySelector<HTMLElement>('[data-slot="card-footer"]');
			if (footer === null) throw new Error('Expected owned Card footer actions.');
			expect(getComputedStyle(footer).flexWrap).toBe('wrap');
			expect(getComputedStyle(footer).gap).toBe('8px');
			const inspectButton = rendered
				.getByRole('button', { name: 'Inspect output attempt 1' })
				.element();
			const markNotHandledButton = rendered
				.getByRole('button', {
					name: 'Mark as not handled',
				})
				.element();
			if (width === 180) {
				expect(markNotHandledButton.getBoundingClientRect().top).toBeGreaterThanOrEqual(
					inspectButton.getBoundingClientRect().bottom,
				);
			} else {
				expect(markNotHandledButton.getBoundingClientRect().top).toBe(
					inspectButton.getBoundingClientRect().top,
				);
			}
			await page.screenshot({
				element: historyEntry,
				path: `../../../tmp/bridgeweb-worktree-annotation-history-card-${width}.png`,
			});
			await expect
				.element(rendered.getByRole('button', { name: 'Repeat output attempt 1' }))
				.not.toBeInTheDocument();
			expect(document.querySelector('[data-slot="popover-content"]')).toBeNull();
			await act(async (): Promise<void> => {
				await rendered.getByRole('button', { name: 'Inspect output attempt 1' }).click();
				await settleInteraction();
			});
			expect(surface.sentOutputInspectionAttemptIds).toEqual([
				'00000000-0000-7000-8000-000000000071',
			]);
			await act(async (): Promise<void> => {
				surface.settleMostRecentInspection({
					attemptId: '00000000-0000-7000-8000-000000000071',
					content: '# Exact saved output',
					outputKind: 'clipboard_markdown',
				});
				await settleInteraction();
			});
			await expect.element(rendered.getByText('# Exact saved output')).toBeVisible();
			expect(document.body.textContent).not.toContain('Root annotation');
			expect(document.body.textContent).not.toContain('Thread 1');

			await act(async (): Promise<void> => {
				surface.publishProjectionState({
					expectedThreadCount: 0,
					outputHistory: [outputHistorySummary({ canMarkNotHandled: false, state: 'unknown' })],
					revision: 3,
					sessions: [annotationSessionSummary({ revision: 3, sessionId: annotationSessionId })],
				});
				await Promise.resolve();
			});
			await expect
				.element(rendered.getByRole('button', { name: 'Repeat output attempt 1' }))
				.toBeVisible();
		},
	);
});

function RecoveryAndHistoryFixture(props: {
	readonly surface: RecordingAnnotationBrowserSurface;
	readonly width?: number;
}): ReactElement {
	return (
		<div style={{ width: props.width ?? 180 }}>
			<WorktreeAnnotationSurfaceProvider surfaceClient={props.surface.client}>
				<LastGoodCommentsProbe />
				<BridgePaneFailureSummarySlot entries={[]} />
				<WorktreeAnnotationRecoveryNotice />
				<WorktreeAnnotationOutputHistoryControl />
			</WorktreeAnnotationSurfaceProvider>
		</div>
	);
}

function LastGoodCommentsProbe(): ReactElement {
	const projection = useWorktreeAnnotationProjection();
	const sessionId = projection.sessions[0]?.sessionId ?? 'none';
	return <output data-testid="last-good-comments">{`Last good comments: ${sessionId}`}</output>;
}

async function settleInteraction(): Promise<void> {
	await Promise.resolve();
	await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
	await Promise.resolve();
}

function clickHtmlButton(element: HTMLElement | SVGElement): void {
	if (!(element instanceof HTMLButtonElement)) throw new Error('Expected an HTML button.');
	element.click();
}

async function settleCollapsibleMotion(panel: HTMLElement): Promise<void> {
	await settleBrowserCondition(
		(): boolean => !panel.hasAttribute('data-starting-style'),
		'Expected History expansion motion to settle.',
	);
	await act(async (): Promise<void> => {
		await Promise.all(
			panel.getAnimations({ subtree: true }).map((animation) => animation.finished),
		);
		await Promise.resolve();
	});
}

async function settleBrowserCondition(
	predicate: () => boolean,
	failureMessage: string,
	remainingFrames = 10,
): Promise<void> {
	if (predicate()) return;
	if (remainingFrames <= 0) throw new Error(failureMessage);
	await act(async (): Promise<void> => {
		await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
		await Promise.resolve();
	});
	await settleBrowserCondition(predicate, failureMessage, remainingFrames - 1);
}

function outputHistorySummary(
	props: {
		readonly canMarkNotHandled?: boolean;
		readonly state?: WorktreeAnnotationOutputHistorySummary['state'];
	} = {},
): WorktreeAnnotationOutputHistorySummary {
	return {
		attemptId: '00000000-0000-7000-8000-000000000071',
		canMarkNotHandled: props.canMarkNotHandled ?? true,
		createdAt: Date.UTC(2026, 7, 17, 10),
		messageCount: 1,
		outputKind: 'clipboard_markdown',
		repeatedFromAttemptId: null,
		sessionId: annotationSessionId,
		state: props.state ?? 'succeeded',
		updatedAt: Date.UTC(2026, 7, 17, 10),
	};
}
