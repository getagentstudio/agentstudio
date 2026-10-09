import { readdir, readFile } from 'node:fs/promises';
import { basename, join } from 'node:path';

import type { Locator, Page, Response } from 'playwright';
import { expect } from 'vitest';

import { bridgeProductWorktreeAnnotationCommandOutcomeSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import {
	captureSharePreview,
	normalizedAnnotationEntries,
	type AnnotationPreviewEntryCapture,
} from './bridge-viewer-vite-annotation-preview-capture.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';

export interface AnnotationOutputCopyHooks {
	readonly beforeCopy?: () => Promise<void>;
}

interface AnnotationOutputCaptureJourneyProps extends AnnotationOutputCopyHooks {
	readonly dataRootPath: string;
	readonly page: Page;
	readonly savedBody: string;
	readonly timeoutMilliseconds: number;
	readonly worktreeRoot: string;
}

interface AnnotationOutputEntryCapture {
	readonly authorKind: 'agent' | 'human';
	readonly body: string;
	readonly endLine: number;
	readonly messageId: string;
	readonly path: string;
	readonly startLine: number;
}

export interface AnnotationOutputIdentityCapture {
	readonly messageId: string;
	readonly placement: unknown;
	readonly sessionId: string;
	readonly sessionLifecycle: unknown;
	readonly sourceRelationship: unknown;
	readonly threadId: string;
}

export async function verifyAnnotationOutputCaptures(
	props: AnnotationOutputCaptureJourneyProps,
): Promise<AnnotationOutputIdentityCapture> {
	const outputDirectory = join(props.dataRootPath, 'annotation-output-captures');
	const markdownNamesBefore = await outputCaptureNames(outputDirectory, '.md');

	await props.page.getByRole('button', { name: 'Annotations', exact: true }).click();
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);
	const copyButton = props.page.getByRole('button', { name: 'Copy Markdown' });
	await waitForEnabledOutputButton(copyButton, props.timeoutMilliseconds);
	const copiedPreview = await captureSharePreview(props.page);
	expect(copiedPreview.map((message) => message.body)).toContain(props.savedBody);
	await props.beforeCopy?.();
	const copyResponseObservation = waitForOutputCommandResponse(
		props.page,
		'clipboardMarkdown',
	).then(
		(response) => ({ kind: 'response' as const, response }),
		(error: unknown) => ({ error, kind: 'failed' as const }),
	);
	try {
		await copyButton.click();
	} catch (error: unknown) {
		void copyResponseObservation;
		throw error;
	}
	const copyResponseResult = await copyResponseObservation;
	if (copyResponseResult.kind === 'failed') throw copyResponseResult.error;
	try {
		await props.page
			.getByRole('region', { name: 'Annotations' })
			.waitFor({ state: 'hidden', timeout: props.timeoutMilliseconds });
	} catch (error: unknown) {
		const diagnostic = await copyDismissalDiagnostic({
			copyButton,
			copyResponse: copyResponseResult.response,
			markdownNamesBefore,
			outputDirectory,
			page: props.page,
		}).catch((): null => null);
		if (diagnostic === null) throw error;
		throw new Error(`Copy did not dismiss Annotations: ${diagnostic}.`, { cause: error });
	}

	const markdownPath = await requireNewOutputCapture({
		extension: '.md',
		namesBefore: markdownNamesBefore,
		outputDirectory,
	});
	const markdown = await readFile(markdownPath, 'utf8');
	expect(markdown).toContain(props.savedBody);
	for (const message of copiedPreview) expect(markdown).toContain(message.body);
	expect(markdown).not.toContain(props.worktreeRoot);
	expect(markdown.match(/^# /gmu)).toHaveLength(1);

	await props.page.getByRole('button', { name: 'Annotations', exact: true }).click();
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count === 0);
	const history = props.page.getByRole('button', { name: /^History \([1-9][0-9]*\)$/u });
	await history.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	await history.click();
	await markOutputNotHandled(props.page, 'clipboardMarkdown');
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);

	const jsonNamesBefore = await outputCaptureNames(outputDirectory, '.json');
	const exportButton = props.page.getByRole('button', { name: 'Export JSON' });
	await waitForEnabledOutputButton(exportButton, props.timeoutMilliseconds);
	const exportedPreview = await captureSharePreview(props.page);
	expect(exportedPreview.length).toBeGreaterThan(0);
	expect(normalizedAnnotationEntries(exportedPreview)).toEqual(
		normalizedAnnotationEntries(copiedPreview),
	);
	const exportResponsePromise = waitForOutputCommandResponse(props.page, 'jsonFile');
	await exportButton.click();
	const exportResponse = await exportResponsePromise;
	expect(exportResponse.status()).toBe(200);
	const jsonPath = await requireNewOutputCapture({
		extension: '.json',
		namesBefore: jsonNamesBefore,
		outputDirectory,
	});
	const annotations = props.page.getByRole('region', { name: 'Annotations' });
	await annotations.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	await annotations
		.getByRole('status')
		.getByText(`Saved to ${basename(jsonPath)}`, { exact: true })
		.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	await annotations
		.getByRole('button', { name: 'Reveal in Finder', exact: true })
		.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	await annotations
		.getByRole('button', { name: 'Change folder…', exact: true })
		.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	const document: unknown = JSON.parse(await readFile(jsonPath, 'utf8'));
	const pendingOutput = decodeAnnotationOutputDocument(document, props.savedBody);
	expectOutputEntriesMatchPreview(pendingOutput.entries, exportedPreview);
	expectMarkdownMatchesOutputEntries(markdown, pendingOutput.entries, props.worktreeRoot);
	const matchingIdentity = pendingOutput.matchingIdentity;
	if (matchingIdentity === null) {
		throw new Error('Annotation JSON capture omitted the saved message identity.');
	}

	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count === 0);
	const completedHistory = props.page.getByRole('button', {
		name: /^History \((?:[2-9]|[1-9][0-9]+)\)$/u,
	});
	await completedHistory.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	// JSON export retains the drawer and the History disclosure opened for the clipboard clear.
	expect(await completedHistory.getAttribute('aria-expanded')).toBe('true');
	await markOutputNotHandled(props.page, 'jsonFile');
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);
	expect(
		normalizedAnnotationEntries(await captureSharePreview(props.page)).get(
			matchingIdentity.messageId.toLowerCase(),
		)?.body,
	).toBe(props.savedBody);
	await props.page.getByRole('button', { name: 'Close Annotations' }).click();
	await props.page
		.getByRole('region', { name: 'Annotations' })
		.waitFor({ state: 'hidden', timeout: props.timeoutMilliseconds });

	const savedThread = props.page
		.locator('[data-testid="worktree-annotation-thread"]')
		.filter({ hasText: props.savedBody });
	const savedThreadId = await savedThread.getAttribute('data-annotation-thread-id');
	if (savedThreadId === null) throw new Error('Saved annotation thread identity was unavailable.');
	await setThreadResolution({
		page: props.page,
		resolution: 'resolved',
		threadId: savedThreadId,
		timeoutMilliseconds: props.timeoutMilliseconds,
	});

	await props.page.getByRole('button', { name: 'Annotations', exact: true }).click();
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, () => true);
	const resolvedPendingPreview = await captureSharePreview(props.page);
	expect(resolvedPendingPreview.map((message) => message.body)).not.toContain(props.savedBody);
	expect(resolvedPendingPreview.map((message) => message.messageId.toLowerCase())).not.toContain(
		matchingIdentity.messageId.toLowerCase(),
	);
	await props.page.locator('[aria-label^="All comments, "]').click();
	await waitForAllCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);
	const allCopiedPreview = await captureSharePreview(props.page);
	expect(allCopiedPreview.map((message) => message.body)).toContain(props.savedBody);
	const allMarkdown = await executeAndReadOutputCapture({
		extension: '.md',
		outputKind: 'clipboardMarkdown',
		outputDirectory,
		page: props.page,
		timeoutMilliseconds: props.timeoutMilliseconds,
	});

	await props.page.getByRole('button', { name: 'Annotations', exact: true }).click();
	await props.page.locator('[aria-label^="All comments, "]').click();
	await waitForAllCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);
	const allExportedPreview = await captureSharePreview(props.page);
	expect(normalizedAnnotationEntries(allExportedPreview)).toEqual(
		normalizedAnnotationEntries(allCopiedPreview),
	);
	const allJSON = await executeAndReadOutputCapture({
		extension: '.json',
		outputKind: 'jsonFile',
		outputDirectory,
		page: props.page,
		timeoutMilliseconds: props.timeoutMilliseconds,
	});
	const allOutput = decodeAnnotationOutputDocument(JSON.parse(allJSON), props.savedBody);
	expectOutputEntriesMatchPreview(allOutput.entries, allExportedPreview);
	expectMarkdownMatchesOutputEntries(allMarkdown, allOutput.entries, props.worktreeRoot);
	await props.page.getByRole('button', { name: 'Close Annotations' }).click();
	await props.page
		.getByRole('region', { name: 'Annotations' })
		.waitFor({ state: 'hidden', timeout: props.timeoutMilliseconds });

	await setThreadResolution({
		page: props.page,
		resolution: 'open',
		threadId: savedThreadId,
		timeoutMilliseconds: props.timeoutMilliseconds,
	});
	await props.page.getByRole('button', { name: 'Annotations', exact: true }).click();
	const finalHistory = props.page.getByRole('button', { name: /^History \([1-9][0-9]*\)$/u });
	await finalHistory.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	await finalHistory.click();
	await props.page
		.getByRole('region', { name: 'Output history' })
		.getByRole('button', { name: 'Mark as not handled' })
		.first()
		.click();
	await props.page.locator('[aria-label^="Pending comments, "]').click();
	await waitForPendingCommentCount(props.page, props.timeoutMilliseconds, (count) => count > 0);
	expect(
		normalizedAnnotationEntries(await captureSharePreview(props.page)).get(
			matchingIdentity.messageId.toLowerCase(),
		)?.body,
	).toBe(props.savedBody);
	return matchingIdentity;
}

