import { act, type ReactElement } from 'react';
import { render } from 'vitest-browser-react';

import type { BridgeMarkdownRenderWorkerClient } from '../app/markdown/worker/bridge-markdown-render-worker-client.js';
import {
	annotationHeadThreadId,
	annotationMessage,
	annotationSessionId,
	annotationSessionSummary,
	RecordingAnnotationBrowserSurface,
} from './worktree-annotation-browser-test-support.js';
import type {
	WorktreeAnnotationMessageEntry,
	WorktreeAnnotationThreadContext,
} from './worktree-annotation-surface-client.js';
import {
	useWorktreeAnnotationProjection,
	WorktreeAnnotationSurfaceProvider,
} from './worktree-annotation-surface-provider.js';
import { WorktreeAnnotationThread } from './worktree-annotation-thread.js';

function AnnotationProjection(): ReactElement | null {
	const projection = useWorktreeAnnotationProjection();
	return projection.threads.length === 0 ? null : (
		<>
			{projection.threads.map((thread) => (
				<WorktreeAnnotationThread key={thread.context.threadId} thread={thread} />
			))}
		</>
	);
}

function RemountingAnnotationProjection(): ReactElement | null {
	const projection = useWorktreeAnnotationProjection();
	return projection.threads.length === 0 ? null : (
		<>
			{projection.threads.map((thread) => (
				<WorktreeAnnotationThread
					key={`${thread.context.threadId}:${projection.revision}`}
					thread={thread}
				/>
			))}
		</>
	);
}

export async function renderAnnotationProjection(
	surface: RecordingAnnotationBrowserSurface,
	markdownWorkerClient?: BridgeMarkdownRenderWorkerClient,
): Promise<Awaited<ReturnType<typeof render>>> {
	return await render(
		<WorktreeAnnotationSurfaceProvider
			markdownWorkerClient={markdownWorkerClient}
			surfaceClient={surface.client}
		>
			<AnnotationProjection />
		</WorktreeAnnotationSurfaceProvider>,
	);
}

export async function renderRemountingAnnotationProjection(
	surface: RecordingAnnotationBrowserSurface,
): Promise<Awaited<ReturnType<typeof render>>> {
	return await render(
		<WorktreeAnnotationSurfaceProvider surfaceClient={surface.client}>
			<RemountingAnnotationProjection />
		</WorktreeAnnotationSurfaceProvider>,
	);
}

export async function publishThreadMessages(
	surface: RecordingAnnotationBrowserSurface,
	messages: readonly WorktreeAnnotationMessageEntry[],
	context: WorktreeAnnotationThreadContext = locatedContext,
): Promise<void> {
	await publishThreads(surface, [{ context, messages }]);
}

export async function publishThreads(
	surface: RecordingAnnotationBrowserSurface,
	threads: readonly {
		readonly context: WorktreeAnnotationThreadContext;
		readonly messages: readonly WorktreeAnnotationMessageEntry[];
	}[],
): Promise<void> {
	const eligibleMessageCount = threads.reduce(
		(count, thread): number =>
			count +
			thread.messages.filter(
				(message): boolean =>
					message.savedBody !== null && message.draft === null && message.status === 'editable',
			).length,
		0,
	);
	await act(async (): Promise<void> => {
		surface.publishProjectionState({
			expectedThreadCount: threads.length,
			revision: 3,
			sessions: [
				annotationSessionSummary({
					eligibleMessageCount,
					revision: 3,
					sessionId: annotationSessionId,
				}),
			],
		});
		for (const thread of threads) {
			surface.publishThreadMessages({ context: thread.context, messages: thread.messages });
		}
		await Promise.resolve();
	});
}

export function makeSavedMessage(props: {
	readonly body: string;
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
		createdAt: Date.now() / 1000 - 978_307_200 - (props.ordinal ?? 0) * 60,
		savedBody: props.body,
	};
}

