import { act } from 'react';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { cleanup, render } from 'vitest-browser-react';

import { createWorktreeAnnotationBrowserProviderHarness } from '../../worktree-annotations/worktree-annotation-browser-test-support.js';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise production styles in the browser.
import '../bridge-app.css';
import { fileItem, fileIntent, markdownCanvas } from './bridge-markdown-annotation-test-support.js';
import { BridgeMarkdownCanvas } from './bridge-markdown-canvas.js';
import { buildBridgeMarkdownRenderWorkerSuccessResponse } from './worker/bridge-markdown-render-worker-renderer.js';

describe('rendered Markdown production annotations', () => {
	beforeEach((): void => {
		const requestFrame = window.requestAnimationFrame.bind(window);
		vi.spyOn(window, 'requestAnimationFrame').mockImplementation((callback): number =>
			requestFrame((timestamp): void => {
				act((): void => callback(timestamp));
			}),
		);
	});

	test('saves through existing durable commands with the painted source descriptor', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(await markdownCanvas('Paragraph to annotate\n\n> Another paragraph')),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeInTheDocument();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
		});
		await act(async (): Promise<void> => {
			await screen
				.getByPlaceholder('Write an annotation in Markdown')
				.fill('Check this source range');
		});
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Save annotation', exact: true }).click();
		});
		await expect
			.poll(() =>
				harness.surface.sentOperations.find((operation) => operation.kind === 'root.create'),
			)
			.toMatchObject({
				origin: {
					kind: 'located',
					path: 'plan.md',
					sourceRole: 'file',
					sourceIdentity: 'plan-descriptor-1',
					startLine: 1,
					endLine: 1,
					diffSide: null,
				},
				body: 'Check this source range',
			});
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'root.create');
		});
		await expect
			.poll(() =>
				harness.surface.sentOperations.some(
					(operation): boolean => operation.kind === 'draft.save',
				),
			)
			.toBe(true);
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'draft.save');
		});
		await expect
			.element(screen.getByText('Check this source range', { exact: true }))
			.toBeVisible();
		await expect
			.element(screen.getByPlaceholder('Write an annotation in Markdown'))
			.not.toBeInTheDocument();
		await expect.element(screen.getByTestId('bridge-markdown-comment-lane')).toBeInTheDocument();
		const article = screen.getByTestId('bridge-markdown-canvas').element();
		const frame = article.parentElement;
		if (frame === null) throw new Error('Missing full-width Markdown frame');
		const selectedBackground = screen.getByTestId('bridge-markdown-source-selection').element();
		await cancelAnnotationPointerGesture(
			screen.getByRole('button', { name: 'Annotate source lines 3–3' }).element(),
		);
		expect(screen.getByTestId('bridge-markdown-source-selection').element()).toBe(
			selectedBackground,
		);
		expect(
			document.querySelector('[data-bridge-markdown-target][data-annotation-active="true"]')
				?.textContent,
		).toBe('Paragraph to annotate');
		const commentLane = screen.getByTestId('bridge-markdown-comment-lane').element();
		expect(selectedBackground.getBoundingClientRect().width).toBeCloseTo(
			frame.getBoundingClientRect().width,
			1,
		);
		expect(commentLane.getBoundingClientRect().width).toBeCloseTo(
			frame.getBoundingClientRect().width,
			1,
		);
		expect(commentLane.getBoundingClientRect().width).toBeGreaterThan(
			article.getBoundingClientRect().width,
		);
		await act(async (): Promise<void> => {
			await screen.getByText('Paragraph to annotate', { exact: true }).click();
		});
		await expect
			.element(screen.getByTestId('bridge-markdown-source-selection'))
			.not.toBeInTheDocument();
		await expect
			.element(screen.getByTestId('bridge-markdown-comment-lane'))
			.toHaveAttribute('data-active', 'false');
		const markedGutter = document.querySelector(
			'[data-bridge-markdown-gutter] [data-commented="true"]',
		);
		if (markedGutter === null) throw new Error('Commented source range lost its persistent stripe');
		expect(markedGutter.getAttribute('data-active')).toBe('false');
		expect(getComputedStyle(markedGutter, '::before').display).toBe('block');
		expect(getComputedStyle(markedGutter, '::before').backgroundImage).toContain('linear-gradient');
		const quote = article.querySelector('blockquote p');
		if (quote === null) throw new Error('Missing quoted source target');
		const inactiveQuoteColor = getComputedStyle(quote).color;
		await act(async (): Promise<void> => {
			await screen.getByText('Check this source range', { exact: true }).click();
			await screen.getByRole('button', { name: 'Annotate source lines 3–3' }).click();
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		expect(getComputedStyle(quote).color).toBe(getComputedStyle(article).color);
		await act(async (): Promise<void> => {
			// Accessibility activation can deliver click without a preceding pointerdown dismissal.
			screen
				.getByText('Check this source range', { exact: true })
				.element()
				.dispatchEvent(new MouseEvent('click', { bubbles: true }));
		});
		expect(screen.getByPlaceholder('Write an annotation in Markdown').query()).toBeNull();
		expect(getComputedStyle(quote).color).toBe(inactiveQuoteColor);
		expect(
			document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
		).toHaveLength(1);
		expect(
			document.querySelector('[data-bridge-markdown-target][data-annotation-active="true"]')
				?.textContent,
		).toBe('Paragraph to annotate');
	});

	test('preserves a typed draft at its original range when another composer replaces it', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(await markdownCanvas('First paragraph\n\nSecond paragraph')),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeVisible();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
			await screen
				.getByPlaceholder('Write an annotation in Markdown')
				.fill('Keep the original draft');
		});
		await expect
			.poll(() =>
				harness.surface.sentOperations.find((operation) => operation.kind === 'root.create'),
			)
			.toMatchObject({ body: 'Keep the original draft', origin: { startLine: 1, endLine: 1 } });
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'root.create');
		});
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 3–3' }).click();
		});
		await expect
			.element(screen.getByPlaceholder('Write an annotation in Markdown'))
			.toHaveValue('');
		await expect
			.poll(() =>
				harness.surface.sentOperations.some((operation) => operation.kind === 'draft.edit.release'),
			)
			.toBe(true);
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'draft.edit.release');
		});
		await expect
			.element(screen.getByText('Keep the original draft', { exact: true }))
			.toBeVisible();
		expect(
			harness.surface.sentOperations.some((operation) => operation.kind === 'draft.revert'),
		).toBe(false);
	});

	test('replaces an empty composer with another range and dismisses it on outside press', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(await markdownCanvas('First paragraph\n\nSecond paragraph')),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeVisible();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		expect(
			screen.getByRole('button', { name: 'Annotate source lines 3–3' }).element(),
		).toBeEnabled();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 3–3' }).click();
		});
		const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
		expect(
			editor.closest('.bridge-markdown-annotation-host')?.previousElementSibling?.textContent,
		).toBe('Second paragraph');
		await act(async (): Promise<void> => {
			await screen.getByText('First paragraph', { exact: true }).click();
		});
		await expect
			.element(screen.getByPlaceholder('Write an annotation in Markdown'))
			.not.toBeInTheDocument();
		expect(
			harness.surface.sentOperations.filter(
				(operation): boolean => operation.kind === 'root.create',
			),
		).toHaveLength(0);
	});

	test('keeps newly typed text and its editor when refresh preparation fails', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(harness.wrap(await markdownCanvas('Original paragraph')));
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeInTheDocument();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
		});
		const editor = screen.getByPlaceholder('Write an annotation in Markdown');
		const originalEditor = editor.element();
		await act(async (): Promise<void> => {
			await editor.fill('Unflushed text');
		});
		await screen.rerender(harness.wrap(await markdownCanvas('Successor paragraph', 2)));
		await expect
			.poll(() =>
				harness.surface.sentOperations.some(
					(operation): boolean => operation.kind === 'root.create',
				),
			)
			.toBe(true);
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentConflict('root.create');
		});
		await expect.element(screen.getByRole('status', { name: 'File changed' })).toBeVisible();
		expect(editor.element()).toBe(originalEditor);
		await expect.element(editor).toHaveValue('Unflushed text');
		await expect.element(screen.getByText('Original paragraph', { exact: true })).toBeVisible();
	});
	afterEach(async (): Promise<void> => {
		await act(async (): Promise<void> => {
			await cleanup();
		});
		vi.restoreAllMocks();
	});

	test('places a table annotation in a full-width row beneath its source row', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(await markdownCanvas('| Name | State |\n| --- | --- |\n| App | Ready |')),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 3–3' }))
			.toBeInTheDocument();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 3–3' }).click();
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
		const cell = editor.closest('td');
		expect(cell?.colSpan).toBe(2);
		expect(
			cell?.parentElement?.previousElementSibling?.getAttribute('data-bridge-markdown-target'),
		).toBe('block-3');
	});

	test.each(['forward', 'reverse'] as const)(
		'yellow-button %s drag opens the composer for the complete range',
		async (direction) => {
			const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
			const screen = await render(
				harness.wrap(await markdownCanvas('First paragraph\n\nSecond paragraph\ncontinued')),
			);
			await expect
				.element(screen.getByRole('button', { name: 'Annotate source lines 3–4' }))
				.toBeVisible();
			const startLabel = direction === 'forward' ? '1–1' : '3–4';
			const endLabel = direction === 'forward' ? '3–4' : '1–1';
			const anchor = screen
				.getByRole('button', { name: `Annotate source lines ${startLabel}` })
				.element();
			const endpoint = screen
				.getByRole('button', { name: `Select source lines ${endLabel}` })
				.element();
			await act(async (): Promise<void> => {
				anchor.dispatchEvent(
					new PointerEvent('pointerdown', {
						bubbles: true,
						cancelable: true,
						pointerId: 42,
						pointerType: 'mouse',
						button: 0,
					}),
				);
			});
			expect(
				document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
			).toHaveLength(1);
			await expect
				.element(screen.getByPlaceholder('Write an annotation in Markdown'))
				.not.toBeInTheDocument();
			const bounds = endpoint.getBoundingClientRect();
			await act(async (): Promise<void> => {
				window.dispatchEvent(
					new PointerEvent('pointermove', {
						pointerId: 42,
						clientX: bounds.left + bounds.width / 2,
						clientY: bounds.top + bounds.height / 2,
					}),
				);
			});
			await act(async (): Promise<void> => {
				window.dispatchEvent(
					new PointerEvent('pointerup', {
						pointerId: 42,
						clientX: bounds.left + bounds.width / 2,
						clientY: bounds.top + bounds.height / 2,
					}),
				);
			});
			await expect
				.element(screen.getByPlaceholder('Write an annotation in Markdown'))
				.toBeVisible();
			expect(
				document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
			).toHaveLength(2);
			const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
			expect(
				editor.closest('.bridge-markdown-annotation-host')?.previousElementSibling?.textContent,
			).toContain('Second paragraph');
		},
	);

	test('handles an uninterrupted Pierre-style pointer gesture while another thread is selected', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(await markdownCanvas('First paragraph\n\nSecond paragraph\ncontinued')),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeVisible();
		await act(async (): Promise<void> => {
			screen
				.getByRole('button', { name: 'Annotate source lines 1–1' })
				.element()
				.dispatchEvent(new MouseEvent('click', { bubbles: true }));
		});
		await act(async (): Promise<void> => {
			await screen.getByPlaceholder('Write an annotation in Markdown').fill('Existing annotation');
		});
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Save annotation', exact: true }).click();
		});
		await expect
			.poll(() =>
				harness.surface.sentOperations.find((operation) => operation.kind === 'root.create'),
			)
			.toBeDefined();
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'root.create');
		});
		await expect
			.poll(() =>
				harness.surface.sentOperations.find((operation) => operation.kind === 'draft.save'),
			)
			.toBeDefined();
		await act(async (): Promise<void> => {
			harness.surface.settleMostRecentCommittedWithoutProjection(undefined, 'draft.save');
		});
		await expect.element(screen.getByText('Existing annotation', { exact: true })).toBeVisible();

		const annotateButton = screen
			.getByRole('button', { name: 'Annotate source lines 3–4' })
			.element();
		const endpoint = screen.getByRole('button', { name: 'Select source lines 3–4' }).element();
		const endpointBounds = endpoint.getBoundingClientRect();
		await act(async (): Promise<void> => {
			annotateButton.dispatchEvent(
				new PointerEvent('pointerdown', {
					bubbles: true,
					cancelable: true,
					pointerId: 73,
					pointerType: 'mouse',
					button: 0,
				}),
			);
			window.dispatchEvent(
				new PointerEvent('pointermove', {
					pointerId: 73,
					clientX: endpointBounds.left + endpointBounds.width / 2,
					clientY: endpointBounds.top + endpointBounds.height / 2,
				}),
			);
			window.dispatchEvent(
				new PointerEvent('pointerup', {
					pointerId: 73,
					clientX: endpointBounds.left + endpointBounds.width / 2,
					clientY: endpointBounds.top + endpointBounds.height / 2,
				}),
			);
		});

		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
		expect(
			editor.closest('.bridge-markdown-annotation-host')?.previousElementSibling?.textContent,
		).toContain('Second paragraph');
	});

	test('reverse number dragging includes the multiline anchor and yellow-button dragging extends that range', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(
			harness.wrap(
				await markdownCanvas('First paragraph\n\nSecond paragraph\ncontinued\n\nThird paragraph'),
			),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Select source lines 3–4' }))
			.toBeVisible();
		const anchor = screen.getByRole('button', { name: 'Select source lines 3–4' }).element();
		const endpoint = screen.getByRole('button', { name: 'Select source lines 1–1' }).element();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
		});
		expect(screen.getByRole('button', { name: 'Select source lines 3–4' }).element()).toBeEnabled();
		await act(async (): Promise<void> => {
			anchor.dispatchEvent(
				new PointerEvent('pointerdown', {
					bubbles: true,
					cancelable: true,
					pointerId: 31,
					pointerType: 'mouse',
					button: 0,
				}),
			);
		});
		const bounds = endpoint.getBoundingClientRect();
		await act(async (): Promise<void> => {
			window.dispatchEvent(
				new PointerEvent('pointermove', { pointerId: 31, clientY: bounds.top + bounds.height / 2 }),
			);
			window.dispatchEvent(new PointerEvent('pointerup', { pointerId: 31 }));
		});
		expect(
			document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
		).toHaveLength(2);
		await act(async (): Promise<void> => {
			screen
				.getByRole('button', { name: 'Annotate source lines 3–4' })
				.element()
				.dispatchEvent(
					new PointerEvent('pointerdown', {
						bubbles: true,
						cancelable: true,
						pointerId: 32,
						pointerType: 'mouse',
						button: 0,
					}),
				);
		});
		expect(
			document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
		).toHaveLength(2);
		const extensionBounds = screen
			.getByRole('button', { name: 'Select source lines 6–6' })
			.element()
			.getBoundingClientRect();
		await act(async (): Promise<void> => {
			window.dispatchEvent(
				new PointerEvent('pointerup', {
					pointerId: 32,
					clientX: extensionBounds.left + extensionBounds.width / 2,
					clientY: extensionBounds.top + extensionBounds.height / 2,
				}),
			);
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		expect(
			document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
		).toHaveLength(3);
	});

	test('cancels yellow-button dragging without opening a composer and retains keyboard activation', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(harness.wrap(await markdownCanvas('Paragraph')));
		const button = screen.getByRole('button', { name: 'Annotate source lines 1–1' });
		await expect.element(button).toBeVisible();
		await cancelAnnotationPointerGesture(button.element());
		await act(async (): Promise<void> => {
			window.dispatchEvent(new PointerEvent('pointerup', { pointerId: 51 }));
		});
		expect(screen.getByPlaceholder('Write an annotation in Markdown').query()).toBeNull();
		expect(
			document.querySelectorAll('[data-bridge-markdown-target][data-annotation-active="true"]'),
		).toHaveLength(0);
		await act(async (): Promise<void> => {
			button.element().dispatchEvent(new MouseEvent('click', { bubbles: true }));
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
		await cancelAnnotationPointerGesture(button.element());
		expect(screen.getByPlaceholder('Write an annotation in Markdown').element()).toBe(editor);
	});

	test('retains the same editor while a successor waits and disables new annotation admission', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const screen = await render(harness.wrap(await markdownCanvas('Original paragraph')));
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeInTheDocument();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 1–1' }).click();
		});
		const editor = screen.getByPlaceholder('Write an annotation in Markdown').element();
		await screen.rerender(harness.wrap(await markdownCanvas('Replacement paragraph', 2)));
		await expect.element(screen.getByText('Original paragraph', { exact: true })).toBeVisible();
		expect(screen.getByPlaceholder('Write an annotation in Markdown').element()).toBe(editor);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 1–1' }))
			.toBeDisabled();
		expect(
			harness.surface.sentOperations.filter(
				(operation): boolean => operation.kind === 'root.create',
			),
		).toHaveLength(0);
	});
	test('opens the real composer for one nested task without including its child', async () => {
		const harness = createWorktreeAnnotationBrowserProviderHarness('fileView');
		const markdown = '# Plan\n\n- [ ] Parent\n  - [x] Child';
		const item = fileItem(markdown);
		const intent = fileIntent(item);
		const response = await buildBridgeMarkdownRenderWorkerSuccessResponse({
			request: {
				...intent,
				schemaVersion: 1,
				method: 'markdown.render',
				requestId: 'markdown-annotation-test',
			},
		});
		const screen = await render(
			harness.wrap(
				<BridgeMarkdownCanvas
					isActive={true}
					annotationSource={{ item }}
					retry={(): void => {}}
					presentationState={{
						status: 'ready',
						refresh: { kind: 'current' },
						identity: response,
						renderResult: response,
						sourcePath: 'plan.md',
					}}
					renderFulfillment={{
						intent,
						selectedItem: item,
						coordinator: {
							observePostRender: (): void => {},
							reconcilePublication: (): void => {},
						},
					}}
				/>,
			),
		);
		await expect
			.element(screen.getByRole('button', { name: 'Annotate source lines 3–3' }))
			.toBeInTheDocument();
		await act(async (): Promise<void> => {
			await screen.getByRole('button', { name: 'Annotate source lines 3–3' }).click();
		});
		await expect.element(screen.getByPlaceholder('Write an annotation in Markdown')).toBeVisible();
		const selected = document.querySelectorAll(
			'[data-bridge-markdown-target][data-annotation-active="true"]',
		);
		expect(selected).toHaveLength(1);
		expect(selected[0]?.textContent).toContain('Parent');
		expect(selected[0]?.textContent).not.toContain('Child');
	});
});

async function cancelAnnotationPointerGesture(button: Element): Promise<void> {
	await act(async (): Promise<void> => {
		button.dispatchEvent(
			new PointerEvent('pointerdown', {
				bubbles: true,
				cancelable: true,
				pointerId: 51,
				pointerType: 'mouse',
				button: 0,
			}),
		);
	});
	await act(async (): Promise<void> => {
		window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 51 }));
	});
}
