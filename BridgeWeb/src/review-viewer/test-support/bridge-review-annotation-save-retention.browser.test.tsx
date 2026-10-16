import { CodeView, type CodeViewOptions } from '@pierre/diffs';
import { act } from 'react';
import { afterEach, describe, expect, test, vi } from 'vitest';
import { cleanup } from 'vitest-browser-react';
import { page, userEvent } from 'vitest/browser';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import '../../app/bridge-app.css';
import { createBridgeReviewAnnotationRetentionWitness } from './bridge-review-annotation-retention-witness.test-support.js';
import {
	advanceBridgeReviewRecoveryWitnessFrames,
	disposeBridgeReviewRecoveryWitnessHarnesses,
	makeBridgeReviewRecoveryWitnessFiles,
	renderBridgeReviewRecoveryWitness,
} from './bridge-viewer-browser.recovery-witness.test-support.js';

// oxlint-disable-next-line unbound-method -- Restored after every Browser witness.
const originalCodeViewSetup = CodeView.prototype.setup;
// oxlint-disable-next-line unbound-method -- Restored after every Browser witness.
const originalCodeViewSetOptions = CodeView.prototype.setOptions;

describe('Bridge Review annotation Save presentation retention', () => {
	afterEach(async (): Promise<void> => {
		CodeView.prototype.setup = originalCodeViewSetup;
		CodeView.prototype.setOptions = originalCodeViewSetOptions;
		await act(async (): Promise<void> => {
			await cleanup();
		});
		disposeBridgeReviewRecoveryWitnessHarnesses();
		await advanceBridgeReviewRecoveryWitnessFrames(2);
		document.body.replaceChildren();
	});

	test('keeps the selected Reply visible across a one-item exact-active worker replay', async () => {
		await runBridgeReviewAnnotationSaveRetentionWitness({
			fileCount: 1,
			screenshotSuffix: 'one-item',
		});
	});

	test(
		'keeps the selected Reply visible across a 1,699-item exact-active worker replay',
		{ tags: ['stress'] },
		async () => {
			await runBridgeReviewAnnotationSaveRetentionWitness({
				fileCount: 1_699,
				screenshotSuffix: '1699-items',
			});
		},
	);
});

