import { act, cloneElement, type ReactElement } from 'react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import {
	annotationHeadThreadId,
	annotationMessage,
	createWorktreeAnnotationBrowserProviderHarness,
} from '../../worktree-annotations/worktree-annotation-browser-test-support.js';
import type { WorktreeAnnotationThreadProjection } from '../../worktree-annotations/worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationEditorInstallationPreparation,
	useWorktreeAnnotationEditSurfaceToken,
} from '../../worktree-annotations/worktree-annotation-surface-provider.js';
import {
	createDeferred,
	waitForWorktreeAnnotationBrowserDomState,
} from '../../worktree-annotations/worktree-annotation-thread.browser.test-support.js';
import { markdownCanvas } from './bridge-markdown-annotation-test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise the real renderer and host geometry.
import '../bridge-app.css';

beforeEach((): void => {
	const requestFrame = window.requestAnimationFrame.bind(window);
	vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback): number =>
		requestFrame((timestamp): void => {
			act((): void => callback(timestamp));
		}),
	);
});

afterEach(async (): Promise<void> => {
	await act(async (): Promise<void> => {
		await cleanup();
	});
	vi.restoreAllMocks();
});

test('retires a pending range through a programmatic file round trip', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const screen = await render(harness.wrap(await markdownCanvas('First target\n\nSecond target')));
	await expect
		.element(screen.getByRole('button', { name: 'Select source lines 3–3' }))
		.toBeVisible();
	act((): void => {
		screen
			.getByRole('button', { name: 'Select source lines 3–3' })
			.element()
			.dispatchEvent(new MouseEvent('click', { bubbles: true }));
	});
	await expect.element(screen.getByTestId('bridge-markdown-source-selection')).toBeInTheDocument();
	// The provider survives the file loading gap; no outside-pointer dismissal occurs.
	await screen.rerender(harness.wrap(null));
	await screen.rerender(harness.wrap(await markdownCanvas('Other document', 1, 'other.md')));
	await expect.element(screen.getByText('Other document', { exact: true })).toBeVisible();
	await screen.rerender(harness.wrap(null));
	await screen.rerender(harness.wrap(await markdownCanvas('First target\n\nSecond target')));
	await expect
		.element(screen.getByRole('button', { name: 'Select source lines 3–3' }))
		.toBeVisible();
	await expect
		.element(screen.getByTestId('bridge-markdown-source-selection'))
		.not.toBeInTheDocument();
});

test('keeps saved thread coordinates with the painted document while another editor retains it', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const screen = await render(
		harness.wrap(await markdownCanvas('First target\n\nCommented target\n\nLast target')),
	);
	const thread = savedThread(1, 3);
	await act(async (): Promise<void> => {
		harness.surface.publishProjection(1, 1);
		harness.surface.publishThreadMessages(thread);
	});
	await expect.element(screen.getByText('Saved second target', { exact: true })).toBeVisible();
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
	});
	const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
	await screen.rerender(
		harness.wrap(
			await markdownCanvas('New target\n\nFirst target\n\nCommented target\n\nLast target', 2),
		),
	);
	await act(async (): Promise<void> => {
		harness.surface.publishProjection(2, 1);
		harness.surface.publishThreadMessages(savedThread(2, 5));
	});
	expect(screen.getByPlaceholder('Write an annotation in Markdown').element()).toBe(editor);
	await expect.element(screen.getByRole('status')).toHaveTextContent('File changed');
	const precedingTarget = (): string | null | undefined =>
		screen
			.getByText('Saved second target', { exact: true })
			.element()
			.closest('.bridge-markdown-annotation-host')?.previousElementSibling?.textContent;
	expect(precedingTarget()).toBe('Commented target');
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Revert annotation draft' }).click();
	});
	await expect.element(screen.getByText('New target', { exact: true })).toBeVisible();
	expect(
		await waitForWorktreeAnnotationBrowserDomState({
			readState: precedingTarget,
			isExpected: (target): boolean => target === 'Commented target',
		}),
	).toBe('Commented target');
});

