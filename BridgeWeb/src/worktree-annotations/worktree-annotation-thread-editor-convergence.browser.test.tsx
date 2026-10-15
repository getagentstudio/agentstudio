import { act, type ReactElement } from 'react';
import { describe, expect, test } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../app/bridge-app.css';
import {
	annotationHeadThreadId,
	annotationMessage,
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import type { WorktreeAnnotationThreadProjection } from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationActiveEditTokens,
	useWorktreeAnnotationEditSurfaceToken,
	useWorktreeAnnotationProjection,
	WorktreeAnnotationSurfaceProvider,
} from './worktree-annotation-surface-provider.js';
import {
	locatedContext,
	makeSavedMessage,
	publishThreadMessages,
	renderAnnotationProjection,
	renderRemountingAnnotationProjection,
	rootMessageId,
	secondRootMessageId,
	settleBrowserCondition,
} from './worktree-annotation-thread.browser.test-support.js';
import {
	WorktreeAnnotationNewMessageComposer,
	WorktreeAnnotationThread,
} from './worktree-annotation-thread.js';

describe('worktree annotation editor convergence', () => {
	test('keeps foreground annotation metadata stable during projection refresh', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderAnnotationProjection(surface);
		const root = makeSavedMessage({ body: 'Root body.', messageId: rootMessageId });
		const reply = makeSavedMessage({
			body: 'Saved reply.',
			messageId: secondRootMessageId,
			ordinal: 1,
		});

		await publishThreadMessages(surface, [root, reply]);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).last().click();
			surface.publishRefreshing();
			await Promise.resolve();
		});

		expect(document.body).not.toHaveTextContent('Refreshing');
		await expect
			.element(rendered.getByRole('textbox', { name: 'Reply with Markdown' }))
			.toBeVisible();
	});

	test('keeps the composer as the only reply owner until saved projection converges', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderAnnotationProjection(surface);
		const root = makeSavedMessage({ body: 'Root body.', messageId: rootMessageId });
		await publishThreadMessages(surface, [root]);

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).click();
			await rendered
				.getByRole('textbox', { name: 'Reply with Markdown' })
				.fill('Single-owner reply');
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected the reply edit to create its durable draft.',
		);
		const createOperation = surface.sentOperations.find(
			(operation) => operation.kind === 'reply.create',
		);
		if (createOperation?.kind !== 'reply.create') throw new Error('Expected reply.create.');

		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted(annotationSessionId, 1);
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [
					{ ...root, sessionRevision: 4 },
					{
						...annotationMessage({
							messageId: secondRootMessageId,
							ordinal: 1,
							sessionRevision: 4,
							threadId: annotationHeadThreadId,
							threadRevision: 2,
						}),
						draft: {
							activeEditToken: createOperation.editToken,
							body: 'Single-owner reply',
							revision: 0,
						},
						savedBody: null,
						savedRevision: null,
					},
				],
			});
			await Promise.resolve();
			await rendered.getByRole('button', { name: 'Save annotation' }).click();
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'draft.save'),
			'Expected reply Save to issue draft.save.',
		);
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommittedWithoutProjection(annotationSessionId, 'draft.save');
			await Promise.resolve();
		});

		await expect.element(rendered.getByText('Single-owner reply')).toBeVisible();
		expect(
			document.querySelector('[data-testid="worktree-annotation-committed-pending-projection"]'),
		).toBeNull();
		expect(rendered.getByRole('button', { name: 'Reply to annotation thread' }).all()).toHaveLength(
			1,
		);
		expect(rendered.getByTestId('worktree-annotation-message').all()).toHaveLength(2);

		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 1,
				revision: 5,
				sessions: [annotationSessionSummary({ revision: 5, sessionId: annotationSessionId })],
			});
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [
					{ ...root, sessionRevision: 5 },
					{
						...annotationMessage({
							messageId: secondRootMessageId,
							ordinal: 1,
							sessionRevision: 5,
							threadId: annotationHeadThreadId,
							threadRevision: 2,
						}),
						draft: null,
						savedBody: 'Single-owner reply',
						savedRevision: 1,
					},
				],
			});
			await Promise.resolve();
		});
		await settleBrowserCondition(
			(): boolean =>
				document.querySelector(
					'[data-testid="worktree-annotation-committed-pending-projection"]',
				) === null,
			'Expected the saved annotation message to replace its committed preview.',
		);

		expect(
			document.querySelector('[data-testid="worktree-annotation-committed-pending-projection"]'),
		).toBeNull();
		expect(rendered.getByRole('button', { name: 'Reply to annotation thread' }).all()).toHaveLength(
			1,
		);
		expect(rendered.getByTestId('worktree-annotation-message').all()).toHaveLength(2);
	});

	test('reverts a durable reply draft instead of only hiding its composer', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderRemountingAnnotationProjection(surface);
		const root = makeSavedMessage({ body: 'Root body.', messageId: rootMessageId });

		await publishThreadMessages(surface, [root]);
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).click();
			await rendered.getByRole('textbox', { name: 'Reply with Markdown' }).fill('Durable reply');
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected the first reply edit to create a durable draft.',
		);
		const createOperation = surface.sentOperations.find(
			(operation) => operation.kind === 'reply.create',
		);
		if (createOperation?.kind !== 'reply.create') throw new Error('Expected reply.create.');

		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted();
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [
					{ ...root, sessionRevision: 4 },
					{
						...annotationMessage({
							messageId: secondRootMessageId,
							ordinal: 1,
							sessionRevision: 4,
							threadId: annotationHeadThreadId,
						}),
						draft: {
							activeEditToken: createOperation.editToken,
							body: 'Durable reply',
							revision: 1,
						},
						savedBody: null,
						savedRevision: null,
					},
				],
			});
			await Promise.resolve();
		});
		await settleBrowserCondition(
			(): boolean => document.querySelector('[data-annotation-draft="present"]') !== null,
			'Expected the remounted composer to adopt its durable reply draft.',
		);
		await expect.element(rendered.getByText('Draft')).toBeVisible();

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Revert annotation draft' }).click();
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'draft.revert'),
			'Expected Revert to issue draft.revert.',
		);
		expect(surface.sentOperations.at(-1)).toMatchObject({
			kind: 'draft.revert',
			messageId: secondRootMessageId,
		});
	});

	test('adopts durable detail that arrives after the composer remounts', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const editToken = 'annotation-edit-remounted-reply';
		const rendered = await render(
			<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
				<ProjectionRemountingReplyComposer editToken={editToken} />
			</WorktreeAnnotationSurfaceProvider>,
		);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				revision: 3,
				sessions: [annotationSessionSummary({ revision: 3, sessionId: annotationSessionId })],
			});
			await rendered.getByRole('textbox', { name: 'Reply with Markdown' }).fill('Durable reply');
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected the first reply edit to create a durable draft.',
		);

		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted(annotationSessionId, 1);
			await Promise.resolve();
		});
		await expect
			.element(rendered.getByRole('textbox', { name: 'Reply with Markdown' }))
			.toHaveValue('Durable reply');

		await act(async (): Promise<void> => {
			surface.publishThread({
				context: locatedContext,
				message: {
					...annotationMessage({
						messageId: secondRootMessageId,
						ordinal: 1,
						sessionRevision: 4,
						threadId: annotationHeadThreadId,
					}),
					draft: { activeEditToken: editToken, body: 'Durable reply', revision: 1 },
					savedBody: null,
					savedRevision: null,
				},
			});
			await Promise.resolve();
		});
		await settleBrowserCondition(
			(): boolean => document.querySelector('[data-annotation-draft="present"]') !== null,
			'Expected the surviving composer to adopt delayed durable detail.',
		);
		await expect
			.element(rendered.getByRole('textbox', { name: 'Reply with Markdown' }))
			.toHaveValue('Durable reply');
		expect(document.querySelectorAll('[aria-label="Reply with Markdown"]')).toHaveLength(1);
	});

	test('completes the first Save across a durable projection remount', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const editToken = 'annotation-edit-save-across-remount';
		const rendered = await render(
			<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
				<ProjectionRemountingReplyComposer editToken={editToken} />
			</WorktreeAnnotationSurfaceProvider>,
		);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				expectedThreadCount: 0,
				revision: 3,
				sessions: [annotationSessionSummary({ revision: 3, sessionId: annotationSessionId })],
			});
			await rendered
				.getByRole('textbox', { name: 'Reply with Markdown' })
				.fill('Save across replacement');
			await rendered.getByRole('button', { name: 'Save annotation' }).click();
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected first Save to create the durable reply draft.',
		);
		const createOperation = surface.sentOperations.find(
			(operation) => operation.kind === 'reply.create',
		);
		if (createOperation?.kind !== 'reply.create') throw new Error('Expected reply.create.');

		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted(annotationSessionId, 1);
			surface.publishThread({
				context: locatedContext,
				message: {
					...annotationMessage({
						messageId: secondRootMessageId,
						ordinal: 1,
						sessionRevision: 4,
						threadId: annotationHeadThreadId,
					}),
					draft: {
						activeEditToken: createOperation.editToken,
						body: 'Save across replacement',
						revision: 0,
					},
					savedBody: null,
					savedRevision: null,
				},
			});
			await Promise.resolve();
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'draft.save'),
			'Expected the original Save action to continue after the Pierre portal remount.',
		);
		expect(
			surface.sentOperations
				.map((operation) => operation.kind)
				.filter((kind) => kind !== 'session.discover'),
		).toEqual([
			'demand.acquire',
			'source.refresh',
			'output.history',
			'reply.create',
			'output.history',
			'draft.save',
		]);
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted(annotationSessionId, 1);
			surface.publishThread({
				context: locatedContext,
				message: {
					...annotationMessage({
						messageId: secondRootMessageId,
						ordinal: 1,
						sessionRevision: 5,
						threadId: annotationHeadThreadId,
					}),
					draft: null,
					savedBody: 'Save across replacement',
					savedRevision: 1,
				},
			});
			await Promise.resolve();
		});
		await expect.element(rendered.getByRole('button', { name: 'Save annotation' })).toBeVisible();
	});

	test('opens a fresh second Reply before the first saved projection converges', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rendered = await renderAnnotationProjection(surface);
		const rootMessage = makeSavedMessage({ body: 'Root body.', messageId: rootMessageId });
		await publishThreadMessages(surface, [rootMessage]);

		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).click();
			await rendered.getByRole('textbox', { name: 'Reply with Markdown' }).fill('Reply one');
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected Reply one to create its durable draft.',
		);
		const firstReplyCreate = surface.sentOperations.find(
			(operation) => operation.kind === 'reply.create',
		);
		if (firstReplyCreate?.kind !== 'reply.create') throw new Error('Expected reply.create.');

		await act(async (): Promise<void> => {
			surface.settleMostRecentCommitted(annotationSessionId, 1);
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [
					{ ...rootMessage, sessionRevision: 4 },
					{
						...annotationMessage({
							messageId: secondRootMessageId,
							ordinal: 1,
							sessionRevision: 4,
							threadId: annotationHeadThreadId,
							threadRevision: 2,
						}),
						draft: {
							activeEditToken: firstReplyCreate.editToken,
							body: 'Reply one',
							revision: 0,
						},
						savedBody: null,
						savedRevision: null,
					},
				],
			});
			await Promise.resolve();
		});
		await act(async (): Promise<void> => {
			await rendered.getByRole('button', { name: 'Save annotation' }).click();
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'draft.save'),
			'Expected Reply one Save to issue draft.save.',
		);
		await act(async (): Promise<void> => {
			surface.settleMostRecentCommittedWithoutProjection(annotationSessionId, 'draft.save');
			await Promise.resolve();
		});
		await expect.element(rendered.getByText('Reply one')).toBeVisible();
		expect(
			document.querySelector('[data-testid="worktree-annotation-committed-pending-projection"]'),
		).toBeNull();

		const latestReplyButton = rendered
			.getByRole('button', { name: 'Reply to annotation thread' })
			.all()
			.at(-1);
		if (latestReplyButton === undefined) throw new Error('Expected the latest Reply control.');
		await act(async (): Promise<void> => {
			await latestReplyButton.click();
		});
		const secondReplyComposer = rendered.getByRole('textbox', { name: 'Reply with Markdown' });
		await expect.element(secondReplyComposer).toBeVisible();

		await act(async (): Promise<void> => {
			surface.publishThreadMessages({
				context: locatedContext,
				messages: [
					{ ...rootMessage, sessionRevision: 5 },
					{
						...annotationMessage({
							messageId: secondRootMessageId,
							ordinal: 1,
							sessionRevision: 5,
							threadId: annotationHeadThreadId,
							threadRevision: 2,
						}),
						draft: null,
						savedBody: 'Reply one',
						savedRevision: 1,
					},
				],
			});
			await Promise.resolve();
		});
		await expect.element(secondReplyComposer).toBeVisible();
	});

	test('uses the exact command receipt revision when a stable thread render lags', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const rootMessage = makeSavedMessage({ body: 'Root body.', messageId: rootMessageId });
		const stableThread: WorktreeAnnotationThreadProjection = {
			context: locatedContext,
			messages: [rootMessage],
		};
		const rendered = await render(
			<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
				<WorktreeAnnotationThread thread={stableThread} />
			</WorktreeAnnotationSurfaceProvider>,
		);
		await publishThreadMessages(surface, [rootMessage]);
		await act(async (): Promise<void> => {
			surface.publishProjectionState({
				commandOutcomes: [
					{
						receipt: {
							context: {
								diffSide: locatedContext.diffSide,
								endLine: locatedContext.endLine,
								path: locatedContext.path,
								resolution: locatedContext.resolution,
								scope: locatedContext.scope,
								sourceIdentity: locatedContext.sourceIdentity,
								sourceRole: locatedContext.sourceRole,
								startLine: locatedContext.startLine,
								threadId: locatedContext.threadId,
							},
							kind: 'message',
							message: {
								...annotationMessage({
									messageId: secondRootMessageId,
									ordinal: 1,
									sessionRevision: 4,
									threadId: annotationHeadThreadId,
									threadRevision: 2,
								}),
								draft: null,
								savedBody: 'Reply one',
								savedRevision: 1,
							},
						},
						requestId: 'product-reply-one',
						sessionId: annotationSessionId,
						status: { kind: 'committed' },
						surface: 'file',
					},
				],
				expectedThreadCount: 1,
				revision: 4,
				sessions: [annotationSessionSummary({ revision: 4, sessionId: annotationSessionId })],
			});
			await Promise.resolve();
			await rendered.getByRole('button', { name: 'Reply to annotation thread' }).click();
			await rendered.getByRole('textbox', { name: 'Reply with Markdown' }).fill('Reply two');
		});
		await settleBrowserCondition(
			(): boolean => surface.sentOperations.some((operation) => operation.kind === 'reply.create'),
			'Expected Reply two to create its durable draft.',
		);
		const secondReplyCreate = surface.sentOperations.find(
			(operation) => operation.kind === 'reply.create',
		);
		expect(secondReplyCreate).toMatchObject({ expectedThreadRevision: 2 });
	});

	test('keeps an edit token active until every overlapping composer unregisters', async () => {
		const surface = new RecordingAnnotationBrowserSurface('fileView');
		const editToken = 'annotation-edit-overlapping-portals';
		const rendered = await render(
			<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
				<ComposerRegistrationFixture editToken={editToken} registrationCount={2} />
			</WorktreeAnnotationSurfaceProvider>,
		);
		await expect
			.element(rendered.getByTestId('active-composer-edit-token'))
			.toHaveTextContent(editToken);

		await rendered.rerender(
			<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
				<ComposerRegistrationFixture editToken={editToken} registrationCount={1} />
			</WorktreeAnnotationSurfaceProvider>,
		);
		await expect
			.element(rendered.getByTestId('active-composer-edit-token'))
			.toHaveTextContent(editToken);
	});
});