async function runBridgeReviewAnnotationSaveRetentionWitness(props: {
	readonly fileCount: number;
	readonly screenshotSuffix: string;
}): Promise<void> {
	// Arrange
	let mountedCodeView: CodeView | null = null;
	let latestCodeViewOptions: CodeViewOptions<undefined> | undefined;
	CodeView.prototype.setup = function captureCodeView(root: HTMLElement): void {
		// oxlint-disable-next-line typescript/no-this-alias -- Browser witness captures the live Pierre instance and restores the prototype after the test.
		mountedCodeView = this;
		originalCodeViewSetup.call(this, root);
	};
	CodeView.prototype.setOptions = function captureCodeViewOptions(
		options: CodeViewOptions<undefined> | undefined,
	): void {
		latestCodeViewOptions = options;
		originalCodeViewSetOptions.call(this, options);
	};
	const generatedFiles = makeBridgeReviewRecoveryWitnessFiles({
		count: props.fileCount,
		lineCount: 8,
		markerPrefix: `ANNOTATION_SAVE_RETENTION_${props.fileCount}`,
	});
	const generatedSelectedFile = generatedFiles[0];
	if (generatedSelectedFile === undefined) {
		throw new Error('Annotation Save retention requires a selected Review file.');
	}
	const selectedFile = {
		...generatedSelectedFile,
		sourceDescriptorIdsByRole: {
			base: 'annotation-save-retention-base-descriptor',
			head: 'annotation-save-retention-head-descriptor',
		},
	};
	const files = [selectedFile, ...generatedFiles.slice(1)];
	const harness = await renderBridgeReviewRecoveryWitness(files);
	const annotationWitness = createBridgeReviewAnnotationRetentionWitness(harness);
	await harness.publishDisplay();
	await expect.poll(() => harness.selectedItemCommandCount()).toBe(1);
	await expect.poll(() => annotationWitness.pendingCommandCount('session.discover')).toBe(1);
	await act(async (): Promise<void> => {
		annotationWitness.settleNextControlCommitted('session.discover');
		await nextAnimationFrame();
	});
	await harness.publishContentForItemIds([selectedFile.itemId]);
	const shell = harness.renderResult.getByTestId('review-viewer-shell');
	await expect.element(shell).toHaveAttribute('data-selected-content-state', 'ready');
	await expect
		.poll(() => harness.renderedCodeViewItemIds().includes(selectedFile.itemId))
		.toBe(true);
	const scrollOwner = harness.codeScrollOwner();
	if (scrollOwner === null) {
		throw new Error('Annotation Save retention requires a Review CodeView scroll owner.');
	}

	// Act: drive the same command-confirmed root create, flush, Save, exact projection,
	// large catalog commit, and cleanup commit used by the real stress journey.
	await openRootComposerThroughProductionAdmission({
		codeView: mountedCodeView,
		options: latestCodeViewOptions,
		selectedItemId: selectedFile.itemId,
	});
	await expect
		.poll(
			(): number => queryPierreElements('[aria-label="Write an annotation in Markdown"]').length,
		)
		.toBe(1);
	const composer = harness.renderResult.getByRole('textbox', {
		name: 'Write an annotation in Markdown',
	});
	const savedBody = 'Selected Review Reply survives annotation catalog cleanup.';
	await act(async (): Promise<void> => {
		await composer.fill(`${savedBody} initial`);
		await nextAnimationFrame();
	});
	await expect.poll(() => annotationWitness.pendingCommandCount('root.create')).toBe(1);
	await act(async (): Promise<void> => {
		annotationWitness.settleNextCommitted('root.create');
		await nextAnimationFrame();
	});
	await act(async (): Promise<void> => {
		await composer.fill(savedBody);
		await nextAnimationFrame();
	});
	await act(async (): Promise<void> => {
		await harness.renderResult.getByRole('button', { name: 'Save annotation' }).click();
		await nextAnimationFrame();
	});
	await annotationWitness.waitForPendingCommand('draft.flush');
	expect(annotationWitness.pendingCommandCount('draft.flush')).toBe(1);
	await act(async (): Promise<void> => {
		annotationWitness.settleNextCommitted('draft.flush');
		await nextAnimationFrame();
	});
	await expect.poll(() => annotationWitness.pendingCommandCount('draft.save')).toBe(1);
	const saveReceipt = await act(async () => {
		const receipt = annotationWitness.settleNextCommitted('draft.save');
		await nextAnimationFrame();
		return receipt;
	});
	await waitForRecoveryWitnessCondition(
		(): boolean => savedThreadWithReplyIsVisible(savedBody),
		'Expected the visible saved body and Reply slot after draft.save.',
	);
	expect(saveReceipt.message).toMatchObject({ draft: null, savedBody });
	await expect.element(harness.renderResult.getByText(savedBody, { exact: true })).toBeVisible();
	await act(async (): Promise<void> => {
		annotationWitness.publishExactProjectionWithLargeCatalog(2_000);
		await advanceBridgeReviewRecoveryWitnessFrames(4);
	});
	if (props.fileCount > 1) {
		const backgroundItemIds = files.slice(1).map((file): string => file.itemId);
		const publishedBackgroundItemIds = await harness.publishContentForItemIds(backgroundItemIds);
		expect(publishedBackgroundItemIds).toHaveLength(backgroundItemIds.length);
		expect(publishedBackgroundItemIds).not.toContain(selectedFile.itemId);
	}
	await act(async (): Promise<void> => {
		annotationWitness.publishCleanupCatalog();
		await advanceBridgeReviewRecoveryWitnessFrames(4);
	});
	await harness.publishExactActiveDisplayAtWorkerEpoch(2);

	// Assert
	const thread = requireHTMLElement(
		queryPierreElements('[data-testid="worktree-annotation-thread"]')[0] ?? null,
		'Expected the exact Review annotation thread after catalog cleanup.',
	);
	const threadBounds = thread.getBoundingClientRect();
	const selectedPaint = harness
		.paintedCodeViewItems()
		.find((paintedItem) => paintedItem.itemId === selectedFile.itemId);
	const trace = {
		renderedItemIds: harness.renderedCodeViewItemIds(),
		selectedPaint,
		shellContentState: shell.element().getAttribute('data-selected-content-state'),
		scrollTop: scrollOwner.scrollTop,
		threadHeight: threadBounds.height,
		threadWidth: threadBounds.width,
	};
	expect(trace.shellContentState, JSON.stringify(trace)).toBe('ready');
	expect(trace.renderedItemIds, JSON.stringify(trace)).toContain(selectedFile.itemId);
	expect(selectedPaint?.paintedLineCount, JSON.stringify(trace)).toBeGreaterThan(0);
	expect(scrollOwner.scrollTop, JSON.stringify(trace)).toBeLessThanOrEqual(1);
	expect(threadBounds.width, JSON.stringify(trace)).toBeGreaterThan(0);
	expect(threadBounds.height, JSON.stringify(trace)).toBeGreaterThan(0);
	const replyButton = harness.renderResult.getByRole('button', {
		name: 'Reply to annotation thread',
	});
	await expect.element(replyButton).toBeVisible();
	const expandedBeforeReply = thread.getAttribute('data-annotation-expanded');
	await act(async (): Promise<void> => {
		await userEvent.click(replyButton.element());
	});
	await waitForRecoveryWitnessCondition(
		(): boolean =>
			queryPierreElements('[aria-label="Reply with Markdown"]').some((element): boolean =>
				elementHasVisibleGeometry(element),
			),
		(): string =>
			`Expected the visible Reply composer after clicking Reply: ${JSON.stringify({
				expandedAfterReply: thread.getAttribute('data-annotation-expanded'),
				expandedBeforeReply,
				threadConnected: thread.isConnected,
			})}`,
	);
	expect(thread.getAttribute('data-annotation-expanded')).toBe('true');
	await act(async (): Promise<void> => {
		await page.screenshot({
			element: harness.renderResult.getByTestId('bridge-review-recovery-witness-root').element(),
			path: `../../../../tmp/bridgeweb-review-annotation-save-retention-${props.screenshotSuffix}.png`,
		});
	});
	await act(async (): Promise<void> => {
		await harness.renderResult.unmount();
	});
}