test('updates saved comment text while retaining its displayed source coordinates', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const screen = await render(
		harness.wrap(await markdownCanvas('First target\n\nCommented target')),
	);
	await act(async (): Promise<void> => {
		harness.surface.publishProjection(1, 1);
		harness.surface.publishThreadMessages(savedThread(1, 3));
	});
	await expect.element(screen.getByText('Saved second target', { exact: true })).toBeVisible();
	const updatedThread = savedThread(2, 5);
	await act(async (): Promise<void> => {
		harness.surface.publishThreadMessages({
			...updatedThread,
			messages: updatedThread.messages.map((message) => ({
				...message,
				messageRevision: message.messageRevision + 1,
				savedRevision: (message.savedRevision ?? 0) + 1,
				savedBody: 'Edited comment on retained document',
			})),
		});
	});
	await expect
		.element(screen.getByText('Edited comment on retained document', { exact: true }))
		.toBeVisible();
	expect(
		screen
			.getByText('Edited comment on retained document', { exact: true })
			.element()
			.closest('.bridge-markdown-annotation-host')?.previousElementSibling?.textContent,
	).toBe('Commented target');
});

test('offers a neutral floating update action without moving the document', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const rootCreateSent = createDeferred<void>();
	const sendCommand = harness.surface.client.send;
	vi.spyOn(harness.surface.client, 'send').mockImplementation((command): string => {
		const requestId = sendCommand(command);
		if (command.command === 'annotationCommand' && command.operation.kind === 'root.create') {
			rootCreateSent.resolve(undefined);
		}
		return requestId;
	});
	const screen = await render(
		harness.wrap(await markdownCanvas('First target\n\nCommented target')),
	);
	await act(async (): Promise<void> => {
		harness.surface.publishProjection(1, 1);
		harness.surface.publishThreadMessages(savedThread(1, 3));
	});
	await expect.element(screen.getByText('Saved second target', { exact: true })).toBeVisible();
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
	});
	await act(async (): Promise<void> => {
		await screen
			.getByPlaceholder('Write an annotation in Markdown')
			.fill('Draft kept before loading the latest file');
	});
	await act(async (): Promise<void> => rootCreateSent.promise);
	expect(harness.surface.sentOperations.some((operation) => operation.kind === 'root.create')).toBe(
		true,
	);
	const documentTopBefore = screen
		.getByTestId('bridge-markdown-canvas')
		.element()
		.getBoundingClientRect().top;

	await screen.rerender(
		harness.wrap(await markdownCanvas('New target\n\nFirst target\n\nCommented target', 2)),
	);
	await act(async (): Promise<void> => {
		harness.surface.publishProjection(2, 1);
		harness.surface.publishThreadMessages(savedThread(2, 5));
	});

	const notice = screen.getByRole('status', { name: 'File changed' }).element();
	const noticeBounds = notice.getBoundingClientRect();
	const viewportBounds = notice.closest('[data-markdown-scroll-viewport]')?.getBoundingClientRect();
	if (viewportBounds === undefined) throw new Error('Markdown scroll viewport is unavailable.');
	expect(noticeBounds.width).toBeLessThan(240);
	expect(viewportBounds.right - noticeBounds.right).toBeLessThanOrEqual(12);
	expect(screen.getByTestId('bridge-markdown-canvas').element().getBoundingClientRect().top).toBe(
		documentTopBefore,
	);
	const neutralReference = document.createElement('div');
	neutralReference.className = 'bg-popover';
	document.body.append(neutralReference);
	expect(getComputedStyle(notice).backgroundColor).toBe(
		getComputedStyle(neutralReference).backgroundColor,
	);
	neutralReference.remove();
	const updateButton = screen.getByRole('button', { name: 'Update Markdown file' });
	await expect.element(updateButton).toBeVisible();
	const editorBounds = screen
		.getByPlaceholder('Write an annotation in Markdown')
		.element()
		.getBoundingClientRect();
	expect(rectanglesOverlap(noticeBounds, editorBounds)).toBe(false);
	let durableReceipt:
		| ReturnType<typeof harness.surface.settleMostRecentCommittedWithoutProjection>
		| undefined;
	await act(async (): Promise<void> => {
		await updateButton.click();
		durableReceipt = harness.surface.settleMostRecentCommittedWithoutProjection(
			undefined,
			'root.create',
		);
		await Promise.resolve();
	});
	if (durableReceipt?.kind !== 'message') {
		throw new Error('Expected Update preparation to return a durable draft receipt.');
	}
	expect(durableReceipt.message.draft?.body).toBe('Draft kept before loading the latest file');
	await expect.element(screen.getByText('New target', { exact: true })).toBeVisible();
});

