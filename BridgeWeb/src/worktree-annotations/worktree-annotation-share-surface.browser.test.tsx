import { act, createRef, type ReactElement, type Ref } from 'react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { page, userEvent } from 'vitest/browser';

import {
	ViewedCommandTestControl,
	type ViewedCommandTestHandle,
} from './worktree-annotation-viewed-command.test-support.js';

const toastSpies = vi.hoisted(() => ({
	default: vi.fn<(message: string) => void>(),
	error: vi.fn<(message: string) => void>(),
	success: vi.fn<(message: string, options?: unknown) => void>(),
	warning: vi.fn<(message: string) => void>(),
}));
vi.mock('sonner', () => ({
	toast: Object.assign(toastSpies.default, {
		error: toastSpies.error,
		success: toastSpies.success,
		warning: toastSpies.warning,
	}),
}));

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import { BridgeViewerContentHeader } from '../app/bridge-viewer-content-header.js';
import {
	BridgeViewerContextPanelProvider,
	BridgeViewerContextPanelViewport,
} from '../app/bridge-viewer-context-panel-host.js';
import {
	annotationHeadThreadId,
	annotationMessage,
	annotationSecondSessionId,
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import { WorktreeAnnotationShareHeaderControl } from './worktree-annotation-output-controls.js';
import {
	findLastOperation,
	requireShareScopeButton,
	outputHandledClearOperations,
	isToastAction,
	performBrowserAction,
	settleInteraction,
	waitForShareShelfOpeningMotion,
	finishShareShelfMotion,
	requireHtmlElement,
	clickHtmlButton,
	requireHtmlButton,
} from './worktree-annotation-share-browser-test-support.js';
import type {
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationOutputHistorySummary,
	WorktreeAnnotationThreadContext,
} from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationSurfaceClient,
	WorktreeAnnotationSurfaceProvider,
} from './worktree-annotation-surface-provider.js';

const handledMessageId = '00000000-0000-7000-8000-000000000081';
const newMessageId = '00000000-0000-7000-8000-000000000082';
const unavailableMessageId = '00000000-0000-7000-8000-000000000083';
const unavailableThreadId = '00000000-0000-7000-8000-000000000084';
const successfulAttemptId = '00000000-0000-7000-8000-000000000085';

