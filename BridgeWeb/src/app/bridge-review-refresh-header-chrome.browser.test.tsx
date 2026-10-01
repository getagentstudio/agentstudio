import type { ReactElement } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { render } from 'vitest-browser-react';

// oxlint-disable-next-line import/no-unassigned-import -- Browser Mode must load production app CSS.
import './bridge-app.css';
import type { BridgeMainReviewRefreshPresentation } from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import {
	BridgeReviewRefreshHeaderGroup,
	bridgeReviewRefreshHeaderPresentation,
} from './bridge-review-refresh-header-chrome.js';
import { BridgeViewerContentHeader } from './bridge-viewer-content-header.js';

const activeIdentity = {
	generation: 1,
	packageId: 'package-a',
	publicationId: '00000000-0000-7000-8000-000000000001',
	revision: 1,
	sourceIdentity: 'source-a',
} as const;
const candidateIdentity = {
	...activeIdentity,
	publicationId: '00000000-0000-7000-8000-000000000002',
	revision: 2,
} as const;

describe('Bridge Review refresh header chrome', () => {
	test('an ordinary installation failure leaves the toolbar silent for the pane summary', async () => {
		const rendered = await renderRefreshHeader(
			{
				activeIdentity: null,
				candidate: null,
				failure: {
					kind: 'installation',
					identity: candidateIdentity,
					presentationClass: { kind: 'ordinary' },
					retryable: true,
					affectedStableFileIdentities: [],
				},
			},
			[],
		);
		expect(rendered.getByRole('button', { name: 'Retry' }).query()).toBeNull();
		expect(rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
		expect(document.body.innerText).not.toContain('unavailable');
	});

	test('keeps ordinary, replacement, and unaffected promoted candidates silent', async () => {
		for (const refreshPresentation of [
			candidatePresentation({
				startDisposition: {
					affectedStableFileIdentities: ['item-1'],
					kind: 'sameSource',
					presentationClass: { kind: 'ordinary' },
				},
			}),
			candidatePresentation({ startDisposition: { kind: 'replacement' } }),
			candidatePresentation({
				startDisposition: {
					affectedStableFileIdentities: ['item-2'],
					kind: 'sameSource',
					presentationClass: { kind: 'promoted', reason: 'files' },
				},
			}),
		]) {
			// oxlint-disable-next-line no-await-in-loop -- Each case owns and unmounts one isolated browser document tree before the next case.
			const rendered = await renderRefreshHeader(refreshPresentation, ['item-1']);
			expect(rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
			expect(rendered.getByRole('button', { name: 'Apply now' }).query()).toBeNull();
			// oxlint-disable-next-line no-await-in-loop -- Sequential cleanup prevents duplicate global role matches between case trees.
			await rendered.unmount();
		}
	});

	test('presents a Main-local active-anchor escalation without changing worker start facts', async () => {
		const refreshPresentation = candidatePresentation({
			effectivePresentationClass: { kind: 'promoted', reason: 'activeAnchor' },
			startDisposition: {
				affectedStableFileIdentities: ['item-1'],
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});
		const rendered = await renderRefreshHeader(refreshPresentation, ['item-1']);

		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Updating…');
		expect(rendered.getByTestId('bridge-viewer-content-status').query()).toBeNull();
		expect(
			rendered
				.getByTestId('bridge-review-refresh-header-group')
				.element()
				.querySelector('.lucide-loader-circle'),
		).toBeNull();
		expect(refreshPresentation.candidate?.startDisposition).toMatchObject({
			presentationClass: { kind: 'ordinary' },
		});
	});

	test('treats symbolic unknown as affected only while Review owns attention', async () => {
		const refreshPresentation = candidatePresentation({
			startDisposition: {
				affectedStableFileIdentities: [],
				kind: 'sameSource',
				presentationClass: { kind: 'promoted', reason: 'unknown' },
			},
		});
		const rendered = await renderRefreshHeader(refreshPresentation, ['item-1']);
		await expect
			.element(rendered.getByTestId('bridge-review-refresh-header-group'))
			.toHaveTextContent('Updating…');

		await rendered.rerender(refreshHeader(refreshPresentation, []));
		expect(rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
	});

	test('groups Update ready with Apply now using the primary accent', async () => {
		const rendered = await renderRefreshHeader(
			candidatePresentation({
				role: 'updateReady',
				startDisposition: {
					affectedStableFileIdentities: ['item-1'],
					kind: 'sameSource',
					presentationClass: { kind: 'promoted', reason: 'lines' },
				},
			}),
			['item-1'],
		);
		const group = rendered.getByTestId('bridge-review-refresh-header-group').element();

		expect(group.className).toContain('text-primary');
		await expect.element(rendered.getByRole('button', { name: 'Apply now' })).toBeVisible();
		expect(group.contains(rendered.getByRole('button', { name: 'Apply now' }).element())).toBe(
			true,
		);
	});

	test('reserves one stable right-side slot across silent and promoted states', async () => {
		const silentPresentation = candidatePresentation({
			startDisposition: {
				affectedStableFileIdentities: ['item-1'],
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});
		const readyPresentation = candidatePresentation({
			role: 'updateReady',
			startDisposition: {
				affectedStableFileIdentities: ['item-1'],
				kind: 'sameSource',
				presentationClass: { kind: 'promoted', reason: 'files' },
			},
		});
		const rendered = await renderRefreshHeader(silentPresentation, ['item-1']);
		const title = rendered.getByTestId('bridge-viewer-content-title').element();
		const silentTitleBounds = title.getBoundingClientRect();
		const silentSlotBounds = rendered
			.getByTestId('bridge-review-refresh-header-slot')
			.element()
			.getBoundingClientRect();

		await rendered.rerender(refreshHeader(readyPresentation, ['item-1']));
		const readyTitleBounds = title.getBoundingClientRect();
		const readySlotBounds = rendered
			.getByTestId('bridge-review-refresh-header-slot')
			.element()
			.getBoundingClientRect();

		expect(readyTitleBounds.left).toBe(silentTitleBounds.left);
		expect(readyTitleBounds.width).toBe(silentTitleBounds.width);
		expect(readySlotBounds.width).toBe(silentSlotBounds.width);
	});

	test.each([true, false])(
		'promoted failure (retryable %s) has no toolbar failure copy or control',
		async (retryable): Promise<void> => {
			const rendered = await renderRefreshHeader(failurePresentation(retryable), ['item-1']);
			expect(rendered.getByTestId('bridge-review-refresh-header-group').query()).toBeNull();
			expect(rendered.getByRole('button', { name: 'Retry' }).query()).toBeNull();
			expect(document.body.innerText).not.toContain('unavailable');
		},
	);
});

async function renderRefreshHeader(
	refreshPresentation: BridgeMainReviewRefreshPresentation,
	attentionItemIds: readonly string[],
): ReturnType<typeof render> extends Promise<infer TResult> ? Promise<TResult> : never {
	return render(refreshHeader(refreshPresentation, attentionItemIds));
}

function refreshHeader(
	refreshPresentation: BridgeMainReviewRefreshPresentation,
	attentionItemIds: readonly string[],
): ReactElement {
	const presentation = bridgeReviewRefreshHeaderPresentation({
		attentionItemIds,
		canRetry: true,
		refreshPresentation,
	});
	return (
		<BridgeViewerContentHeader
			controls={
				<BridgeReviewRefreshHeaderGroup
					onApplyNow={vi.fn()}
					onRetry={vi.fn()}
					presentation={presentation}
				/>
			}
			mode="review"
			statusText={null}
			title="Sources/First.swift"
		/>
	);
}

function candidatePresentation(props: {
	readonly effectivePresentationClass?: NonNullable<
		BridgeMainReviewRefreshPresentation['candidate']
	>['effectivePresentationClass'];
	readonly role?: NonNullable<BridgeMainReviewRefreshPresentation['candidate']>['role'];
	readonly startDisposition: NonNullable<
		BridgeMainReviewRefreshPresentation['candidate']
	>['startDisposition'];
}): BridgeMainReviewRefreshPresentation {
	return {
		activeIdentity,
		candidate: {
			affectedStableFileIdentities:
				props.startDisposition.kind === 'sameSource'
					? props.startDisposition.affectedStableFileIdentities
					: [],
			effectivePresentationClass:
				props.effectivePresentationClass ??
				(props.startDisposition.kind === 'sameSource'
					? props.startDisposition.presentationClass
					: { kind: 'ordinary' }),
			identity: candidateIdentity,
			role: props.role ?? 'provisional',
			startDisposition: props.startDisposition,
		},
		failure: null,
	};
}

function failurePresentation(retryable: boolean): BridgeMainReviewRefreshPresentation {
	return {
		activeIdentity,
		candidate: null,
		failure: {
			kind: 'promotedRefresh',
			affectedStableFileIdentities: ['item-1'],
			identity: candidateIdentity,
			presentationClass: { kind: 'promoted', reason: 'commits' },
			retryable,
		},
	};
}
