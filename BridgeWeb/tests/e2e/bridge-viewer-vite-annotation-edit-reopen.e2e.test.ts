import type { Browser, Locator, Page, Response } from 'playwright';
import { expect, test } from 'vitest';

import { bridgeProductWorktreeAnnotationCommandOutcomeSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import {
	selectRangeForAnnotation,
	waitForSelectedFileReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { waitForCommittedAnnotationOutcome } from './bridge-viewer-vite-annotation-wire-response-observation.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';

const journeyTimeoutMilliseconds = 120_000;

test('keeps one File annotation stable through repeated edit, reply, resolve, and reopen', async () => {
	const fixture = await createBridgeViewerViteProductFixture();
	let browser: Browser | null = null;
	let page: Page | null = null;
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let phase = 'fixture-ready';
	let commandObservation: AnnotationCommandObservation | null = null;
	try {
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		browser = await launchBridgeViewerE2EChromium();
		page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		commandObservation = observeAnnotationCommandOutcomes(page, (): string => phase);

		phase = 'file-ready';
		await page.goto(bridgeViewerViteProductFileUrl(server.origin, fixture.oracle.largeFilePath), {
			timeout: journeyTimeoutMilliseconds,
			waitUntil: 'domcontentloaded',
		});
		await waitForSelectedFileReady({ oracle: fixture.oracle, page });
		expect(fixture.oracle.largeFileLineCount).toBe(128);

		phase = 'root-range-selected';
		await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: 'file' });
		const rootBody = 'Stable editable root annotation.';
		const root = await createAndSaveMessage({
			createKind: 'root.create',
			finalBody: rootBody,
			page,
			textboxName: 'Write an annotation in Markdown',
		});
		const thread = page.locator(`[data-annotation-thread-id="${root.context.threadId}"]`);
		await waitForCanonicalMessageBody({ body: rootBody, messageId: root.messageId, page });

		phase = 'first-edit';
		await editAndSaveMessage({
			body: 'Stable editable root annotation, first revision.',
			messageId: root.messageId,
			page,
		});

		phase = 'second-edit';
		const secondEditBody = 'Stable editable root annotation, second revision.';
		await editAndSaveMessage({ body: secondEditBody, messageId: root.messageId, page });
		expect(await page.getByText('edit_token_conflict', { exact: true }).count()).toBe(0);

		phase = 'first-reply';
		await createAndSaveReply({ body: 'Reply before resolution.', page, thread });

		phase = 'resolve';
		const resolved = waitForCommittedResolutionOutcome(page, 'resolved');
		await thread.getByRole('button', { name: 'Resolve annotation thread', exact: true }).click();
		await resolved;
		await waitForThreadResolution(page, root.context.threadId, 'resolved');
		expect(
			await thread.getByRole('button', { name: 'Reply to annotation thread', exact: true }).count(),
		).toBe(0);

		phase = 'reopen';
		const reopened = waitForCommittedResolutionOutcome(page, 'open');
		await thread.getByRole('button', { name: 'Reopen annotation thread', exact: true }).click();
		await reopened;
		await waitForThreadResolution(page, root.context.threadId, 'open');
		await thread
			.getByRole('button', { name: 'Reply to annotation thread', exact: true })
			.waitFor({ state: 'visible', timeout: journeyTimeoutMilliseconds });

		phase = 'post-reopen-reply';
		await createAndSaveReply({ body: 'Reply after canonical reopen.', page, thread });
		await waitForCanonicalMessageBody({ body: secondEditBody, messageId: root.messageId, page });
		expect(await page.getByText('edit_token_conflict', { exact: true }).count()).toBe(0);
	} catch (error: unknown) {
		await commandObservation?.drain();
		const visibleAlerts =
			page === null
				? []
				: await page
						.locator('[role="alert"]')
						.allTextContents()
						.catch(() => []);
		throw new Error(
			`Annotation edit/reopen journey failed during ${phase}; commands=${JSON.stringify(commandObservation?.records ?? [])}; alerts=${JSON.stringify(visibleAlerts)}; server=${server?.diagnostics() ?? 'not-started'}.`,
			{ cause: error },
		);
	} finally {
		try {
			await page?.close();
			await browser?.close();
		} finally {
			try {
				if (server !== null) {
					const cleanup = await server.stop();
					expect(cleanup.forcedTerminationRequired).toBe(false);
					expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
				}
			} finally {
				await fixture.dispose();
			}
		}
	}
});

