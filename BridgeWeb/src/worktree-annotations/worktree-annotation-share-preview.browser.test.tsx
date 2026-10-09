import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';
import { page } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	WorktreeAnnotationSharePreview,
	type WorktreeAnnotationSharePreviewReadiness,
} from './worktree-annotation-share-preview.js';
import {
	deriveWorktreeAnnotationShareProjection,
	type FilteredShareThread,
} from './worktree-annotation-share-projection.js';
import type { WorktreeAnnotationThreadProjection } from './worktree-annotation-surface-client.js';

describe('worktree annotation Share preview', () => {
	test('first Comments read uses the common card skeleton rather than loading copy', async () => {
		await render(
			<WorktreeAnnotationSharePreview
				scope="all"
				inlineThreads={[]}
				otherThreads={[]}
				readiness="unknown"
			/>,
		);
		expect(
			document
				.querySelector('[data-bridge-region="comments"]')
				?.getAttribute('data-presentation-state'),
		).toBe('loading');
		expect(
			document.querySelector('[data-skeleton-shape="comments"] [data-slot="skeleton"]'),
		).not.toBeNull();
		expect(document.body.textContent).not.toContain('Loading comments');
	});
	test('renders every supplied saved message with literal body, context, author, and no interactions', async () => {
		const markdownLookingBody =
			'# Not a heading\n[not a link](https://example.com)\n' + 'x'.repeat(600);
		const rendered = await render(
			<div className="w-[320px] p-2">
				<WorktreeAnnotationSharePreview
					scope="all"
					inlineThreads={[
						threadFixture({
							endLine: 14,
							messages: [
								messageFixture('human-inline', 'First line\nSecond line', 'human'),
								{ ...messageFixture('agent-inline', markdownLookingBody, 'agent'), ordinal: 1 },
							],
							path: 'Sources/Feature/VeryLongDirectoryName/AnotherLongDirectoryName/Inline.swift',
							placement: 'relocated',
							resolution: 'resolved',
							startLine: 12,
							threadId: 'thread-inline',
						}),
					]}
					otherThreads={[
						threadFixture({
							endLine: 7,
							messages: [messageFixture('agent-other', 'Unavailable source body', 'agent')],
							path: 'Sources/Feature/Original.swift',
							placement: 'unavailable',
							resolution: 'open',
							startLine: 7,
							threadId: 'thread-other',
						}),
					]}
					readiness="current"
				/>
			</div>,
		);

		const preview = rendered.getByRole('region', { name: 'Annotation list' }).element();
		const threadCards = preview.querySelectorAll<HTMLElement>('[data-slot="card"]');
		expect(threadCards).toHaveLength(2);
		const inlineThread = preview.querySelector<HTMLElement>('[data-thread-id="thread-inline"]');
		if (inlineThread === null) throw new Error('Expected the inline thread preview.');
		const inlineCard = inlineThread.closest<HTMLElement>('[data-slot="card"]');
		const inlinePath = inlineCard?.querySelector<HTMLElement>('[data-thread-path]') ?? null;
		if (inlinePath === null || inlineCard === null) {
			throw new Error('Expected a file card containing its path and thread.');
		}
		expect(inlineCard.contains(inlinePath)).toBe(true);
		const filename = inlineCard.querySelector<HTMLElement>('[data-slot="card-title"]');
		const directory = inlineCard.querySelector<HTMLElement>('[data-thread-directory]');
		if (filename === null || directory === null) throw new Error('Missing file heading hierarchy');
		expect(filename.textContent).toBe('Inline.swift');
		expect(directory.textContent).toBe(
			'Sources/Feature/VeryLongDirectoryName/AnotherLongDirectoryName',
		);
		expect(inlinePath.title).toBe(
			'Sources/Feature/VeryLongDirectoryName/AnotherLongDirectoryName/Inline.swift',
		);
		expect(directory.scrollWidth).toBeGreaterThan(directory.clientWidth);
		expect(getComputedStyle(directory).direction).toBe('rtl');
		expect(Number(getComputedStyle(filename).fontWeight)).toBeGreaterThan(
			Number(getComputedStyle(directory).fontWeight),
		);
		expect(parseFloat(getComputedStyle(filename).fontSize)).toBeGreaterThan(
			parseFloat(getComputedStyle(directory).fontSize),
		);
		expect(getComputedStyle(filename).color).not.toBe(getComputedStyle(directory).color);
		expect(
			[...inlineCard.querySelectorAll('[data-message-number]')].map(
				(element) => element.textContent,
			),
		).toEqual(['1 of 2', '2 of 2']);
		expect(inlineCard.querySelectorAll('[data-message-id]')).toHaveLength(2);
		expect(inlineCard.textContent).toContain('You');
		expect(inlineCard.textContent).toContain('Agent');
		expect(inlineCard.textContent).toContain('12–14');
		expect(inlineCard.querySelector('[data-slot="avatar-fallback"]')?.textContent).toBe('Y');
		expect(getComputedStyle(inlineCard).backgroundColor).toBe('rgb(39, 44, 52)');
		expect(getComputedStyle(inlineCard).borderStyle).toBe('solid');
		expect(getComputedStyle(inlineCard).borderRadius).toBe('8px');
		expect(preview.querySelectorAll('[data-message-id]')).toHaveLength(3);
		expect(preview.querySelector('[data-message-id="human-inline"]')?.textContent).toContain(
			'First line\nSecond line',
		);
		expect(preview.querySelector('[data-message-id="agent-inline"]')?.textContent).toContain(
			markdownLookingBody,
		);
		expect(preview.querySelector('[data-message-id="agent-other"]')?.textContent).toContain(
			'Unavailable source body',
		);
		expect(preview.textContent).toContain('Inline.swift');
		expect(preview.textContent).toContain('12–14');
		expect(preview.textContent).toContain('Original.swift');
		expect(preview.textContent).toContain('7');
		await expect
			.element(rendered.getByRole('img', { name: 'Location updated to follow source changes' }))
			.toBeVisible();
		await expect
			.element(rendered.getByRole('img', { name: 'Source unavailable in this viewer' }))
			.toBeVisible();
		await expect
			.element(rendered.getByRole('img', { name: 'Resolved conversation' }))
			.toBeVisible();
		expect(preview.textContent).toContain('You');
		expect(preview.textContent).toContain('Agent');
		expect(preview.querySelector('a, button, input, textarea, [role="checkbox"]')).toBeNull();
		const humanBody = preview.querySelector<HTMLElement>(
			'[data-message-id="human-inline"] .whitespace-pre-wrap',
		);
		if (humanBody === null) throw new Error('Expected the complete human body.');
		const lineLabel = inlineThread.querySelector('[data-thread-range]');
		if (lineLabel === null) throw new Error('Expected the thread line label.');
		expect(lineLabel.getBoundingClientRect().right).toBeCloseTo(
			lineLabel.parentElement?.parentElement?.getBoundingClientRect().right ?? 0,
			1,
		);
		expect(lineLabel.getBoundingClientRect().top).toBeCloseTo(
			directory.getBoundingClientRect().top,
			1,
		);
		expect(directory.getBoundingClientRect().right).toBeLessThan(
			lineLabel.getBoundingClientRect().left,
		);
		const author = inlineCard.querySelector(
			'[data-message-id="human-inline"] [data-slot="item-metadata"]',
		);
		const avatar = inlineCard.querySelector(
			'[data-message-id="human-inline"] [data-slot="avatar"]',
		);
		if (author === null || avatar === null) throw new Error('Missing shared message anatomy');
		expect(
			Math.abs(humanBody.getBoundingClientRect().left - author.getBoundingClientRect().left),
		).toBeLessThanOrEqual(1);
		expect(author.getBoundingClientRect().left).toBeGreaterThan(
			avatar.getBoundingClientRect().right,
		);
		const timeline = inlineCard.querySelector<HTMLElement>('.bg-annotation-border');
		if (timeline === null) throw new Error('Missing shared timeline between replies');
		expect(inlineCard.querySelectorAll('.bg-annotation-border')).toHaveLength(1);
		expect(timeline.getBoundingClientRect().height).toBeGreaterThan(0);
		expect(timeline.getBoundingClientRect().width).toBe(1);
		expect(timeline.getBoundingClientRect().left + 0.5).toBeCloseTo(
			avatar.getBoundingClientRect().left + avatar.getBoundingClientRect().width / 2,
			1,
		);
		expect(
			inlineCard.querySelector('[data-message-id="agent-inline"] .bg-annotation-border'),
		).toBeNull();
		expect(avatar.getBoundingClientRect().left - filename.getBoundingClientRect().left).toBeCloseTo(
			8,
			1,
		);
		expect(
			avatar.getBoundingClientRect().top - directory.getBoundingClientRect().bottom,
		).toBeCloseTo(16, 1);
		expect(getComputedStyle(humanBody).whiteSpace).toBe('pre-wrap');
		expect(getComputedStyle(humanBody).fontSize).toBe('12px');
		const longBody = preview.querySelector<HTMLElement>('[data-message-id="agent-inline"] p');
		if (longBody === null) throw new Error('Expected the complete long body.');
		expect(longBody.scrollWidth).toBeLessThanOrEqual(longBody.clientWidth);
		expect(preview.getBoundingClientRect().right).toBeLessThanOrEqual(
			preview.parentElement?.getBoundingClientRect().right ?? 0,
		);
		await page.screenshot({
			element: preview,
			path: '../../../tmp/bridgeweb-worktree-annotation-share-preview.png',
		});
	});

	test('renders 3 of 10 for the third full-thread message when it is the only pending message', async () => {
		const thread = threadFixture({
			threadId: 'thread-ten',
			path: 'Sources/Ten.swift',
			startLine: 1,
			endLine: 1,
			placement: 'exact',
			resolution: 'open',
			messages: Array.from({ length: 10 }, (_, index) => ({
				...messageFixture(`message-${index + 1}`, `Message body ${index + 1}`, 'human'),
				ordinal: index,
				handled: index !== 2,
			})),
		});
		const projection = deriveWorktreeAnnotationShareProjection({
			scope: 'pending',
			threads: [thread],
		});
		const rendered = await render(
			<WorktreeAnnotationSharePreview
				scope="pending"
				inlineThreads={projection.inlineThreads}
				otherThreads={projection.otherThreads}
				readiness="current"
			/>,
		);
		await expect.element(rendered.getByText('3 of 10', { exact: true })).toBeVisible();
		expect(
			rendered
				.getByRole('region', { name: 'Annotation list' })
				.element()
				.querySelectorAll('[data-message-id]'),
		).toHaveLength(1);
	});

	test.each([
		{
			name: 'normal',
			placement: 'exact',
			sourceRole: 'file',
			resolution: 'open',
			status: null,
			destination: 'Files',
		},
		{
			name: 'original side',
			placement: 'exact',
			sourceRole: 'review_base',
			resolution: 'open',
			status: 'Original version of this file',
			destination: 'Review',
		},
		{
			name: 'outdated',
			placement: 'outdated',
			sourceRole: 'review_head',
			resolution: 'open',
			status: 'Outdated location in this viewer',
			destination: 'Review',
		},
		{
			name: 'unavailable',
			placement: 'unavailable',
			sourceRole: 'file',
			resolution: 'open',
			status: 'Source unavailable in this viewer',
			destination: null,
		},
		{
			name: 'resolved',
			placement: 'exact',
			sourceRole: 'file',
			resolution: 'resolved',
			status: 'Resolved conversation',
			destination: 'Files',
		},
		{
			name: 'resolved original side',
			placement: 'exact',
			sourceRole: 'review_base',
			resolution: 'resolved',
			status: 'Original version of this file',
			destination: 'Review',
		},
	] as const)(
		'keeps the $name header in two rows with explicit metadata meanings',
		async (state) => {
			const base = threadFixture({
				endLine: 14,
				startLine: 12,
				messages: [messageFixture('state-message', 'Saved body', 'human')],
				path: 'Sources/Feature/Example.swift',
				placement: state.placement,
				resolution: state.resolution,
				threadId: 'state-thread',
			});
			const thread = { ...base, context: { ...base.context, sourceRole: state.sourceRole } };
			const rendered = await render(
				<div style={{ width: 480 }}>
					<WorktreeAnnotationSharePreview
						scope="all"
						inlineThreads={[thread]}
						otherThreads={[]}
						readiness="current"
						activeSurface="file"
						onOpenThread={(): void => {}}
					/>
				</div>,
			);
			const card = rendered
				.getByRole('region', { name: 'Annotation list' })
				.element()
				.querySelector('[data-slot="card"]');
			const header = card?.querySelector('[data-slot="card-header"]');
			if (card === null || card === undefined || header === null || header === undefined)
				throw new Error('Missing state card');
			expect(header.children).toHaveLength(2);
			for (const metadataRow of header.querySelectorAll('[data-slot="item-description"]')) {
				const label = metadataRow.querySelector('[data-slot="item-metadata"]');
				if (label === null) throw new Error('Missing metadata label');
				const labelBounds = label.getBoundingClientRect();
				for (const icon of metadataRow.querySelectorAll('svg')) {
					const iconBounds = icon.getBoundingClientRect();
					expect(
						Math.abs(
							iconBounds.top + iconBounds.height / 2 - labelBounds.top - labelBounds.height / 2,
						),
					).toBeLessThanOrEqual(0.5);
				}
			}
			expect(card.querySelector('button')).toBeNull();
			expect(card.querySelector('[data-thread-range]')?.textContent).toBe('12–14');
			if (state.status !== null)
				await expect.element(rendered.getByRole('img', { name: state.status })).toBeVisible();
			if (state.resolution === 'resolved')
				await expect
					.element(rendered.getByRole('img', { name: 'Resolved conversation' }))
					.toBeVisible();
			if (state.destination === null) expect(card.getAttribute('role')).toBeNull();
			else
				await expect.element(rendered.getByText(state.destination, { exact: true })).toBeVisible();
		},
	);

	test.each([
		['current', 'No annotations yet.'],
		['unknown', ''],
		['unconfirmed', ''],
	] satisfies readonly (readonly [WorktreeAnnotationSharePreviewReadiness, string])[])(
		'renders the %s empty/readiness state without interactive descendants',
		async (readiness, expectedText) => {
			const rendered = await render(
				<WorktreeAnnotationSharePreview
					scope="all"
					inlineThreads={[]}
					otherThreads={[]}
					readiness={readiness}
				/>,
			);
			const state = document.querySelector('[data-bridge-region="comments"]');
			if (state === null) throw new Error('Expected Comments region');
			if (readiness === 'current')
				await expect.element(rendered.getByText(expectedText)).toBeVisible();
			else {
				expect(state.getAttribute('data-presentation-state')).toBe('loading');
				expect(state.querySelector('[data-slot="skeleton"]')).not.toBeNull();
			}
			expect(state.querySelector('a, button, input, textarea, [role="checkbox"]')).toBeNull();
		},
	);

	test('labels supplied last-known content as unconfirmed', async () => {
		const rendered = await render(
			<WorktreeAnnotationSharePreview
				scope="all"
				inlineThreads={[
					threadFixture({
						endLine: 3,
						messages: [messageFixture('unconfirmed-message', 'Last known saved body', 'human')],
						path: 'Sources/Unconfirmed.swift',
						placement: 'exact',
						resolution: 'open',
						startLine: 3,
						threadId: 'thread-unconfirmed',
					}),
				]}
				otherThreads={[]}
				readiness="unconfirmed"
			/>,
		);

		await expect.element(rendered.getByText('Last known comments')).toBeVisible();
		await expect.element(rendered.getByText('Last known saved body')).toBeVisible();
	});
});