async function openRootComposerThroughProductionAdmission(props: {
	readonly codeView: CodeView | null;
	readonly options: CodeViewOptions<undefined> | undefined;
	readonly selectedItemId: string;
}): Promise<void> {
	const selectedItem = props.codeView?.getItem(props.selectedItemId);
	if (selectedItem === undefined) {
		throw new Error('Expected the selected Review item in the live CodeView.');
	}
	const gutterAdmission = props.options?.onGutterUtilityClick;
	const selectionAdmission = props.options?.onLineSelectionEnd;
	if (gutterAdmission === undefined || selectionAdmission === undefined) {
		throw new Error('Expected production Review annotation range and gutter admission callbacks.');
	}
	const range = { end: 5, side: 'additions' as const, start: 2 };
	await act(async (): Promise<void> => {
		Reflect.apply(selectionAdmission, undefined, [range, { item: selectedItem }]);
		await nextAnimationFrame();
	});
	await act(async (): Promise<void> => {
		Reflect.apply(gutterAdmission, undefined, [range, { item: selectedItem }]);
		await nextAnimationFrame();
	});
	await waitForRecoveryWitnessCondition(
		(): boolean =>
			queryPierreElements('[aria-label="Write an annotation in Markdown"]').some(
				(element): boolean => elementHasVisibleGeometry(element),
			),
		'Expected the visible root composer slot after gutter admission.',
	);
}

function savedThreadWithReplyIsVisible(savedBody: string): boolean {
	return queryPierreElements('[data-testid="worktree-annotation-thread"]').some(
		(thread): boolean => {
			const reply = thread.querySelector('[aria-label="Reply to annotation thread"]');
			return (
				(thread.textContent?.includes(savedBody) ?? false) &&
				elementHasVisibleGeometry(thread) &&
				reply !== null &&
				elementHasVisibleGeometry(reply)
			);
		},
	);
}

function elementHasVisibleGeometry(element: Element): boolean {
	const bounds = element.getBoundingClientRect();
	return bounds.width > 0 && bounds.height > 0;
}

async function waitForRecoveryWitnessCondition(
	predicate: () => boolean,
	failureMessage: string | (() => string),
	remainingFrames = 60,
): Promise<void> {
	if (predicate()) return;
	if (remainingFrames <= 0) {
		throw new Error(typeof failureMessage === 'string' ? failureMessage : failureMessage());
	}
	await advanceBridgeReviewRecoveryWitnessFrames(1);
	await waitForRecoveryWitnessCondition(predicate, failureMessage, remainingFrames - 1);
}

function queryPierreElements(selector: string): Element[] {
	const elements: Element[] = [];
	const pendingRoots: ParentNode[] = [document];
	while (pendingRoots.length > 0) {
		const root = pendingRoots.shift();
		if (root === undefined) break;
		elements.push(...root.querySelectorAll(selector));
		for (const candidate of root.querySelectorAll('*')) {
			if (candidate.shadowRoot !== null) pendingRoots.push(candidate.shadowRoot);
		}
	}
	return elements;
}

function requireHTMLElement(value: Element | null, message: string): HTMLElement {
	if (!(value instanceof HTMLElement)) throw new Error(message);
	return value;
}

async function nextAnimationFrame(): Promise<void> {
	await new Promise<void>((resolve): void => {
		requestAnimationFrame((): void => resolve());
	});
}

test('rejects a withheld Review flush fact even when the pending count claims one command', async () => {
	const harness = await renderBridgeReviewRecoveryWitness(
		makeBridgeReviewRecoveryWitnessFiles({
			count: 1,
			lineCount: 8,
			markerPrefix: 'WITHHELD_FLUSH',
		}),
	);
	const witness = createBridgeReviewAnnotationRetentionWitness(harness);
	vi.spyOn(witness, 'pendingCommandCount').mockReturnValue(1);
	const waiting = witness.waitForPendingCommand('draft.flush');
	disposeBridgeReviewRecoveryWitnessHarnesses();
	await expect(waiting).rejects.toThrow(
		'Awaiting Review annotation pending draft.flush: Review recovery witness disposed',
	);
	await act(async (): Promise<void> => {
		await harness.renderResult.unmount();
	});
});
