import { act, type ReactElement } from 'react';
import { afterEach, beforeEach, describe, expect, test } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';
import { page, userEvent } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	annotationMessage,
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import { WorktreeAnnotationConversationFrame } from './worktree-annotation-conversation-frame.js';
import type {
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationThreadContext,
} from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationProjection,
	WorktreeAnnotationSurfaceProvider,
} from './worktree-annotation-surface-provider.js';
import {
	settleThreadMotion,
	waitForWorktreeAnnotationBrowserDomState,
} from './worktree-annotation-thread.browser.test-support.js';
import { WorktreeAnnotationThread } from './worktree-annotation-thread.js';

describe('worktree annotation inline shell', () => {
	test('marks the active conversation with an outline without washing out its text', async () => {
		// Arrange
		const rendered = await render(
			<WorktreeAnnotationConversationFrame active>
				Readable comment
			</WorktreeAnnotationConversationFrame>,
		);
		// Act
		const frame = rendered.getByTestId('worktree-annotation-conversation-frame').element();
		const style = getComputedStyle(frame);
		// Assert
		expect(style.backgroundColor).toBe('rgb(40, 44, 52)');
		expect(style.color).toBe('rgb(255, 255, 255)');
		expect(style.opacity).toBe('1');
		expect(style.boxShadow).toContain('249, 226, 175');
	});

	beforeEach(async (): Promise<void> => {
		await act(async (): Promise<void> => {
			await userEvent.unhover(document.body);
		});
	});

	afterEach(async (): Promise<void> => {
		await act(async (): Promise<void> => {
			await cleanup();
		});
	});

	test('expands complete chronology on one inline timeline and moves following content', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);
		const visibleLatestMessage = rendered
			.getByTestId('worktree-annotation-thread')
			.getByText('Latest message.');

		await waitForInlineShellVisibleElement(visibleLatestMessage);
		expect(document.body.textContent).not.toContain('Root message.');
		const compactThread = rendered.getByTestId('worktree-annotation-thread').element();
		expect(compactThread.classList).toContain('max-w-3xl');
		expect(compactThread.classList).not.toContain('max-w-xl');
		const followingDiffRow = rendered.getByTestId('following-diff-row').element();
		const compactThreadHeight = compactThread.getBoundingClientRect().height;
		const followingDiffRowTop = followingDiffRow.getBoundingClientRect().top;
		const expandButton = rendered.getByRole('button', { name: 'Expand 2 annotations' }).element();
		expect(expandButton.getBoundingClientRect().width).toBe(24);
		expect(expandButton.getBoundingClientRect().height).toBe(24);
		expect(expandButton.classList).not.toContain('rounded-full');
		expect(expandButton.classList).not.toContain('border-comment-border');
		expect(getComputedStyle(expandButton).color).toBe('rgb(234, 234, 234)');
		await waitForInlineShellVisibleElement(rendered.getByText('1 pending'));
		const pendingStatus = rendered.getByTestId('worktree-annotation-pending-status').element();
		expect(pendingStatus.classList).toContain('text-annotation-status-pending');
		expect(pendingStatus.querySelector('.bg-annotation-status-pending')).not.toBeNull();

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Expand 2 annotations' }).click();
			await userEvent.unhover(expandButton);
		});
		const historyPanel = rendered.getByTestId('worktree-annotation-thread-history').element();
		await settleThreadMotion(historyPanel, 'Expected thread expansion motion to settle.');

		const thread = rendered.getByTestId('worktree-annotation-thread').element();
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
		await waitForInlineShellVisibleElement(rendered.getByText('1 pending'));
		expect(rendered.getByTestId('worktree-annotation-pending-status').element()).toBe(
			pendingStatus,
		);
		expect(rendered.getByTestId('worktree-annotation-message-pending-status').all()).toHaveLength(
			1,
		);
		expect(getComputedStyle(historyPanel).transitionProperty).toContain('height');
		expect(rendered.getByText('Latest message.').all()).toHaveLength(1);
		const expandedMessages = [
			...thread.querySelectorAll<HTMLElement>('[data-testid="worktree-annotation-message"]'),
		];
		expect(expandedMessages).toHaveLength(2);
		const firstMessageBounds = expandedMessages[0]?.getBoundingClientRect();
		const secondMessageBounds = expandedMessages[1]?.getBoundingClientRect();
		if (firstMessageBounds === undefined || secondMessageBounds === undefined) {
			throw new Error('Expected two measured inline messages.');
		}
		expect(secondMessageBounds.top - firstMessageBounds.bottom).toBeCloseTo(4, 1);
		const latestCommandRail = expandedMessages[1]?.querySelector<HTMLElement>(
			'[aria-label="Annotation commands"]',
		);
		const latestCard = latestCommandRail?.parentElement;
		if (
			latestCommandRail === undefined ||
			latestCommandRail === null ||
			latestCard === undefined ||
			latestCard === null
		) {
			throw new Error('Expected the latest message command rail and card.');
		}
		const latestCommandRailBounds = latestCommandRail.getBoundingClientRect();
		const latestCardBounds = latestCard.getBoundingClientRect();
		expect(getComputedStyle(latestCard).backgroundColor).toBe('rgba(0, 0, 0, 0)');
		expect(getComputedStyle(latestCard).borderTopColor).toBe('rgba(0, 0, 0, 0)');
		const latestCardContent = latestCard.firstElementChild;
		if (!(latestCardContent instanceof HTMLElement)) {
			throw new Error('Expected the latest message card content inset owner.');
		}
		const commandButtons = [...latestCommandRail.querySelectorAll<HTMLElement>('button')];
		const editCommandBounds = commandButtons[0]?.getBoundingClientRect();
		if (editCommandBounds === undefined || commandButtons.length !== 1) {
			throw new Error('Expected one annotation-local Edit command.');
		}
		const expandedThreadBounds = thread.getBoundingClientRect();
		expect(latestCommandRailBounds.top).toBeGreaterThanOrEqual(latestCardBounds.top);
		expect(latestCommandRailBounds.bottom).toBeLessThanOrEqual(latestCardBounds.bottom);
		expect(latestCardBounds.right - latestCommandRailBounds.right).toBeCloseTo(9, 1);
		expect(latestCardBounds.bottom - latestCommandRailBounds.bottom).toBeCloseTo(9, 1);
		expect(latestCommandRail.classList).toContain('right-2');
		expect(latestCommandRail.classList).toContain('bottom-2');
		expect(latestCommandRail.classList).toContain('gap-2');
		expect(commandButtons[0]?.getAttribute('aria-label')).toBe('Edit annotation');
		expect(latestCardContent.classList).toContain('py-2');
		expect(latestCardContent.classList).toContain('pr-10');
		expect(thread.classList).toContain('p-3');
		expect(thread.classList).not.toContain('pr-9');
		expect(thread.classList).not.toContain('pb-9');
		expect(expandedThreadBounds.right - latestCardBounds.right).toBeCloseTo(12, 1);
		expect(expandedThreadBounds.bottom - latestCardBounds.bottom).toBeCloseTo(12, 1);
		expect(compactThread.getBoundingClientRect().height).toBeGreaterThan(compactThreadHeight);
		expect(followingDiffRow.getBoundingClientRect().top).toBeGreaterThan(followingDiffRowTop);
		await page.screenshot({ path: '../../../tmp/bridgeweb-inline-thread-expanded.png' });

		await act(async (): Promise<void> => {
			const collapseButton = rendered
				.getByRole('button', { name: 'Collapse 2 annotations' })
				.element();
			await userEvent.click(collapseButton);
			await userEvent.unhover(collapseButton);
		});
		await settleThreadMotion(historyPanel, 'Expected thread collapse motion to settle.');
		await waitForWorktreeAnnotationBrowserDomState({
			readState: (): boolean => !document.body.textContent?.includes('Root message.'),
			isExpected: (collapsed): boolean => collapsed,
		});
		await waitForInlineShellVisibleElement(visibleLatestMessage);
		expect(followingDiffRow.getBoundingClientRect().top).toBeCloseTo(followingDiffRowTop, 1);
	});

	test('opens Reply as the next node on the inline timeline and preserves the first edit', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);

		const replyButton = rendered
			.getByRole('button', {
				name: 'Reply to annotation thread',
			})
			.element();
		await act(async (): Promise<void> => {
			await userEvent.click(replyButton);
			await userEvent.unhover(replyButton);
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected reply expansion motion to settle.',
		);

		const thread = rendered.getByTestId('worktree-annotation-thread').element();
		const composer = rendered.getByRole('textbox', { name: 'Reply with Markdown' });
		await waitForInlineShellVisibleElement(composer);
		expect(thread.contains(composer.element())).toBe(true);
		const replyFrame = composer.element().closest('[data-annotation-frame-placement="embedded"]');
		if (!(replyFrame instanceof HTMLElement)) throw new Error('Expected an embedded reply frame.');
		expect(getComputedStyle(replyFrame).boxShadow).toBe('none');
		const editorSurface = composer.element().closest('[data-annotation-editor-surface]');
		if (!(editorSurface instanceof HTMLElement))
			throw new Error('Expected the reply editor surface.');
		expect(getComputedStyle(editorSurface).boxShadow).not.toBe('none');
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
		const timelineMessages = [
			...thread.querySelectorAll<HTMLElement>('[data-testid="worktree-annotation-message"]'),
		];
		const rootAvatar = timelineMessages[0]?.querySelector<HTMLElement>('[aria-label="You"]');
		const replyAvatar = timelineMessages.at(-1)?.querySelector<HTMLElement>('[aria-label="You"]');
		if (
			rootAvatar === null ||
			rootAvatar === undefined ||
			replyAvatar === null ||
			replyAvatar === undefined
		) {
			throw new Error('Expected aligned root and reply avatars on the inline timeline.');
		}
		expect(replyAvatar.getBoundingClientRect().left).toBeCloseTo(
			rootAvatar.getBoundingClientRect().left,
			1,
		);
		await page.screenshot({ path: '../../../tmp/bridgeweb-inline-reply-aligned.png' });

		await act(async (): Promise<void> => {
			await composer.fill('Inline reply draft');
		});
		await waitForWorktreeAnnotationBrowserDomState({
			readState: (): string | null => {
				const textbox = composer.element();
				return textbox instanceof HTMLTextAreaElement ? textbox.value : null;
			},
			isExpected: (body): boolean => body === 'Inline reply draft',
		});
		expect(thread.contains(composer.element())).toBe(true);
	});

	test('keeps Reply and expanded chronology stable when the active thread background is clicked', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).click();
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected reply expansion motion to settle.',
		);
		const thread = rendered.getByTestId('worktree-annotation-thread').element();
		const composer = rendered.getByRole('textbox', { name: 'Reply with Markdown' });
		await waitForInlineShellVisibleElement(composer);
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
		const rootMessage = rendered
			.getByText('Root message.')
			.element()
			.closest<HTMLElement>('[data-testid="worktree-annotation-message"]');
		const latestMessage = rendered
			.getByText('Latest message.')
			.element()
			.closest<HTMLElement>('[data-testid="worktree-annotation-message"]');
		if (rootMessage === null || latestMessage === null) {
			throw new Error('Expected stable root and latest message surfaces.');
		}

		await act(async (): Promise<void> => {
			await rendered
				.getByTestId('worktree-annotation-thread-summary')
				.getByText('2 comments')
				.click();
			await Promise.resolve();
		});

		await waitForInlineShellVisibleElement(composer);
		expect(rendered.getByTestId('worktree-annotation-thread').element()).toBe(thread);
		expect(thread.getAttribute('data-annotation-expanded')).toBe('true');
		expect(
			rendered
				.getByText('Root message.')
				.element()
				.closest('[data-testid="worktree-annotation-message"]'),
		).toBe(rootMessage);
		expect(
			rendered
				.getByText('Latest message.')
				.element()
				.closest('[data-testid="worktree-annotation-message"]'),
		).toBe(latestMessage);
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
	});

	test('reveals five-message history with one downward soft mask', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishFiveMessageThread(surface);
		const summary = rendered.getByTestId('worktree-annotation-thread-summary').element();
		expect(summary.textContent?.indexOf('5 pending')).toBeLessThan(
			summary.textContent?.indexOf('5 comments') ?? -1,
		);
		expect(
			rendered.getByTestId('worktree-annotation-pending-status').element().classList,
		).toContain('text-annotation-status-pending');
		const expandButton = rendered.getByRole('button', { name: 'Expand 5 annotations' }).element();
		expect(expandButton.classList).not.toContain('rounded-full');
		expect(expandButton.classList).not.toContain('border-comment-border');
		expect(getComputedStyle(expandButton).color).toBe('rgb(234, 234, 234)');
		const expansionChevron = expandButton.querySelector('svg');
		if (expansionChevron === null) throw new Error('Expected the thread expansion chevron.');
		expect(getComputedStyle(expansionChevron).transitionDuration).toBe('0.12s');

		await act(async (): Promise<void> => {
			await userEvent.click(expandButton);
			await userEvent.unhover(expandButton);
		});
		const historyPanel = rendered.getByTestId('worktree-annotation-thread-history').element();
		await settleThreadMotion(historyPanel, 'Expected grouped history entrance to settle.');
		const historyGroup = rendered.getByTestId('worktree-annotation-thread-history-group').element();
		expect(
			historyGroup.querySelectorAll('[data-testid="worktree-annotation-message"]'),
		).toHaveLength(4);
		expect(rendered.getByTestId('worktree-annotation-message-pending-status').all()).toHaveLength(
			5,
		);
		expect(getComputedStyle(historyPanel).transitionDuration).toBe('0.12s');
		expect(
			historyGroup.querySelectorAll('[data-testid="worktree-annotation-thread-history-message"]'),
		).toHaveLength(0);
		expect(getComputedStyle(historyGroup).maskImage).toContain('linear-gradient');
		expect(getComputedStyle(historyGroup).maskSize).toBe('100% 220%');
		expect(getComputedStyle(historyGroup).transitionProperty).toContain('mask-position');
		expect(getComputedStyle(historyGroup).transitionDelay).toBe('0s');
		expect(getComputedStyle(historyGroup).transitionDuration).toBe('0.12s');
		await page.screenshot({ path: '../../../tmp/bridgeweb-inline-five-message-expanded.png' });

		await act(async (): Promise<void> => {
			const collapseButton = rendered
				.getByRole('button', { name: 'Collapse 5 annotations' })
				.element();
			await userEvent.click(collapseButton);
			await userEvent.unhover(collapseButton);
		});
		const reverseMaskKeyframes = historyGroup
			.getAnimations()
			.flatMap((animation) =>
				animation.effect instanceof KeyframeEffect ? animation.effect.getKeyframes() : [],
			);
		expect(
			reverseMaskKeyframes.some((keyframe) =>
				Object.values(keyframe).some((value) => String(value).includes('100%')),
			),
		).toBe(true);
		expect(getComputedStyle(historyPanel).transitionDelay).toBe('0s');
		await settleThreadMotion(historyPanel, 'Expected reversed soft mask motion to settle.');
	});

	test('keeps focus inert and activates the saved range only on click', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);

		const compactSurface = rendered.getByTestId('worktree-annotation-message');
		await act(async (): Promise<void> => {
			compactSurface.element().focus();
			await Promise.resolve();
		});
		expect(document.body.textContent).not.toContain('Root message.');
		expect(rendered.getByTestId('worktree-annotation-thread').element().classList).not.toContain(
			'ring-warning',
		);
		expect(
			getComputedStyle(rendered.getByTestId('worktree-annotation-thread').element()).borderRadius,
		).toBe('14px');
		expect(rendered.getByTestId('worktree-annotation-thread').element().classList).toContain('p-3');

		await act(async (): Promise<void> => {
			await rendered
				.getByTestId('worktree-annotation-thread-summary')
				.getByText('2 comments')
				.click();
			await Promise.resolve();
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected activated history to settle.',
		);
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
		expect(rendered.getByTestId('worktree-annotation-thread').element().classList).toContain(
			'ring-warning',
		);

		const externalFocusTarget = document.createElement('button');
		externalFocusTarget.textContent = 'External keyboard target';
		document.body.append(externalFocusTarget);
		await act(async (): Promise<void> => {
			externalFocusTarget.focus();
		});
		expect(
			rendered
				.getByTestId('worktree-annotation-thread')
				.element()
				.getAttribute('data-annotation-expanded'),
		).toBe('true');
		externalFocusTarget.remove();
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Collapse 2 annotations' }).click();
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected Collapse transition to settle.',
		);
		await waitForWorktreeAnnotationBrowserDomState({
			readState: (): boolean => !document.body.textContent?.includes('Root message.'),
			isExpected: (collapsed): boolean => collapsed,
		});
	});

	test('keeps permanent local Edit and outlined thread actions at their exact owners', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);

		const thread = rendered.getByTestId('worktree-annotation-thread');
		const editButton = thread.getByRole('button', { name: 'Edit annotation' });
		await waitForInlineShellVisibleElement(editButton);
		const editCommands = editButton
			.element()
			.closest<HTMLElement>('[aria-label="Annotation commands"]');
		if (editCommands === null) throw new Error('Expected permanent annotation Edit commands.');
		expect(getComputedStyle(editCommands).opacity).toBe('1');
		await waitForInlineShellVisibleElement(
			thread.getByRole('button', { name: 'Reply to annotation thread' }),
		);
		const replyButton = thread
			.getByRole('button', { name: 'Reply to annotation thread' })
			.element();
		expect(replyButton.classList).toContain('border-border');
		expect(replyButton.classList).toContain('size-6');
		const resolveButton = thread.getByRole('button', { name: 'Resolve annotation thread' });
		await waitForInlineShellVisibleElement(resolveButton);
		expect(resolveButton.element().classList).toContain('border-success/50');
		expect(resolveButton.element().classList).toContain('text-success');
		expect(resolveButton.element().classList).toContain('size-6');

		await act(async (): Promise<void> => {
			await thread.getByText('Latest message.').click();
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected saved-message activation to settle before Edit.',
		);
		await waitForInlineShellVisibleElement(rendered.getByText('Root message.'));
		expect(rendered.getByRole('textbox', { name: 'Annotation Markdown' }).all()).toHaveLength(0);
		await act(async (): Promise<void> => {
			await userEvent.dblClick(thread.getByText('Latest message.').element());
		});
		await waitForInlineAnnotationEditor();
	});

	test('offers direct Edit and supports Enter from message focus', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);

		const latestMessage = rendered
			.getByText('Latest message.')
			.element()
			.closest<HTMLElement>('[data-testid="worktree-annotation-message"]');
		const editButton = latestMessage?.querySelector<HTMLButtonElement>(
			'button[aria-label="Edit annotation"]',
		);
		if (editButton === null || editButton === undefined) {
			throw new Error('Expected the visible latest message Edit action.');
		}
		await performBrowserAction(async (): Promise<void> => {
			await userEvent.click(editButton);
			await userEvent.unhover(editButton);
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected direct Edit thread expansion to settle.',
		);
		const editor = rendered.getByRole('textbox', { name: 'Annotation Markdown' });
		await waitForInlineAnnotationEditor();
		const editingMessage = editor
			.element()
			.closest<HTMLElement>('[data-testid="worktree-annotation-message"]');
		const editorSurface = editor.element().closest<HTMLElement>('[data-annotation-editor-surface]');
		if (editingMessage === null || editorSurface === null) {
			throw new Error('Expected the explicit message editor surface.');
		}
		expect(editingMessage.getAttribute('data-annotation-editing')).toBe('true');
		expect(editorSurface.classList).toContain('ring-inset');
		expect(getComputedStyle(editorSurface).boxShadow).not.toBe('none');
		const revert = rendered.getByRole('button', { name: 'Revert annotation draft' });
		const surfaceBounds = editorSurface.getBoundingClientRect();
		const revertBounds = revert.element().getBoundingClientRect();
		expect(revertBounds.top - surfaceBounds.top).toBeGreaterThanOrEqual(8);
		expect(surfaceBounds.right - revertBounds.right).toBeGreaterThanOrEqual(8);
		expect(revertBounds.width).toBe(24);
		expect(revertBounds.height).toBe(24);
		expect(editor.element().getBoundingClientRect().right).toBeLessThanOrEqual(
			revertBounds.left - 8,
		);
		await act(async (): Promise<void> => {
			revert.element().focus();
		});
		const commandFocusedBoxShadow = await waitForWorktreeAnnotationBrowserDomState({
			readState: (): string => getComputedStyle(editorSurface).boxShadow,
			isExpected: (shadow): boolean => shadow !== 'none',
		});
		await act(async (): Promise<void> => {
			editor.element().focus();
		});
		expect(editingMessage.getAttribute('data-annotation-editing')).toBe('true');
		expect(commandFocusedBoxShadow).not.toBe('none');
		await page.screenshot({ path: '../../../tmp/bridgeweb-annotation-explicit-editing.png' });
		await performBrowserAction(async (): Promise<void> => {
			rendered.getByTestId('worktree-annotation-thread').element().focus();
		});
		await waitForInlineAnnotationEditor();
		expect(editingMessage.getAttribute('data-annotation-editing')).toBe('true');
		await waitForWorktreeAnnotationBrowserDomState({
			readState: (): string => getComputedStyle(editorSurface).boxShadow,
			isExpected: (shadow): boolean => shadow === 'none',
		});
		expect(rendered.getByTestId('worktree-annotation-thread').element().classList).toContain(
			'ring-warning',
		);
		const originalEditor = editor.element();
		if (!(originalEditor instanceof HTMLTextAreaElement))
			throw new Error('Expected textarea editor.');
		originalEditor.setSelectionRange(2, 2);
		const originalBody = originalEditor.value;
		await performBrowserAction(async (): Promise<void> => {
			editorSurface.click();
		});
		expect(document.activeElement).toBe(originalEditor);
		expect(editor.element()).toBe(originalEditor);
		expect(originalEditor.value).toBe(originalBody);
		expect(originalEditor.selectionStart).toBe(2);
		await performBrowserAction(async (): Promise<void> => {
			rendered.getByTestId('worktree-annotation-thread').element().focus();
		});

		await performBrowserAction(async (): Promise<void> => {
			await userEvent.keyboard('{Escape}');
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected editor exit thread motion to settle.',
		);
		const message = rendered.getByTestId('worktree-annotation-message').all().at(-1);
		if (message === undefined) throw new Error('Expected the latest message after editing.');
		expect(message.element().getAttribute('data-annotation-editing')).toBe('false');
		await performBrowserAction(async (): Promise<void> => {
			message.element().focus();
			await userEvent.keyboard('{Enter}');
		});
		await settleThreadMotion(
			rendered.getByTestId('worktree-annotation-thread-history').element(),
			'Expected Enter thread expansion to settle.',
		);
		await waitForInlineAnnotationEditor();
	});

	test('preserves message links and selected text without entering edit mode', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderInlineShell(surface);
		await publishTwoMessageThread(surface);
		const messageText = rendered.getByText('Latest message.').element();
		const syntheticLink = document.createElement('a');
		syntheticLink.href = 'https://example.com/';
		syntheticLink.textContent = 'Reference';
		syntheticLink.addEventListener('click', (event) => event.preventDefault());
		messageText.append(syntheticLink);

		await act(async (): Promise<void> => {
			syntheticLink.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
		});
		expect(document.querySelector('[aria-label="Annotation Markdown"]')).toBeNull();

		const selection = window.getSelection();
		const selectionRange = document.createRange();
		selectionRange.selectNodeContents(messageText);
		selection?.removeAllRanges();
		selection?.addRange(selectionRange);
		await act(async (): Promise<void> => {
			messageText.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, detail: 1 }));
			messageText.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
		});
		expect(document.querySelector('[aria-label="Annotation Markdown"]')).toBeNull();
		selection?.removeAllRanges();
	});

	test('keeps the max-w-3xl frame contained at narrow width and 200 percent text', async () => {
		const priorRootFontSize = document.documentElement.style.fontSize;
		document.documentElement.style.fontSize = '32px';
		try {
			const surface = new RecordingAnnotationBrowserSurface('fileView');
			const rendered = await renderInlineShell(surface);
			await publishTwoMessageThread(surface);
			const thread = rendered.getByTestId('worktree-annotation-thread').element();
			const host = thread.parentElement;
			if (host === null) throw new Error('Expected the inline-shell host.');
			host.style.width = '360px';
			const hostBounds = host.getBoundingClientRect();
			const threadBounds = thread.getBoundingClientRect();
			expect(getComputedStyle(document.documentElement).fontSize).toBe('32px');
			expect(threadBounds.left).toBeGreaterThanOrEqual(hostBounds.left);
			expect(threadBounds.right).toBeLessThanOrEqual(hostBounds.right);
			expect(document.documentElement.scrollWidth).toBe(document.documentElement.clientWidth);
		} finally {
			document.documentElement.style.fontSize = priorRootFontSize;
		}
	});
});