export const locatedContext: WorktreeAnnotationThreadContext = {
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

export const rootMessageId = '00000000-0000-7000-8000-000000000091';
export const replyMessageId = '00000000-0000-7000-8000-000000000092';
export const secondRootMessageId = '00000000-0000-7000-8000-000000000093';
export const secondReplyMessageId = '00000000-0000-7000-8000-000000000094';
export const thirdReplyMessageId = '00000000-0000-7000-8000-000000000096';

export async function settleBrowserCondition(
	predicate: () => boolean,
	failureMessage: string,
	remainingFrames = 60,
): Promise<void> {
	await act(async (): Promise<void> => {
		await Promise.resolve();
		await new Promise<void>((resolve): void => {
			requestAnimationFrame((): void => resolve());
		});
		await Promise.resolve();
	});
	if (predicate()) return;
	if (remainingFrames <= 0) throw new Error(failureMessage);
	await settleBrowserCondition(predicate, failureMessage, remainingFrames - 1);
}

export async function settleThreadMotion(element: Element, failureMessage: string): Promise<void> {
	if (!(element instanceof HTMLElement)) throw new Error(failureMessage);
	const panel = element;
	const needsTransitionCommit =
		panel.isConnected &&
		(panel.hasAttribute('data-starting-style') ||
			(!panel.hasAttribute('data-open') &&
				!panel.hasAttribute('data-ending-style') &&
				!panel.hasAttribute('hidden')));
	if (needsTransitionCommit) {
		// Base UI defers starting -> idle and closing -> ending to its queued frame.
		// Let that exact transition commit when this act returns. Holding the same act
		// open until panel removal would prevent ending's passive effect from starting.
		await act(async (): Promise<void> => {
			await new Promise<void>((resolve): void => {
				requestAnimationFrame((): void => resolve());
			});
		});
		if (
			panel.isConnected &&
			(panel.hasAttribute('data-starting-style') ||
				(!panel.hasAttribute('data-open') &&
					!panel.hasAttribute('data-ending-style') &&
					!panel.hasAttribute('hidden')))
		) {
			throw new Error(`${failureMessage} Base UI's deferred transition did not commit.`);
		}
	}
	await act(async (): Promise<void> => {
		await Promise.all(
			panel.getAnimations({ subtree: true }).map(async (animation): Promise<void> => {
				try {
					await animation.finished;
				} catch {
					// Reversing an in-flight transition cancels its predecessor.
				}
			}),
		);
		// Base UI probes animations on a later frame, then clears its measured
		// dimensions in flushSync. Visual completion alone does not join that update.
		await new Promise<void>((resolve): void => {
			const observer = new MutationObserver(checkCompletion);
			function checkCompletion(): void {
				const opened =
					panel.hasAttribute('data-open') &&
					!panel.hasAttribute('data-starting-style') &&
					panel.style.getPropertyValue('--collapsible-panel-height') === 'auto';
				if (!panel.isConnected || panel.hasAttribute('hidden') || opened) {
					observer.disconnect();
					resolve();
				}
			}
			observer.observe(panel, { attributes: true });
			if (panel.parentNode !== null) observer.observe(panel.parentNode, { childList: true });
			checkCompletion();
		});
	});
}

export async function waitForWorktreeAnnotationBrowserDomState<TState>(props: {
	readonly readState: () => TState;
	readonly isExpected: (state: TState) => boolean;
}): Promise<TState> {
	let observedState = props.readState();
	await act(async (): Promise<void> => {
		if (props.isExpected(observedState)) return;
		observedState = await new Promise<TState>((resolve): void => {
			const observer = new MutationObserver(publishWhenExpected);
			function publishWhenExpected(): void {
				const state = props.readState();
				if (!props.isExpected(state)) return;
				observer.disconnect();
				document.removeEventListener('focusin', publishWhenExpected, true);
				document.removeEventListener('focusout', publishWhenExpected, true);
				document.removeEventListener('transitionend', publishWhenExpected, true);
				resolve(state);
			}
			observer.observe(document.documentElement, {
				attributes: true,
				characterData: true,
				childList: true,
				subtree: true,
			});
			document.addEventListener('focusin', publishWhenExpected, true);
			document.addEventListener('focusout', publishWhenExpected, true);
			document.addEventListener('transitionend', publishWhenExpected, true);
			publishWhenExpected();
		});
	});
	return observedState;
}

export function createDeferred<TValue>(): {
	readonly promise: Promise<TValue>;
	readonly reject: (error: Error) => void;
	readonly resolve: (value: TValue) => void;
} {
	let reject!: (error: Error) => void;
	let resolve!: (value: TValue) => void;
	const promise = new Promise<TValue>((promiseResolve, promiseReject): void => {
		resolve = promiseResolve;
		reject = promiseReject;
	});
	return { promise, reject, resolve };
}