describe('worktree annotation Annotations integrated surface', () => {
	afterEach(async (): Promise<void> => {
		await act(async (): Promise<void> => {
			await cleanup();
			await Promise.resolve();
		});
		toastSpies.default.mockReset();
		toastSpies.error.mockReset();
		toastSpies.success.mockReset();
		toastSpies.warning.mockReset();
	});

	test('opens an inset right drawer over the code canvas without moving it or covering the header', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		const annotationsTrigger = rendered
			.getByRole('button', { name: 'Annotations', exact: true })
			.element();
		expect(annotationsTrigger.textContent).toBe('Annotations');
		expect(annotationsTrigger.classList).toContain('border-border');
		expect(annotationsTrigger.querySelector('svg')).not.toBeNull();
		const header = rendered.getByTestId('bridge-viewer-content-topbar').element();
		const codeCanvas = rendered.getByTestId('share-layout-code-canvas').element();
		const contextPanelViewport = rendered.getByTestId('share-context-panel-viewport').element();
		const codeCanvasTopBeforeOpen = codeCanvas.getBoundingClientRect().top;

		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);

		const shelf = rendered.getByTestId('worktree-annotation-share-shelf').element();
		await waitForShareShelfOpeningMotion(requireHtmlElement(shelf));
		const headerBounds = header.getBoundingClientRect();
		const contextPanelViewportBounds = contextPanelViewport.getBoundingClientRect();
		const shelfBounds = shelf.getBoundingClientRect();
		expect(codeCanvas.getBoundingClientRect().top).toBe(codeCanvasTopBeforeOpen);
		expect(shelfBounds.width).toBeCloseTo(480, 0);
		expect(shelfBounds.top).toBeCloseTo(contextPanelViewportBounds.top + 8, 0);
		expect(contextPanelViewportBounds.right - shelfBounds.right).toBeCloseTo(8, 0);
		expect(shelfBounds.bottom).toBeCloseTo(contextPanelViewportBounds.bottom - 8, 0);
		expect(shelfBounds.height).toBeCloseTo(contextPanelViewportBounds.height - 16, 0);
		expect(shelfBounds.top).toBeGreaterThan(headerBounds.bottom);
		expect(getComputedStyle(shelf).transitionDuration).toBe('0.12s');
		expect(shelf.getAttribute('data-swipe-direction')).toBe('right');
		expect(document.querySelector('[data-slot="drawer-popup"]')).toBe(shelf);
	});

	test('dismisses the shelf on outside press without stealing outside focus', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		const outsideTarget = rendered.getByRole('button', { name: 'Code canvas target' });
		const closingShelf = requireHtmlElement(
			rendered.getByTestId('worktree-annotation-share-shelf').element(),
		);

		await act(async (): Promise<void> => {
			await outsideTarget.click();
			await finishShareShelfMotion(closingShelf);
		});

		await expect
			.element(rendered.getByRole('region', { name: 'Annotations' }))
			.not.toBeInTheDocument();
		expect(document.activeElement).toBe(outsideTarget.element());
	});

	test('presents unknown membership before the first complete projection', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);

		await expect
			.element(rendered.getByRole('button', { name: 'Annotations', exact: true }))
			.toBeEnabled();
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();
		await expect.element(rendered.getByText('Pending —')).toBeVisible();
		await expect.element(rendered.getByText('All —')).toBeVisible();
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeDisabled();
		await expect.element(rendered.getByRole('button', { name: 'Export JSON' })).toBeDisabled();
	});

	test('keeps retained unavailable comments inspectable without granting output authority', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		await act(async (): Promise<void> => {
			surface.publishUnavailable();
			await settleInteraction();
		});

		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await expect.element(rendered.getByText('Last known comments')).toBeVisible();
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'All comments, 3' }).click(),
		);
		await expect
			.element(rendered.getByRole('button', { name: 'All comments, 3' }))
			.toHaveAttribute('aria-pressed', 'true');
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeDisabled();
		await expect.element(rendered.getByRole('button', { name: 'Export JSON' })).toBeDisabled();
	});

	test('disables output only for an active-session command receipt awaiting projection', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		const copyButton = requireHtmlButton(
			rendered.getByRole('button', { name: 'Copy Markdown' }).element(),
		);
		expect(copyButton.disabled).toBe(false);

		await act(async (): Promise<void> => {
			requireHtmlElement(
				rendered.getByTestId('create-unrelated-command-overlay').element(),
			).click();
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommittedWithoutProjection(annotationSecondSessionId, 'root.create');
			await settleInteraction();
		});
		expect(copyButton.disabled).toBe(false);

		await act(async (): Promise<void> => {
			requireHtmlElement(rendered.getByTestId('create-active-command-overlay').element()).click();
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommittedWithoutProjection(annotationSessionId, 'draft.flush');
			await settleInteraction();
		});
		expect(copyButton.disabled).toBe(true);
	});

	test('preserves All membership but disables output until viewed projection convergence', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const viewedControl = createRef<ViewedCommandTestHandle>();
		const rendered = await render(
			<ShareSurfaceFixture viewedControlRef={viewedControl} surface={surface} />,
		);
		const agentMessage = {
			...annotationMessage({ messageId: newMessageId, threadId: annotationHeadThreadId }),
			attentionState: 'new' as const,
			authorKind: 'agent' as const,
			sessionRevision: 3,
		};
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 1,
				revision: 3,
				sessions: [annotationSessionSummary({ revision: 3, sessionId: annotationSessionId })],
			});
			surface.publishThreadMessages({ context: locatedContext, messages: [agentMessage] });
			await settleInteraction();
		});
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'All comments, 1' }).click(),
		);
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeEnabled();

		await waitForShareShelfOpeningMotion(
			requireHtmlElement(rendered.getByTestId('worktree-annotation-share-shelf').element()),
		);
		expect(viewedControl.current).not.toBeNull();
		await performBrowserAction(() => viewedControl.current?.markViewed());
		await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();
		await act(async (): Promise<void> => {
			surface.settleMostRecentViewed(5);
			await settleInteraction();
		});
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeDisabled();
		await expect.element(rendered.getByRole('button', { name: 'Export JSON' })).toBeDisabled();

		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 1,
				revision: 4,
				sessions: [annotationSessionSummary({ revision: 5, sessionId: annotationSessionId })],
			});
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [{ ...agentMessage, attentionState: 'viewed', sessionRevision: 5 }],
			});
			await settleInteraction();
		});
		await expect.element(rendered.getByRole('button', { name: 'Copy Markdown' })).toBeEnabled();
	});

	test.each([
		{ scope: 'pending', outputKind: 'clipboardMarkdown' },
		{ scope: 'all', outputKind: 'clipboardMarkdown' },
		{ scope: 'pending', outputKind: 'jsonFile' },
		{ scope: 'all', outputKind: 'jsonFile' },
	] as const)(
		'sends the displayed $scope batch for $outputKind and keeps Share open on conflict',
		async ({ scope, outputKind }) => {
			const surface = new RecordingAnnotationBrowserSurface('review');
			const rendered = await render(<ShareSurfaceFixture surface={surface} />);
			await publishShareProjection(surface);
			await performBrowserAction(() => {
				clickHtmlButton(
					rendered.getByRole('button', { name: 'Annotations', exact: true }).element(),
				);
			});
			if (scope === 'all')
				await performBrowserAction(() => requireShareScopeButton('All comments').click());
			await performBrowserAction(() => {
				clickHtmlButton(
					rendered
						.getByRole('button', {
							name: outputKind === 'jsonFile' ? 'Export JSON' : 'Copy Markdown',
							exact: true,
						})
						.element(),
				);
			});
			expect(findLastOperation(surface, 'output.scope.commit')).toEqual({
				...(outputKind === 'jsonFile' ? { destination: 'remembered' } : {}),
				kind: 'output.scope.commit',
				messages: [
					...(scope === 'all' ? [{ messageId: handledMessageId, savedRevision: 1 }] : []),
					{ messageId: newMessageId, savedRevision: 1 },
					{ messageId: unavailableMessageId, savedRevision: 1 },
				],
				outputKind,
				scope,
				sessionId: annotationSessionId,
			});
			await performBrowserAction(() => surface.settleMostRecentConflict('output.scope.commit'));
			await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();
			await expect.element(rendered.getByText('conflict', { exact: true })).toBeVisible();
			expect(
				surface.sentOperations.filter(({ kind }) => kind === 'output.scope.commit'),
			).toHaveLength(1);
		},
	);

	test.each(['fileView', 'review'] as const)(
		'uses the %s header entry and exact All scope, then dismisses with reversible success',
		async (surfaceKind) => {
			const surface = new RecordingAnnotationBrowserSurface(surfaceKind);
			const rendered = await render(<ShareSurfaceFixture surface={surface} />);
			await publishShareProjection(surface);

			await expect
				.element(rendered.getByRole('button', { name: 'Annotations', exact: true }))
				.toBeEnabled();
			await performBrowserAction(() => {
				clickHtmlButton(
					rendered.getByRole('button', { name: 'Annotations', exact: true }).element(),
				);
			});
			const pendingScopeButton = requireShareScopeButton('Pending comments');
			expect(pendingScopeButton.getAttribute('aria-label')).toBe('Pending comments, 2');
			expect(pendingScopeButton.getAttribute('aria-pressed')).toBe('true');
			expect(document.querySelector('[aria-label="Other saved comments"]')).toBeNull();
			if (surfaceKind === 'review') {
				const integratedSurface = rendered
					.getByTestId('review-or-file-header')
					.element().parentElement;
				if (integratedSurface === null)
					throw new Error('Expected the integrated Share surface root.');
				await waitForShareShelfOpeningMotion(
					requireHtmlElement(rendered.getByTestId('worktree-annotation-share-shelf').element()),
				);
				await page.screenshot({
					element: integratedSurface,
					path: '../../../tmp/bridgeweb-worktree-annotation-share-integrated.png',
				});
			}

			const allScopeButton = requireShareScopeButton('All comments');
			expect(allScopeButton.getAttribute('aria-label')).toBe('All comments, 3');
			await performBrowserAction(async (): Promise<void> => allScopeButton.click());
			await performBrowserAction(() => {
				clickHtmlButton(rendered.getByRole('button', { name: 'Copy Markdown' }).element());
			});
			expect(findLastOperation(surface, 'output.scope.commit')).toEqual({
				kind: 'output.scope.commit',
				messages: [
					{ messageId: handledMessageId, savedRevision: 1 },
					{ messageId: newMessageId, savedRevision: 1 },
					{ messageId: unavailableMessageId, savedRevision: 1 },
				],
				outputKind: 'clipboardMarkdown',
				scope: 'all',
				sessionId: annotationSessionId,
			});

			const closingShelf = requireHtmlElement(
				rendered.getByTestId('worktree-annotation-share-shelf').element(),
			);
			await act(async (): Promise<void> => {
				surface.settleMostRecentOutput({
					kind: 'succeeded',
					summary: outputSummary('clipboard_markdown', 3),
				});
				await Promise.resolve();
			});
			await act(async (): Promise<void> => finishShareShelfMotion(closingShelf));
			await expect
				.element(rendered.getByRole('region', { name: 'Annotations' }))
				.not.toBeInTheDocument();
			expect(toastSpies.success).toHaveBeenCalledWith(
				'Copied 3 annotations',
				expect.objectContaining({
					action: expect.objectContaining({ label: 'Mark as not handled' }),
				}),
			);
			const toastAction = toastSpies.success.mock.calls.at(-1)?.[1];
			if (!isToastAction(toastAction))
				throw new Error('Expected a reversible success toast action.');
			await act(async (): Promise<void> => {
				toastAction.action.onClick();
				await settleInteraction();
			});
			expect(findLastOperation(surface, 'output.handled.clear')).toEqual({
				attemptId: successfulAttemptId,
				expectedSessionRevision: 4,
				kind: 'output.handled.clear',
			});
		},
	);

	test('previews unavailable saved bodies from the selected Pending collection', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await settleInteraction();

		await expect
			.element(rendered.getByText('Unavailable saved comment', { exact: false }))
			.toBeVisible();
		const unavailableFile = rendered.getByText('Unavailable.swift', { exact: true });
		await expect.element(unavailableFile).toBeVisible();
		expect(unavailableFile.element().getAttribute('title')).toBe('Sources/App/Unavailable.swift');
		expect(rendered.getByText('4–7').all()).toHaveLength(2);
		await expect
			.element(rendered.getByRole('img', { name: 'Source unavailable in this viewer' }))
			.toBeVisible();
		await expect.element(rendered.getByRole('button', { name: 'All comments, 3' })).toBeVisible();
	});

	test('omits resolved Pending bodies and counts, then restores them from canonical reopen', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, false, 'resolved');
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);

		await expect
			.element(rendered.getByRole('button', { name: 'Pending comments, 1' }))
			.toBeVisible();
		expect(document.body.textContent).not.toContain('New saved comment');
		await expect
			.element(rendered.getByText('Unavailable saved comment', { exact: false }))
			.toBeVisible();

		await publishShareProjection(surface, false, 'open');
		await expect
			.element(rendered.getByRole('button', { name: 'Pending comments, 2' }))
			.toBeVisible();
		await expect.element(rendered.getByText('New saved comment')).toBeVisible();
	});

	test('keeps failure and cancellation in Share, but closes partial success with a warning toast', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface);
		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Annotations', exact: true }).element());
		});

		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Export JSON' }).element());
		});
		await act(async (): Promise<void> => {
			surface.settleMostRecentOutput({ kind: 'destination_cancelled' });
			await settleInteraction();
		});
		await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();

		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Export JSON' }).element());
		});
		const closingShelf = requireHtmlElement(
			rendered.getByTestId('worktree-annotation-share-shelf').element(),
		);
		await act(async (): Promise<void> => {
			surface.settleMostRecentOutput({
				effectError: 'write failed',
				kind: 'effect_failed',
				summary: outputSummary('json_file'),
			});
			await Promise.resolve();
			await Promise.resolve();
		});
		await expect.element(rendered.getByRole('alert')).toHaveTextContent('Export failed.');

		await performBrowserAction(() => {
			clickHtmlButton(rendered.getByRole('button', { name: 'Copy Markdown' }).element());
		});
		await act(async (): Promise<void> => {
			surface.settleMostRecentOutput({
				finalizationError: 'history failed',
				kind: 'partial_success',
				summary: outputSummary('clipboard_markdown'),
			});
			await Promise.resolve();
		});
		await act(async (): Promise<void> => finishShareShelfMotion(closingShelf));
		await expect
			.element(rendered.getByRole('region', { name: 'Annotations' }))
			.not.toBeInTheDocument();
		expect(toastSpies.warning).toHaveBeenCalledWith(
			'Clipboard contains 2 annotations, but durable history was not recorded.',
		);
		expect(toastSpies.success).not.toHaveBeenCalled();
	});

	test('keeps durable history in the Share shelf and exposes unhandle only for an eligible success', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, true);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);

		await expect.element(rendered.getByRole('button', { name: 'History (1)' })).toBeVisible();
		expect(document.querySelector('[data-slot="drawer-popup"]')).not.toBeNull();
		const embeddedHistory = rendered.getByRole('region', { name: 'Output history' }).element();
		expect(embeddedHistory.classList).not.toContain('border-t');
		await performBrowserAction(() => rendered.getByRole('button', { name: 'History (1)' }).click());
		await expect.element(rendered.getByText('Clipboard Markdown', { exact: true })).toBeVisible();
		await expect.element(rendered.getByText('3 annotations', { exact: true })).toBeVisible();
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Mark as not handled' }).click(),
		);
		expect(findLastOperation(surface, 'output.handled.clear')).toEqual({
			attemptId: successfulAttemptId,
			expectedSessionRevision: 3,
			kind: 'output.handled.clear',
		});
	});

	test('locks shelf dismissal while History Repeat is unresolved', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, 'unknown');
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await performBrowserAction(() => rendered.getByRole('button', { name: 'History (1)' }).click());
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Repeat output attempt 1' }).click(),
		);

		await expect
			.element(rendered.getByRole('button', { name: 'Close Annotations' }))
			.toBeDisabled();
		await performBrowserAction(() => userEvent.keyboard('{Escape}'));
		await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();
		expect(
			rendered
				.getByTestId('worktree-annotation-share-shelf')
				.element()
				.hasAttribute('data-ending-style'),
		).toBe(false);

		await act(async (): Promise<void> => {
			surface.settleMostRecentOutput({
				effectError: 'repeat failed',
				kind: 'effect_failed',
				summary: outputSummary('clipboard_markdown'),
			});
			await settleInteraction();
		});
		await expect.element(rendered.getByRole('region', { name: 'Annotations' })).toBeVisible();
	});

	test('uses one output lease across Share commands and History Repeat', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, 'unknown');
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await performBrowserAction(() => rendered.getByRole('button', { name: 'History (1)' }).click());
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Copy Markdown' }).click(),
		);

		await expect
			.element(rendered.getByRole('button', { name: 'Repeat output attempt 1' }))
			.toBeDisabled();
		await expect
			.element(rendered.getByRole('button', { name: 'Close Annotations' }))
			.toBeDisabled();
		expect(
			surface.sentOperations.filter((operation) => operation.kind === 'output.repeat'),
		).toHaveLength(0);
		await act(async (): Promise<void> => {
			surface.settleMostRecentOutput({ kind: 'destination_cancelled' });
			await settleInteraction();
		});
	});

	test.each(['fileView', 'review'] as const)(
		'keeps collapsed and expanded History outside the %s Share command hit area',
		async (surfaceKind) => {
			const surface = new RecordingAnnotationBrowserSurface(surfaceKind);
			const rendered = await render(
				<ShareSurfaceGridFixture surface={surface} surfaceKind={surfaceKind} />,
			);
			await publishShareProjection(surface, true);
			await performBrowserAction(() =>
				rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
			);

			const shareLayoutOwner = rendered.getByTestId('worktree-annotation-share-shelf').element();
			await waitForShareShelfOpeningMotion(requireHtmlElement(shareLayoutOwner));
			expect(
				shareLayoutOwner.contains(
					rendered.getByRole('button', { name: 'Copy Markdown' }).element(),
				),
			).toBe(true);
			expect(
				shareLayoutOwner.contains(rendered.getByRole('button', { name: 'History (1)' }).element()),
			).toBe(true);
			assertElementOwnsItsCenterHitTarget(
				rendered.getByRole('button', { name: 'Copy Markdown' }).element(),
			);
			await act(async (): Promise<void> => {
				await rendered.getByRole('button', { name: 'History (1)' }).click();
				await settleInteraction();
			});
			assertElementOwnsItsCenterHitTarget(
				rendered.getByRole('button', { name: 'Copy Markdown' }).element(),
			);
		},
	);

	test('retries unhandle once after the output projection advances past a revision conflict', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, true);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await performBrowserAction(() => rendered.getByRole('button', { name: 'History (1)' }).click());
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Mark as not handled' }).click(),
		);

		await act(async (): Promise<void> => {
			surface.settleMostRecentConflict('output.handled.clear');
			await settleInteraction();
		});
		expect(outputHandledClearOperations(surface)).toEqual([
			{
				attemptId: successfulAttemptId,
				expectedSessionRevision: 3,
				kind: 'output.handled.clear',
			},
		]);

		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				outputHistory: [successfulHistorySummary()],
				revision: 5,
				sessions: [
					annotationSessionSummary({
						eligibleMessageCount: 3,
						eligibleWithoutInlinePlacementCount: 1,
						revision: 4,
						sessionId: annotationSessionId,
					}),
				],
			});
			await settleInteraction();
		});
		await expect.poll(() => outputHandledClearOperations(surface).length).toBe(2);
		expect(outputHandledClearOperations(surface)[1]).toEqual({
			attemptId: successfulAttemptId,
			expectedSessionRevision: 4,
			kind: 'output.handled.clear',
		});
	});

	test('stops a conflicted unhandle when its review session disappears', async () => {
		const surface = new RecordingAnnotationBrowserSurface('review');
		const rendered = await render(<ShareSurfaceFixture surface={surface} />);
		await publishShareProjection(surface, true);
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Annotations', exact: true }).click(),
		);
		await performBrowserAction(() => rendered.getByRole('button', { name: 'History (1)' }).click());
		await performBrowserAction(() =>
			rendered.getByRole('button', { name: 'Mark as not handled' }).click(),
		);

		await act(async (): Promise<void> => {
			surface.settleMostRecentConflict('output.handled.clear');
			await settleInteraction();
			surface.publishProjectionState({
				expectedThreadCount: 0,
				outputHistory: [],
				revision: 5,
				sessions: [],
			});
			await settleInteraction();
		});

		expect(toastSpies.error).toHaveBeenCalledWith('The review session is no longer available.');
		expect(outputHandledClearOperations(surface)).toHaveLength(1);
	});
});