async function executeAndReadOutputCapture(props: {
	readonly extension: '.json' | '.md';
	readonly outputKind: 'clipboardMarkdown' | 'jsonFile';
	readonly outputDirectory: string;
	readonly page: Page;
	readonly timeoutMilliseconds: number;
}): Promise<string> {
	const namesBefore = await outputCaptureNames(props.outputDirectory, props.extension);
	const actionButton = props.page.getByRole('button', {
		name: props.outputKind === 'clipboardMarkdown' ? 'Copy Markdown' : 'Export JSON',
	});
	await waitForEnabledOutputButton(actionButton, props.timeoutMilliseconds);
	const responsePromise = waitForOutputCommandResponse(props.page, props.outputKind);
	await actionButton.click();
	const response = await responsePromise;
	const responseBody = await response.text();
	if (props.outputKind === 'clipboardMarkdown') {
		await props.page
			.getByRole('region', { name: 'Annotations' })
			.waitFor({ state: 'hidden', timeout: props.timeoutMilliseconds })
			.catch(async (error: unknown): Promise<never> => {
				const alerts = await props.page.getByRole('alert').allTextContents();
				throw new Error(
					`All ${props.outputKind} did not dismiss Annotations: status=${response.status()} body=${responseBody} alerts=${JSON.stringify(alerts)}.`,
					{ cause: error },
				);
			});
	}
	const capturePath = await requireNewOutputCapture({
		extension: props.extension,
		namesBefore,
		outputDirectory: props.outputDirectory,
	});
	if (props.outputKind === 'jsonFile') {
		expect(response.status()).toBe(200);
		const annotations = props.page.getByRole('region', { name: 'Annotations' });
		await annotations.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
		await annotations
			.getByRole('status')
			.getByText(`Saved to ${basename(capturePath)}`, { exact: true })
			.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
		await annotations
			.getByRole('button', { name: 'Reveal in Finder', exact: true })
			.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
		await annotations
			.getByRole('button', { name: 'Change folder…', exact: true })
			.waitFor({ state: 'visible', timeout: props.timeoutMilliseconds });
	}
	return await readFile(capturePath, 'utf8');
}