function InlineShellProjection(): ReactElement | null {
	const projection = useWorktreeAnnotationProjection();
	const thread = projection.threads[0];
	return thread === undefined ? null : (
		<div>
			<WorktreeAnnotationThread
				rangeIdentity={{ itemId: 'inline-shell-item', range: { end: 7, start: 7 } }}
				thread={thread}
			/>
			<div data-testid="following-diff-row">Following diff row</div>
			<button data-testid="following-focus-target" type="button">
				Following focus target
			</button>
		</div>
	);
}

async function renderInlineShell(
	surface: RecordingAnnotationBrowserSurface,
): Promise<Awaited<ReturnType<typeof render>>> {
	return await render(
		<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
			<InlineShellProjection />
		</WorktreeAnnotationSurfaceProvider>,
	);
}

async function performBrowserAction(action: () => Promise<void>): Promise<void> {
	await act(action);
}

async function waitForInlineShellVisibleElement(locator: {
	readonly all: () => readonly { readonly element: () => Element }[];
}): Promise<void> {
	await waitForWorktreeAnnotationBrowserDomState({
		readState: (): Element | null => locator.all()[0]?.element() ?? null,
		isExpected: (element): boolean => element !== null && inlineShellElementIsVisible(element),
	});
}

function inlineShellElementIsVisible(element: Element): boolean {
	const bounds = element.getBoundingClientRect();
	const style = getComputedStyle(element);
	return (
		element.isConnected &&
		bounds.width > 0 &&
		bounds.height > 0 &&
		style.visibility !== 'hidden' &&
		style.visibility !== 'collapse'
	);
}