function ShareSurfaceFixture(props: {
	readonly viewedControlRef?: Ref<ViewedCommandTestHandle>;
	readonly surface: RecordingAnnotationBrowserSurface;
}): ReactElement {
	return (
		<WorktreeAnnotationSurfaceProvider surfaceClient={props.surface.client}>
			{props.viewedControlRef === undefined ? null : (
				<ViewedCommandTestControl controlRef={props.viewedControlRef} />
			)}
			<OverlayCommandTestControl />
			<BridgeViewerContextPanelProvider>
				<div
					className="grid h-[500px] w-[600px] grid-rows-[auto_minmax(0,1fr)]"
					data-testid="review-or-file-header"
				>
					<BridgeViewerContentHeader
						controls={<WorktreeAnnotationShareHeaderControl />}
						mode="review"
						statusText={null}
						title="Sources/First.swift"
					/>
					<BridgeViewerContextPanelViewport testId="share-context-panel-viewport">
						<button className="mt-16" data-testid="share-layout-code-canvas" type="button">
							Code canvas target
						</button>
					</BridgeViewerContextPanelViewport>
				</div>
			</BridgeViewerContextPanelProvider>
		</WorktreeAnnotationSurfaceProvider>
	);
}

function ShareSurfaceGridFixture(props: {
	readonly surface: RecordingAnnotationBrowserSurface;
	readonly surfaceKind: 'fileView' | 'review';
}): ReactElement {
	return (
		<WorktreeAnnotationSurfaceProvider surfaceClient={props.surface.client}>
			<BridgeViewerContextPanelProvider>
				<div
					className={`grid h-[500px] w-[600px] ${
						props.surfaceKind === 'review'
							? 'grid-rows-[auto_auto_minmax(0,1fr)]'
							: 'grid-rows-[auto_minmax(0,1fr)]'
					}`}
					data-testid="share-surface-grid-fixture"
				>
					<BridgeViewerContentHeader
						controls={<WorktreeAnnotationShareHeaderControl />}
						mode={props.surfaceKind === 'review' ? 'review' : 'file'}
						statusText={null}
						title="Sources/First.swift"
					/>
					{props.surfaceKind === 'review' ? <div>Comparison status</div> : null}
					<BridgeViewerContextPanelViewport testId="share-context-panel-viewport">
						<div data-testid="share-layout-code-canvas">Code canvas</div>
					</BridgeViewerContextPanelViewport>
				</div>
			</BridgeViewerContextPanelProvider>
		</WorktreeAnnotationSurfaceProvider>
	);
}