function decodeAnnotationOutputDocument(
	document: unknown,
	savedBody: string,
): {
	readonly entries: readonly AnnotationOutputEntryCapture[];
	readonly matchingIdentity: AnnotationOutputIdentityCapture | null;
} {
	expect(document).toMatchObject({
		formatVersion: 2,
		schema: 'agentstudio.worktree-annotations.batch',
	});
	if (!isRecord(document) || !Array.isArray(document['entries'])) {
		throw new Error('Annotation JSON capture did not contain an entries array.');
	}
	const entries: AnnotationOutputEntryCapture[] = [];
	let matchingIdentity: AnnotationOutputIdentityCapture | null = null;
	for (const [entryIndex, entry] of document['entries'].entries()) {
		if (
			!isRecord(entry) ||
			!isRecord(entry['message']) ||
			!isRecord(entry['message']['author']) ||
			!isRecord(entry['thread'])
		) {
			throw new Error(`Annotation JSON entry ${entryIndex} was malformed.`);
		}
		expect(entry['batchOrdinal']).toBe(entryIndex);
		const messageId = entry['message']['messageId'];
		const body = entry['message']['bodyMarkdown'];
		const authorKind = entry['message']['author']['kind'];
		const coordinate = outputEntryCoordinate(entry['thread']);
		if (
			typeof messageId !== 'string' ||
			typeof body !== 'string' ||
			(authorKind !== 'agent' && authorKind !== 'human')
		) {
			throw new Error(`Annotation JSON entry ${entryIndex} omitted message identity or body.`);
		}
		entries.push({ authorKind, body, messageId, ...coordinate });
		if (body === savedBody) matchingIdentity = outputIdentityCapture(document, entry);
	}
	expect(entries.length).toBeGreaterThan(0);
	expect(new Set(entries.map(({ messageId }) => messageId.toLowerCase())).size).toBe(
		entries.length,
	);
	return { entries, matchingIdentity };
}