function ProjectionRemountingReplyComposer(props: { readonly editToken: string }): ReactElement {
	const projection = useWorktreeAnnotationProjection();
	return (
		<WorktreeAnnotationNewMessageComposer
			createOperation={(body, editToken) => ({
				body,
				editToken,
				expectedThreadRevision: 3,
				kind: 'reply.create',
				sessionId: annotationSessionId,
				threadId: annotationHeadThreadId,
			})}
			editToken={props.editToken}
			key={projection.revision}
			onCancel={() => {}}
			onSaved={() => {}}
			placement="embedded"
			placeholder="Reply with Markdown"
		/>
	);
}

function ComposerRegistrationFixture(props: {
	readonly editToken: string;
	readonly registrationCount: 1 | 2;
}): ReactElement {
	const activeEditTokens = useWorktreeAnnotationActiveEditTokens();
	return (
		<>
			<ComposerRegistration editToken={props.editToken} />
			{props.registrationCount === 2 ? <ComposerRegistration editToken={props.editToken} /> : null}
			<span data-testid="active-composer-edit-token">
				{activeEditTokens.has(props.editToken) ? props.editToken : 'inactive'}
			</span>
		</>
	);
}

function ComposerRegistration(props: { readonly editToken: string }): null {
	useWorktreeAnnotationEditSurfaceToken(props.editToken);
	return null;
}