function OverlayCommandTestControl(): ReactElement {
	const client = useWorktreeAnnotationSurfaceClient();
	return (
		<div hidden>
			<button
				data-testid="create-unrelated-command-overlay"
				type="button"
				onClick={() => {
					void client.execute({
						admission: { kind: 'selected', sessionId: annotationSecondSessionId },
						body: 'Unrelated draft',
						editToken: 'unrelated-overlay-edit',
						kind: 'root.create',
						origin: {
							diffSide: 'additions',
							endLine: 3,
							kind: 'located',
							path: 'Sources/Other.swift',
							sourceIdentity: 'other-source',
							sourceRole: 'reviewHead',
							startLine: 3,
						},
					});
				}}
			>
				Create unrelated command overlay
			</button>
			<button
				data-testid="create-active-command-overlay"
				type="button"
				onClick={() => {
					void client.execute({
						body: 'Changed active draft',
						editToken: 'active-overlay-edit',
						expectedDraftRevision: null,
						expectedMessageRevision: 1,
						kind: 'draft.flush',
						messageId: newMessageId,
						sessionId: annotationSessionId,
					});
				}}
			>
				Create active command overlay
			</button>
		</div>
	);
}

function assertElementOwnsItsCenterHitTarget(element: Element): void {
	const bounds = element.getBoundingClientRect();
	const hitTarget = document.elementFromPoint(
		bounds.left + bounds.width / 2,
		bounds.top + bounds.height / 2,
	);
	expect(element.contains(hitTarget)).toBe(true);
}