function outputEntryCoordinate(thread: Readonly<Record<string, unknown>>): {
	readonly endLine: number;
	readonly path: string;
	readonly startLine: number;
} {
	const origin = thread['origin'];
	const placement = thread['placement'];
	if (!isRecord(origin) || !isRecord(placement)) {
		throw new Error('Annotation JSON entry omitted thread origin or placement.');
	}
	const status = placement['status'];
	const current = placement['current'];
	const coordinate =
		(status === 'exact' || status === 'relocated') && isRecord(current) ? current : origin;
	const path = coordinate['path'];
	const startLine = coordinate['startLine'];
	const endLine = coordinate['endLine'];
	if (typeof path !== 'string' || typeof startLine !== 'number' || typeof endLine !== 'number') {
		throw new Error('Annotation JSON entry contained malformed path or range context.');
	}
	return { endLine, path, startLine };
}

function expectOutputEntriesMatchPreview(
	entries: readonly AnnotationOutputEntryCapture[],
	preview: readonly AnnotationPreviewEntryCapture[],
): void {
	expect(new Set(preview.map(({ messageId }) => messageId.toLowerCase())).size).toBe(
		preview.length,
	);
	expect(normalizedAnnotationEntries(entries)).toEqual(normalizedAnnotationEntries(preview));
}