interface AnnotationCommandObservation {
	readonly drain: () => Promise<void>;
	readonly records: readonly {
		readonly operationKind: string;
		readonly phase: string;
		readonly status: string;
	}[];
}

function observeAnnotationCommandOutcomes(
	page: Page,
	readPhase: () => string,
): AnnotationCommandObservation {
	const records: Array<{
		readonly operationKind: string;
		readonly phase: string;
		readonly status: string;
	}> = [];
	const pending = new Set<Promise<void>>();
	page.on('response', (response): void => {
		const operationKind = annotationOperationKind(response);
		if (operationKind === null) return;
		const responsePhase = readPhase();
		const recording = recordAnnotationCommandOutcome(response)
			.then((status): void => {
				records.push({ operationKind, phase: responsePhase, status });
				if (records.length > 64) records.splice(0, records.length - 64);
			})
			.finally((): void => {
				pending.delete(recording);
			});
		pending.add(recording);
	});
	return {
		drain: async (): Promise<void> => {
			await Promise.allSettled(pending);
		},
		records,
	};
}

function annotationOperationKind(response: Response): string | null {
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return null;
	const requestBody: unknown = request.postDataJSON();
	if (!isRecord(requestBody) || !isRecord(requestBody['call'])) return null;
	const callRequest = requestBody['call']['request'];
	if (!isRecord(callRequest) || !isRecord(callRequest['operation'])) return null;
	return typeof callRequest['operation']['kind'] === 'string'
		? callRequest['operation']['kind']
		: null;
}

async function recordAnnotationCommandOutcome(response: Response): Promise<string> {
	try {
		const responseBody: unknown = await response.json();
		if (!isRecord(responseBody) || !isRecord(responseBody['call'])) return 'malformed';
		const callResult = responseBody['call']['result'];
		if (!isRecord(callResult) || !isRecord(callResult['outcome'])) return 'malformed';
		const parsedOutcome = bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(
			callResult['outcome'],
		);
		if (!parsedOutcome.success) return 'malformed';
		return parsedOutcome.data.status.kind === 'failed'
			? `failed:${parsedOutcome.data.status.code}`
			: parsedOutcome.data.status.kind;
	} catch {
		return `http:${response.status()}`;
	}
}

async function createAndSaveMessage(props: {
	readonly createKind: 'reply.create' | 'root.create';
	readonly finalBody: string;
	readonly page: Page;
	readonly textboxName: 'Reply with Markdown' | 'Write an annotation in Markdown';
}): Promise<Awaited<ReturnType<typeof waitForCommittedAnnotationOutcome>>> {
	const composer = props.page.getByRole('textbox', { name: props.textboxName, exact: true });
	await composer.waitFor({ state: 'visible', timeout: journeyTimeoutMilliseconds });
	const createdPromise = waitForCommittedAnnotationOutcome(props.page, props.createKind, 'file');
	await composer.fill(`${props.finalBody} Initial`);
	const created = await createdPromise;
	const flushedPromise = waitForCommittedAnnotationOutcome(props.page, 'draft.flush', 'file');
	await composer.fill(props.finalBody);
	assertSameMessage(created, await flushedPromise);
	const savedPromise = waitForCommittedAnnotationOutcome(props.page, 'draft.save', 'file');
	await props.page.getByRole('button', { name: 'Save annotation', exact: true }).last().click();
	assertSameMessage(created, await savedPromise);
	await composer.waitFor({ state: 'hidden', timeout: journeyTimeoutMilliseconds });
	await waitForCanonicalMessageBody({
		body: props.finalBody,
		messageId: created.messageId,
		page: props.page,
	});
	return created;
}