async function waitForInlineAnnotationEditor(): Promise<HTMLTextAreaElement> {
	const editor = await waitForWorktreeAnnotationBrowserDomState({
		readState: (): HTMLTextAreaElement | null =>
			document.querySelector('textarea[aria-label="Annotation Markdown"]'),
		isExpected: (candidate): boolean =>
			candidate !== null && !candidate.disabled && inlineShellElementIsVisible(candidate),
	});
	if (editor === null) throw new Error('Expected the settled inline annotation editor.');
	return editor;
}

async function publishTwoMessageThread(surface: RecordingAnnotationBrowserSurface): Promise<void> {
	await act(async (): Promise<void> => {
		surface.publishProjectionState({
			expectedThreadCount: 1,
			revision: 3,
			sessions: [annotationSessionSummary({ revision: 3, sessionId: annotationSessionId })],
		});
		surface.publishThreadMessages({
			context: locatedContext,
			messages: [
				makeSavedMessage({ body: 'Root message.', handled: true, messageId: rootMessageId }),
				makeSavedMessage({ body: 'Latest message.', messageId: latestMessageId, ordinal: 1 }),
			],
		});
		await Promise.resolve();
	});
}

async function publishFiveMessageThread(surface: RecordingAnnotationBrowserSurface): Promise<void> {
	await act(async (): Promise<void> => {
		surface.publishProjectionState({
			expectedThreadCount: 1,
			revision: 6,
			sessions: [annotationSessionSummary({ revision: 6, sessionId: annotationSessionId })],
		});
		surface.publishThreadMessages({
			context: locatedContext,
			messages: Array.from({ length: 5 }, (_, ordinal) =>
				makeSavedMessage({
					body: ordinal === 0 ? 'Root message.' : `Reply ${ordinal}.`,
					messageId: `00000000-0000-7000-8000-${String(194 + ordinal).padStart(12, '0')}`,
					ordinal,
				}),
			),
		});
		await Promise.resolve();
	});
}

function makeSavedMessage(props: {
	readonly body: string;
	readonly handled?: boolean;
	readonly messageId: string;
	readonly ordinal?: number;
}): WorktreeAnnotationMessageEntry {
	return {
		...annotationMessage({
			messageId: props.messageId,
			...(props.ordinal === undefined ? {} : { ordinal: props.ordinal }),
			sessionRevision: 3,
			threadId,
		}),
		createdAt: Date.now() / 1000 - 978_307_200 - (props.ordinal ?? 0) * 60,
		handled: props.handled ?? false,
		savedBody: props.body,
	};
}

const threadId = '00000000-0000-7000-8000-000000000191';
const rootMessageId = '00000000-0000-7000-8000-000000000192';
const latestMessageId = '00000000-0000-7000-8000-000000000193';

const locatedContext: WorktreeAnnotationThreadContext = {
	diffSide: null,
	endLine: 7,
	path: 'Sources/App/View.swift',
	placement: 'exact',
	resolution: 'open',
	scope: 'located',
	sourceIdentity: 'descriptor-inline-shell',
	sourceRole: 'file',
	startLine: 7,
	threadId,
};