function expectMarkdownMatchesOutputEntries(
	markdown: string,
	entries: readonly AnnotationOutputEntryCapture[],
	worktreeRoot: string,
): void {
	expect(markdown).not.toContain(worktreeRoot);
	expect(markdown.match(/^# /gmu)).toHaveLength(1);
	const bodies = markdown
		.split('\nMessage:\n\n')
		.slice(1)
		.map((segment) => (segment.split('\n\n---\n\n')[0] ?? '').replace(/\n$/u, ''));
	expect(bodies).toEqual(entries.map(({ body }) => body));
	for (const entry of entries) {
		expect(markdown).toContain(`File: \`${entry.path}\``);
		const range =
			entry.startLine === entry.endLine
				? `line ${entry.startLine}`
				: `lines ${entry.startLine}–${entry.endLine}`;
		expect(markdown).toMatch(new RegExp(`(?:Location|Original location): ${range}`, 'u'));
		expect(markdown).toContain(`Author: ${entry.authorKind === 'agent' ? 'Agent' : 'Human'}`);
	}
}

async function setThreadResolution(props: {
	readonly page: Page;
	readonly resolution: 'open' | 'resolved';
	readonly threadId: string;
	readonly timeoutMilliseconds: number;
}): Promise<void> {
	const thread = props.page.locator(`[data-annotation-thread-id="${props.threadId}"]`);
	const responsePromise = waitForThreadResolutionResponse(props.page, props.resolution);
	await thread
		.getByRole('button', {
			name:
				props.resolution === 'resolved' ? 'Resolve annotation thread' : 'Reopen annotation thread',
		})
		.click();
	await responsePromise;
	await expect
		.poll(async (): Promise<string | null> => thread.getAttribute('data-annotation-resolution'), {
			timeout: props.timeoutMilliseconds,
		})
		.toBe(props.resolution);
}

async function copyDismissalDiagnostic(props: {
	readonly copyButton: Locator;
	readonly copyResponse: Response;
	readonly markdownNamesBefore: ReadonlySet<string>;
	readonly outputDirectory: string;
	readonly page: Page;
}): Promise<string> {
	const closeButton = props.page.getByRole('button', { name: 'Close Annotations' });
	const [responseBody, alerts, markdownNamesAfter, copyDisabled, closeDisabled] = await Promise.all(
		[
			props.copyResponse.text(),
			props.page.getByRole('alert').allTextContents(),
			outputCaptureNames(props.outputDirectory, '.md'),
			props.copyButton.isDisabled(),
			closeButton.isDisabled(),
		],
	);
	const createdNames = [...markdownNamesAfter].filter(
		(name): boolean => !props.markdownNamesBefore.has(name),
	);
	return [
		`status=${props.copyResponse.status()}`,
		`body=${responseBody}`,
		`alerts=${JSON.stringify(alerts)}`,
		`captures=${JSON.stringify(createdNames)}`,
		`copyDisabled=${copyDisabled}`,
		`closeDisabled=${closeDisabled}`,
	].join(' ');
}

function outputIdentityCapture(
	document: Readonly<Record<string, unknown>>,
	entry: Readonly<Record<string, unknown>>,
): AnnotationOutputIdentityCapture {
	const session = document['session'];
	const thread = entry['thread'];
	const message = entry['message'];
	if (!isRecord(session) || !isRecord(thread) || !isRecord(message)) {
		throw new Error('Annotation JSON capture omitted durable identity context.');
	}
	const sessionId = session['sessionId'];
	const sessionLifecycle = session['lifecycle'];
	const sourceRelationship = session['sourceRelationship'];
	const threadId = thread['threadId'];
	const placement = thread['placement'];
	const messageId = message['messageId'];
	if (
		typeof sessionId !== 'string' ||
		sessionLifecycle === undefined ||
		sourceRelationship === undefined ||
		typeof threadId !== 'string' ||
		placement === undefined ||
		typeof messageId !== 'string'
	) {
		throw new Error('Annotation JSON capture contained malformed durable identity context.');
	}
	return {
		messageId,
		placement,
		sessionId,
		sessionLifecycle,
		sourceRelationship,
		threadId,
	};
}

async function outputCaptureNames(
	outputDirectory: string,
	extension: string,
): Promise<Set<string>> {
	try {
		return new Set(
			(await readdir(outputDirectory)).filter((name): boolean => name.endsWith(extension)),
		);
	} catch (error: unknown) {
		if (isRecord(error) && error['code'] === 'ENOENT') return new Set();
		throw error;
	}
}

async function requireNewOutputCapture(props: {
	readonly extension: string;
	readonly namesBefore: ReadonlySet<string>;
	readonly outputDirectory: string;
}): Promise<string> {
	const namesAfter = await outputCaptureNames(props.outputDirectory, props.extension);
	const createdNames = [...namesAfter].filter((name): boolean => !props.namesBefore.has(name));
	if (createdNames.length !== 1) {
		throw new Error(
			`Expected one new ${props.extension} annotation capture, received ${JSON.stringify(createdNames)}.`,
		);
	}
	return join(props.outputDirectory, createdNames[0] ?? '');
}

async function waitForPendingCommentCount(
	page: Page,
	timeoutMilliseconds: number,
	accept: (count: number) => boolean,
): Promise<void> {
	await waitForShareScopeCommentCount(page, 'Pending', timeoutMilliseconds, accept);
}

async function waitForAllCommentCount(
	page: Page,
	timeoutMilliseconds: number,
	accept: (count: number) => boolean,
): Promise<void> {
	await waitForShareScopeCommentCount(page, 'All', timeoutMilliseconds, accept);
}

async function waitForShareScopeCommentCount(
	page: Page,
	scopeLabel: 'All' | 'Pending',
	timeoutMilliseconds: number,
	accept: (count: number) => boolean,
): Promise<void> {
	const labelPrefix = `${scopeLabel} comments, `;
	await expect
		.poll(
			async (): Promise<number | null> => {
				const label = await page
					.locator(`[aria-label^="${labelPrefix}"]`)
					.getAttribute('aria-label');
				if (label === null) return null;
				const count = Number(label.slice(labelPrefix.length));
				return Number.isInteger(count) && accept(count) ? count : null;
			},
			{ timeout: timeoutMilliseconds },
		)
		.not.toBeNull();
}

async function waitForEnabledOutputButton(
	button: Locator,
	timeoutMilliseconds: number,
): Promise<void> {
	await expect
		.poll(async (): Promise<boolean> => button.isEnabled(), { timeout: timeoutMilliseconds })
		.toBe(true);
}

async function waitForOutputCommandResponse(
	page: Page,
	outputKind: 'clipboardMarkdown' | 'jsonFile',
): Promise<Response> {
	const settled = await waitForProductCallSettlement(page, (response): boolean => {
		const request = response.request();
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/command'
		) {
			return false;
		}
		const body: unknown = request.postDataJSON();
		if (!isRecord(body) || !isRecord(body['call'])) return false;
		const call = body['call'];
		if (!isRecord(call['request']) || !isRecord(call['request']['operation'])) return false;
		const operation = call['request']['operation'];
		return operation['kind'] === 'output.scope.commit' && operation['outputKind'] === outputKind;
	});
	return settled.response;
}

async function markOutputNotHandled(
	page: Page,
	outputKind: 'clipboardMarkdown' | 'jsonFile',
): Promise<void> {
	const settlement = waitForProductCallSettlement(page, (response): boolean => {
		const request = response.request();
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/command'
		)
			return false;
		const body: unknown = request.postDataJSON();
		return (
			isRecord(body) &&
			isRecord(body['call']) &&
			isRecord(body['call']['request']) &&
			isRecord(body['call']['request']['operation']) &&
			body['call']['request']['operation']['kind'] === 'output.handled.clear'
		);
	});
	await page
		.getByRole('region', { name: 'Output history' })
		.getByTestId('annotation-output-history-entry')
		.filter({
			has: page.getByText(outputKind === 'jsonFile' ? 'JSON file' : 'Clipboard Markdown', {
				exact: true,
			}),
		})
		.first()
		.getByRole('button', { name: 'Mark as not handled' })
		.click();
	const result: unknown = (await settlement).result;
	const outcome =
		isRecord(result) && isRecord(result['call']) && isRecord(result['call']['result'])
			? bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(
					result['call']['result']['outcome'],
				)
			: null;
	if (outcome === null || !outcome.success || outcome.data.status.kind !== 'committed') {
		throw new Error(
			`Mark as not handled did not commit: ${outcome?.success ? outcome.data.status.kind : 'unparseable'}.`,
		);
	}
}

async function waitForThreadResolutionResponse(
	page: Page,
	resolution: 'open' | 'resolved',
): Promise<Response> {
	const settled = await waitForProductCallSettlement(page, (response): boolean => {
		const request = response.request();
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/command'
		) {
			return false;
		}
		const body: unknown = request.postDataJSON();
		if (!isRecord(body) || !isRecord(body['call'])) return false;
		const call = body['call'];
		if (!isRecord(call['request']) || !isRecord(call['request']['operation'])) return false;
		const operation = call['request']['operation'];
		return operation['kind'] === 'thread.resolution.set' && operation['resolution'] === resolution;
	});
	return settled.response;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