test('updates only to the latest prepared candidate', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let releasePreparation: (() => void) | null = null;
	const preparation = new Promise<boolean>((resolve): void => {
		releasePreparation = (): void => resolve(true);
	});
	const screen = await render(
		harness.wrap(
			<>
				<InstallationPreparation prepare={(): Promise<boolean> => preparation} />
				{await markdownCanvas('Original document')}
			</>,
		),
	);
	await screen.rerender(
		harness.wrap(
			<>
				<InstallationPreparation prepare={(): Promise<boolean> => preparation} />
				{await markdownCanvas('Stale candidate', 2)}
			</>,
		),
	);
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await screen.rerender(
		harness.wrap(
			<>
				<InstallationPreparation prepare={(): Promise<boolean> => preparation} />
				{await markdownCanvas('Latest candidate', 3)}
			</>,
		),
	);
	await act(async (): Promise<void> => {
		releasePreparation?.();
		await preparation;
	});

	await expect.element(screen.getByText('Original document', { exact: true })).toBeVisible();
	await expect
		.element(screen.getByText('Stale candidate', { exact: true }))
		.not.toBeInTheDocument();
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(screen.getByText('Latest candidate', { exact: true })).toBeVisible();
});

test('keeps the old document when preparation fails and retries the same update', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let preparationSucceeds = false;
	let preparationCount = 0;
	const prepare = async (): Promise<boolean> => {
		preparationCount += 1;
		return preparationSucceeds;
	};
	const renderCandidate = async (contents: string, version: number): Promise<ReactElement> => (
		<>
			<InstallationPreparation prepare={prepare} />
			{await markdownCanvas(contents, version)}
		</>
	);
	const screen = await render(harness.wrap(await renderCandidate('Original document', 1)));
	await screen.rerender(harness.wrap(await renderCandidate('Updated document', 2)));
	await expect.element(screen.getByRole('status', { name: 'File changed' })).toBeVisible();
	await expect.element(screen.getByRole('button', { name: 'Update Markdown file' })).toBeVisible();
	// The arriving candidate already flushed the active editor once automatically.
	const preparationCountBeforeUpdate = preparationCount;

	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(screen.getByText('Original document', { exact: true })).toBeVisible();
	await expect.element(screen.getByRole('status', { name: "Couldn't apply update" })).toBeVisible();
	expect(preparationCount).toBe(preparationCountBeforeUpdate + 1);
	preparationSucceeds = true;
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(screen.getByText('Updated document', { exact: true })).toBeVisible();
	await expect
		.element(screen.getByRole('status', { name: "Couldn't apply update" }))
		.not.toBeInTheDocument();
	await expect
		.element(screen.getByRole('status', { name: 'File changed' }))
		.not.toBeInTheDocument();
	expect(preparationCount).toBe(preparationCountBeforeUpdate + 2);
});

test('does not carry a failed update label into a later file change', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let preparationSucceeds = false;
	const prepare = async (): Promise<boolean> => preparationSucceeds;
	const renderCandidate = async (
		contents: string,
		version: number,
		editing: boolean,
	): Promise<ReactElement> => (
		<>
			{editing ? <InstallationPreparation prepare={prepare} /> : null}
			{await markdownCanvas(contents, version)}
		</>
	);
	const screen = await render(harness.wrap(await renderCandidate('Original document', 1, true)));
	await screen.rerender(harness.wrap(await renderCandidate('Recovered document', 2, true)));
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(screen.getByRole('status', { name: "Couldn't apply update" })).toBeVisible();

	preparationSucceeds = true;
	await screen.rerender(harness.wrap(await renderCandidate('Recovered document', 2, false)));
	await expect.element(screen.getByText('Recovered document', { exact: true })).toBeVisible();
	await screen.rerender(harness.wrap(await renderCandidate('Recovered document', 2, true)));
	await screen.rerender(harness.wrap(await renderCandidate('Next document', 3, true)));

	await expect.element(screen.getByRole('status', { name: 'File changed' })).toBeVisible();
	await expect
		.element(screen.getByRole('status', { name: "Couldn't apply update" }))
		.not.toBeInTheDocument();
	await expect.element(screen.getByText('Recovered document', { exact: true })).toBeVisible();
});

test('shows no file-changed notice while a routine refresh installs without an active editor', async (): Promise<void> => {
	// Arrange: an editor surface registers installation preparation but holds no edit.
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let releasePreparation: (() => void) | null = null;
	const preparation = new Promise<boolean>((resolve): void => {
		releasePreparation = (): void => resolve(true);
	});
	const renderCandidate = async (contents: string, version: number): Promise<ReactElement> => (
		<>
			<InstallationPreparationWithoutEdit prepare={(): Promise<boolean> => preparation} />
			{await markdownCanvas(contents, version)}
		</>
	);
	const screen = await render(harness.wrap(await renderCandidate('Original document', 1)));

	// Act: a newer candidate arrives and the automatic install is still preparing.
	await screen.rerender(harness.wrap(await renderCandidate('Refreshed document', 2)));

	// Assert: nothing blocks the install, so no notice appears in that window.
	expect(screen.container.querySelector('[role="status"]')).toBeNull();
	await act(async (): Promise<void> => {
		releasePreparation?.();
		await preparation;
	});
	await expect.element(screen.getByText('Refreshed document', { exact: true })).toBeVisible();
	expect(screen.container.querySelector('[role="status"]')).toBeNull();
});