async function publishShareProjection(
	surface: RecordingAnnotationBrowserSurface,
	includeHistory: boolean | 'unknown' = false,
	locatedResolution: 'open' | 'resolved' = 'open',
): Promise<void> {
	await act(async (): Promise<void> => {
		surface.publishProjectionState({
			expectedThreadCount: 2,
			...(includeHistory !== false
				? {
						outputHistory: [
							includeHistory === 'unknown' ? unknownHistorySummary() : successfulHistorySummary(),
						],
					}
				: {}),
			revision: 3,
			sessions: [
				annotationSessionSummary({
					eligibleMessageCount: 3,
					eligibleWithoutInlinePlacementCount: 1,
					revision: 3,
					sessionId: annotationSessionId,
				}),
			],
		});
		surface.publishThreadMessages({
			context: { ...locatedContext, resolution: locatedResolution },
			messages: [
				savedMessage({ body: 'Handled saved comment', handled: true, messageId: handledMessageId }),
				savedMessage({
					body: 'New saved comment',
					handled: false,
					messageId: newMessageId,
					ordinal: 1,
				}),
			],
		});
		surface.publishThreadMessages({
			context: unavailableContext,
			messages: [
				savedMessage({
					body: '## Unavailable saved comment\n\n- Preserved list item',
					handled: false,
					messageId: unavailableMessageId,
					threadId: unavailableThreadId,
				}),
			],
		});
		await settleInteraction();
	});
}