async function editAndSaveMessage(props: {
	readonly body: string;
	readonly messageId: string;
	readonly page: Page;
}): Promise<void> {
	const message = props.page.locator(`[data-annotation-message-id="${props.messageId}"]`);
	await message.getByRole('button', { name: 'Edit annotation', exact: true }).click();
	const editor = message.getByRole('textbox', { name: 'Annotation Markdown', exact: true });
	await editor.waitFor({ state: 'visible', timeout: journeyTimeoutMilliseconds });
	const flushedPromise = waitForCommittedAnnotationOutcome(props.page, 'draft.flush', 'file');
	await editor.fill(props.body);
	const flushed = await flushedPromise;
	if (flushed.messageId !== props.messageId) {
		throw new Error(
			`draft.flush changed message identity from ${props.messageId} to ${flushed.messageId}.`,
		);
	}
	const savedPromise = waitForCommittedAnnotationOutcome(props.page, 'draft.save', 'file');
	await message.getByRole('button', { name: 'Save annotation', exact: true }).click();
	const saved = await savedPromise;
	if (saved.messageId !== props.messageId) {
		throw new Error(
			`draft.save changed message identity from ${props.messageId} to ${saved.messageId}.`,
		);
	}
	await editor.waitFor({ state: 'hidden', timeout: journeyTimeoutMilliseconds });
	await waitForCanonicalMessageBody(props);
}

async function createAndSaveReply(props: {
	readonly body: string;
	readonly page: Page;
	readonly thread: Locator;
}): Promise<void> {
	await props.thread
		.getByRole('button', { name: 'Reply to annotation thread', exact: true })
		.click();
	await createAndSaveMessage({
		createKind: 'reply.create',
		finalBody: props.body,
		page: props.page,
		textboxName: 'Reply with Markdown',
	});
}

async function waitForCommittedResolutionOutcome(
	page: Page,
	resolution: 'open' | 'resolved',
): Promise<void> {
	const settled = await waitForProductCallSettlement(page, (candidate): boolean =>
		resolutionCommandResponseMatches(candidate, resolution),
	);
	const responseBody: unknown = settled.result;
	if (
		!isRecord(responseBody) ||
		responseBody['kind'] !== 'call.completed' ||
		!isRecord(responseBody['call']) ||
		responseBody['call']['method'] !== 'file.annotations.command' ||
		!isRecord(responseBody['call']['result']) ||
		responseBody['call']['result']['kind'] !== 'completed'
	) {
		throw new Error(`Malformed thread.resolution.set ${resolution} response.`);
	}
	const callResult = responseBody['call']['result'];
	if (!isRecord(callResult) || !isRecord(callResult['outcome'])) {
		throw new Error(`Missing thread.resolution.set ${resolution} outcome.`);
	}
	const parsedOutcome = bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(
		callResult['outcome'],
	);
	if (!parsedOutcome.success || parsedOutcome.data.status.kind !== 'committed') {
		throw new Error(
			`Non-committed thread.resolution.set ${resolution} outcome: ${JSON.stringify(callResult['outcome'])}.`,
		);
	}
}

function resolutionCommandResponseMatches(
	response: Response,
	resolution: 'open' | 'resolved',
): boolean {
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	)
		return false;
	const requestBody: unknown = request.postDataJSON();
	if (!isRecord(requestBody) || !isRecord(requestBody['call'])) return false;
	const callRequest = requestBody['call']['request'];
	return (
		requestBody['call']['method'] === 'file.annotations.command' &&
		isRecord(callRequest) &&
		isRecord(callRequest['operation']) &&
		callRequest['operation']['kind'] === 'thread.resolution.set' &&
		callRequest['operation']['resolution'] === resolution
	);
}

async function waitForThreadResolution(
	page: Page,
	threadId: string,
	resolution: 'open' | 'resolved',
): Promise<void> {
	await page.waitForFunction(
		({ expectedResolution, expectedThreadId }): boolean =>
			document
				.querySelector(`[data-annotation-thread-id="${CSS.escape(expectedThreadId)}"]`)
				?.getAttribute('data-annotation-resolution') === expectedResolution,
		{ expectedResolution: resolution, expectedThreadId: threadId },
		{ timeout: journeyTimeoutMilliseconds },
	);
}

async function waitForCanonicalMessageBody(props: {
	readonly body: string;
	readonly messageId: string;
	readonly page: Page;
}): Promise<void> {
	await props.page
		.locator(`[data-annotation-message-id="${props.messageId}"]`)
		.getByText(props.body, { exact: true })
		.waitFor({ state: 'visible', timeout: journeyTimeoutMilliseconds });
}

function assertSameMessage(
	left: Awaited<ReturnType<typeof waitForCommittedAnnotationOutcome>>,
	right: Awaited<ReturnType<typeof waitForCommittedAnnotationOutcome>>,
): void {
	if (left.messageId !== right.messageId || left.sessionId !== right.sessionId) {
		throw new Error('Annotation identity changed across committed command outcomes.');
	}
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