test('does not carry an update failure to a different file', async (): Promise<void> => {
	// Arrange: an update of plan.md failed while an editor held it.
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	const prepare = async (): Promise<boolean> => false;
	const renderCandidate = async (
		contents: string,
		version: number,
		path: string,
		editing: boolean,
	): Promise<ReactElement> => (
		<>
			{editing ? <InstallationPreparation prepare={prepare} /> : null}
			{await markdownCanvas(contents, version, path)}
		</>
	);
	const screen = await render(
		harness.wrap(await renderCandidate('Original document', 1, 'plan.md', true)),
	);
	await screen.rerender(
		harness.wrap(await renderCandidate('Updated document', 2, 'plan.md', true)),
	);
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await expect.element(screen.getByRole('status', { name: "Couldn't apply update" })).toBeVisible();

	// Act: the same canvas moves to another file with no editor holding it.
	await screen.rerender(
		harness.wrap(await renderCandidate('Other document', 3, 'other.md', false)),
	);

	// Assert
	await expect.element(screen.getByText('Other document', { exact: true })).toBeVisible();
	expect(screen.container.querySelector('[role="status"]')).toBeNull();
});

test('does not install a prepared candidate after the canvas becomes inactive', async (): Promise<void> => {
	const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
	let releasePreparation: (() => void) | null = null;
	const preparation = new Promise<boolean>((resolve): void => {
		releasePreparation = (): void => resolve(true);
	});
	const withPreparation = async (
		contents: string,
		version: number,
		active = true,
	): Promise<ReactElement> => {
		const canvas = await markdownCanvas(contents, version);
		return (
			<>
				<InstallationPreparation prepare={(): Promise<boolean> => preparation} />
				{active ? canvas : cloneElement(canvas, { isActive: false })}
			</>
		);
	};
	const screen = await render(harness.wrap(await withPreparation('Original document', 1)));
	await screen.rerender(harness.wrap(await withPreparation('Prepared candidate', 2)));
	await act(async (): Promise<void> => {
		await screen.getByRole('button', { name: 'Update Markdown file' }).click();
	});
	await screen.rerender(harness.wrap(await withPreparation('Prepared candidate', 2, false)));
	await act(async (): Promise<void> => {
		releasePreparation?.();
		await preparation;
	});

	await expect.element(screen.getByText('Original document', { exact: true })).toBeVisible();
	await expect
		.element(screen.getByText('Prepared candidate', { exact: true }))
		.not.toBeInTheDocument();
});

function InstallationPreparation(props: { readonly prepare: () => Promise<boolean> }): null {
	useWorktreeAnnotationEditSurfaceToken('markdown-update-preparation');
	useWorktreeAnnotationEditorInstallationPreparation('markdown-update-preparation', props.prepare);
	return null;
}

function InstallationPreparationWithoutEdit(props: {
	readonly prepare: () => Promise<boolean>;
}): null {
	useWorktreeAnnotationEditorInstallationPreparation('markdown-refresh-preparation', props.prepare);
	return null;
}

function rectanglesOverlap(left: DOMRect, right: DOMRect): boolean {
	return !(
		left.right <= right.left ||
		left.left >= right.right ||
		left.bottom <= right.top ||
		left.top >= right.bottom
	);
}

function savedThread(version: number, line: number): WorktreeAnnotationThreadProjection {
	return {
		context: {
			scope: 'located',
			path: 'plan.md',
			sourceIdentity: `plan-descriptor-${version}`,
			sourceRole: 'file',
			diffSide: null,
			placement: version === 1 ? 'exact' : 'relocated',
			resolution: 'open',
			startLine: line,
			endLine: line,
			threadId: annotationHeadThreadId,
		},
		messages: [
			{
				...annotationMessage({
					messageId: '00000000-0000-7000-8000-000000000091',
					threadId: annotationHeadThreadId,
				}),
				savedBody: 'Saved second target',
			},
		],
	};
}