function unknownHistorySummary(): WorktreeAnnotationOutputHistorySummary {
	return {
		...successfulHistorySummary(),
		canMarkNotHandled: false,
		state: 'unknown',
	};
}

function successfulHistorySummary(): WorktreeAnnotationOutputHistorySummary {
	return {
		attemptId: successfulAttemptId,
		canMarkNotHandled: true,
		createdAt: Date.UTC(2026, 7, 20, 16),
		messageCount: 3,
		outputKind: 'clipboard_markdown' as const,
		repeatedFromAttemptId: null,
		sessionId: annotationSessionId,
		state: 'succeeded' as const,
		updatedAt: Date.UTC(2026, 7, 20, 16),
	};
}

function savedMessage(props: {
	readonly body: string;
	readonly handled: boolean;
	readonly messageId: string;
	readonly ordinal?: number;
	readonly threadId?: string;
}): WorktreeAnnotationMessageEntry {
	return {
		...annotationMessage({
			messageId: props.messageId,
			...(props.ordinal === undefined ? {} : { ordinal: props.ordinal }),
			sessionRevision: 3,
			threadId: props.threadId ?? annotationHeadThreadId,
		}),
		handled: props.handled,
		savedBody: props.body,
	};
}

function outputSummary(
	outputKind: 'clipboard_markdown' | 'json_file',
	messageCount = 2,
): {
	readonly attemptId: string;
	readonly destinationFilename: string | null;
	readonly messageCount: number;
	readonly outputKind: 'clipboard_markdown' | 'json_file';
	readonly sessionId: string;
} {
	return {
		attemptId: successfulAttemptId,
		destinationFilename: outputKind === 'json_file' ? 'comments.json' : null,
		messageCount,
		outputKind,
		sessionId: annotationSessionId,
	} as const;
}

const locatedContext: WorktreeAnnotationThreadContext = {
	diffSide: null,
	endLine: 7,
	path: 'Sources/App/View.swift',
	placement: 'exact',
	resolution: 'open',
	scope: 'located',
	sourceIdentity: 'descriptor-file-1',
	sourceRole: 'file',
	startLine: 4,
	threadId: annotationHeadThreadId,
};

const unavailableContext: WorktreeAnnotationThreadContext = {
	...locatedContext,
	path: 'Sources/App/Unavailable.swift',
	placement: 'unavailable',
	threadId: unavailableThreadId,
};