function threadFixture(props: {
	readonly endLine: number;
	readonly messages: readonly WorktreeAnnotationThreadProjection['messages'][number][];
	readonly path: string;
	readonly placement: WorktreeAnnotationThreadProjection['context']['placement'];
	readonly resolution: WorktreeAnnotationThreadProjection['context']['resolution'];
	readonly startLine: number;
	readonly threadId: string;
}): FilteredShareThread<WorktreeAnnotationThreadProjection> {
	const thread: WorktreeAnnotationThreadProjection = {
		context: {
			diffSide: 'additions',
			endLine: props.endLine,
			path: props.path,
			placement: props.placement,
			resolution: props.resolution,
			scope: 'located',
			sourceIdentity: `source-${props.threadId}`,
			sourceRole: 'file',
			startLine: props.startLine,
			threadId: props.threadId,
		},
		messages: props.messages,
	};
	const projection = deriveWorktreeAnnotationShareProjection({ scope: 'all', threads: [thread] });
	const result = projection.inlineThreads[0] ?? projection.otherThreads[0];
	if (result === undefined) throw new Error('Fixture requires saved messages');
	return result;
}

function messageFixture(
	messageId: string,
	savedBody: string,
	authorKind: 'agent' | 'human',
): WorktreeAnnotationThreadProjection['messages'][number] {
	return {
		attentionState: authorKind === 'agent' ? 'new' : 'not_applicable',
		authorKind,
		createdAt: 1_786_124_400_000,
		draft: null,
		handled: false,
		messageId,
		messageRevision: 1,
		ordinal: 0,
		savedBody,
		savedRevision: 1,
		sessionId: 'session-preview',
		sessionRevision: 1,
		status: 'locked',
		threadId: 'fixture-thread',
		threadRevision: 1,
	};
}
