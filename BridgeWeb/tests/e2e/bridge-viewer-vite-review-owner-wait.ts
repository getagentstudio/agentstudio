import type { Page } from 'playwright';
import { z } from 'zod';

export type ReviewTerminalOwner = 'open-elsewhere' | 'worker-recovery-exhausted';

/** Failed presentations and failedRetryable view status do not end automatic recovery. */
export function reviewWaitTerminalOwner(props: {
	readonly inactiveSession: boolean;
	readonly workerSessionState: string | null;
}): ReviewTerminalOwner | null {
	if (props.inactiveSession) return 'open-elsewhere';
	// BridgePaneCommWorkerSession publishes "failed" only from #failReplacementBudget.
	if (props.workerSessionState === 'failed') return 'worker-recovery-exhausted';
	return null;
}

const reviewOwnerWaitObservationSchema = z
	.object({
		workerSessionState: z.string().nullable(),
		selectedItemId: z.string().nullable(),
		selectedContentState: z.string().nullable(),
		painted: z.boolean(),
	})
	.strict();
const reviewOwnerWaitOutcomeSchema = z.discriminatedUnion('kind', [
	reviewOwnerWaitObservationSchema.extend({ kind: z.literal('ready'), owner: z.null() }),
	reviewOwnerWaitObservationSchema.extend({
		kind: z.literal('terminal'),
		owner: z.enum(['open-elsewhere', 'worker-recovery-exhausted']),
	}),
]);
export type ReviewOwnerWaitOutcome = z.infer<typeof reviewOwnerWaitOutcomeSchema>;

/** One page-side owner predicate serves shell mounting and selected painted readiness. */
export async function waitForReviewOwnerOutcome(
	props: {
		readonly page: Page;
	} & ({ readonly goal: 'shell' } | { readonly goal: 'selected-painted'; readonly itemId: string }),
): Promise<ReviewOwnerWaitOutcome> {
	const input = JSON.stringify({
		goal: props.goal,
		itemId: props.goal === 'selected-painted' ? props.itemId : null,
	});
	// Native import must stay in the page realm; Vite SSR rewrites imports in serialized callbacks.
	// Both embedded values are trusted test code or JSON-encoded test inputs.
	const value: unknown = await props.page.evaluate(`(async () => {
		const input = ${input};
		const terminalOwner = (${reviewWaitTerminalOwner.toString()});
		let workerSessionState = window.__bridgeReviewSelectionDiagnostic?.sessionState ?? null;
		const immediate = terminalOwner({
			inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null,
			workerSessionState
		});
		if (immediate !== null) return {
			kind: 'terminal', owner: immediate, workerSessionState,
			selectedItemId: null, selectedContentState: null, painted: false
		};
		let diagnostics = null;
		if (location.protocol === 'http:' || location.protocol === 'https:') {
			diagnostics = await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href);
			workerSessionState = diagnostics.readBridgeReviewSelectionDiagnostic()?.sessionState ?? null;
		}
		return await new Promise(resolve => {
			let unsubscribeOwner = () => {};
			let closed = false;
			const inspect = () => {
				if (closed) return;
				const owner = terminalOwner({
					inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null,
					workerSessionState
				});
				const panel = [...document.querySelectorAll('[data-testid="bridge-code-view-panel"]')]
					.find(candidate => candidate.getAttribute('data-selected-item-id') === input.itemId);
				const painted = panel?.querySelector('diffs-container[data-bridge-painted-source-correlations]') != null;
				const selectedContentState = panel?.getAttribute('data-selected-content-state') ?? null;
				const ready = input.goal === 'shell'
					? document.querySelector('[data-testid="review-viewer-shell"]') !== null
					: selectedContentState === 'ready' && painted;
				if (owner === null && !ready) return;
				closed = true;
				observer.disconnect();
				unsubscribeOwner();
				resolve({
					kind: owner === null ? 'ready' : 'terminal', owner, workerSessionState,
					selectedItemId: panel?.getAttribute('data-selected-item-id') ?? null,
					selectedContentState, painted
				});
			};
			const observer = new MutationObserver(inspect);
			observer.observe(document, { attributes: true, childList: true, subtree: true });
			if (diagnostics !== null) unsubscribeOwner = diagnostics.observeBridgePaneCommWorkerSessionDiagnosticSnapshots(snapshot => {
				workerSessionState = snapshot.state;
				inspect();
			});
			inspect();
		});
	})()`);
	return reviewOwnerWaitOutcomeSchema.parse(value);
}
