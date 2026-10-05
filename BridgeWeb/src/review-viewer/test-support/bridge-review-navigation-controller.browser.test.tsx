import { act, type ReactElement } from 'react';
import { afterEach, describe, expect, test } from 'vitest';
import { cleanup, render, type RenderResult } from 'vitest-browser-react';

import { ReviewNavigationControllerProbe } from './bridge-review-navigation-controller.browser.test-support.js';

describe('Bridge Review navigation controller', () => {
	afterEach(async (): Promise<void> => {
		await cleanup();
	});

	test.each(['Replay binding', 'Replay source'] as const)(
		'preserves user selection through %s, then honors a new logical command',
		async (replayAction): Promise<void> => {
			// Arrange: the original explicit target has already been applied.
			const events: string[] = [];
			const rendered = await renderInsideAct(<ReviewNavigationControllerProbe events={events} />);
			await expect
				.element(rendered.getByTestId('review-navigation-selection'))
				.toHaveTextContent('item-one');
			await clickInsideAct(rendered, 'Select item-two as user');
			await expect
				.element(rendered.getByTestId('review-navigation-selection'))
				.toHaveTextContent('item-two');
			const beforeReplay = events.length;

			// Act: worker replacement rebinds the same logical target.
			await clickInsideAct(rendered, replayAction);

			// Assert: replay does not commit an older target; a new command remains authoritative.
			expect(events.slice(beforeReplay)).toEqual([]);
			await expect
				.element(rendered.getByTestId('review-navigation-selection'))
				.toHaveTextContent('item-two');
			await clickInsideAct(rendered, 'Navigate with new command');
			await expect
				.element(rendered.getByTestId('review-navigation-selection'))
				.toHaveTextContent('item-one');
			expect(events.slice(beforeReplay)).toEqual(['select:item-one:programmatic']);
		},
	);

	test('does not reactivate an earlier consumed command after a newer command', async (): Promise<void> => {
		const events: string[] = [];
		const rendered = await renderInsideAct(<ReviewNavigationControllerProbe events={events} />);
		await clickInsideAct(rendered, 'Navigate with new command');
		await clickInsideAct(rendered, 'Select item-two as user');
		const beforeReplay = events.length;
		await clickInsideAct(rendered, 'Replay earlier command');
		expect(events.slice(beforeReplay)).toEqual([]);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-two');
		expect(events.slice(beforeReplay)).toEqual([]);
	});

	test('user selection supersedes a retained target before it enters the projection', async (): Promise<void> => {
		const events: string[] = [];
		const rendered = await renderInsideAct(
			<ReviewNavigationControllerProbe events={events} initialTargetPending />,
		);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('none');
		await clickInsideAct(rendered, 'Select item-two as user');
		const beforeReveal = events.length;
		await clickInsideAct(rendered, 'Reveal pending target');
		expect(events.slice(beforeReveal)).toEqual([]);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-two');
		expect(events.slice(beforeReveal)).toEqual([]);
		await clickInsideAct(rendered, 'Navigate with new command');
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-one');
	});

	test('clicking the already-selected item supersedes an unapplied retained target', async (): Promise<void> => {
		const events: string[] = [];
		const rendered = await renderInsideAct(
			<ReviewNavigationControllerProbe
				events={events}
				initialTargetPending
				initialSelectedItemId="item-two"
			/>,
		);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-two');
		await clickInsideAct(rendered, 'Select item-two as user');
		const beforeReveal = events.length;
		await clickInsideAct(rendered, 'Reveal pending target');
		expect(events.slice(beforeReveal)).toEqual([]);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-two');
	});

	test('a retained target still applies when it becomes available without a user selection', async (): Promise<void> => {
		const events: string[] = [];
		const rendered = await renderInsideAct(
			<ReviewNavigationControllerProbe events={events} initialTargetPending />,
		);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('none');
		const beforeReveal = events.length;
		await clickInsideAct(rendered, 'Reveal pending target');
		expect(events.slice(beforeReveal)).toEqual(['select:item-one:programmatic']);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('item-one');
	});

	test('does not apply a retained command after its admission is revoked', async () => {
		// Arrange
		const events: string[] = [];

		// Act
		const rendered = await renderInsideAct(
			<ReviewNavigationControllerProbe
				events={events}
				isNavigationCommandStillEligible={(): boolean => false}
			/>,
		);

		// Assert
		expect(events).toEqual([]);
		await expect
			.element(rendered.getByTestId('review-navigation-selection'))
			.toHaveTextContent('none');
	});
});

async function renderInsideAct(element: ReactElement): Promise<RenderResult> {
	let rendered: RenderResult | null = null;
	await act(async (): Promise<void> => {
		rendered = await render(element);
		await Promise.resolve();
	});
	if (rendered === null) throw new Error('Expected Browser render result.');
	return rendered;
}

async function clickInsideAct(rendered: RenderResult, buttonName: string): Promise<void> {
	await act(async (): Promise<void> => {
		await rendered.getByRole('button', { name: buttonName, exact: true }).click();
	});
}
