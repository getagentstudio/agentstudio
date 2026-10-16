import type { Page } from 'playwright';

import { reviewWaitTerminalOwner } from './bridge-viewer-vite-review-owner-wait.ts';

export type SelectedContentReadyTarget =
	| { readonly surface: 'review'; readonly itemId: string }
	| {
			readonly surface: 'file';
			readonly expectedSha256: string;
			readonly itemId?: string;
			readonly goal?: 'descriptor-prepared' | 'content-closed';
	  };

/** The same script is consumed by Playwright and the deterministic Node adapter proofs. */
export function selectedContentOwnerWaitScript(props: {
	readonly label: string;
	readonly target: SelectedContentReadyTarget;
}): string {
	const input = JSON.stringify({ ...props.target, label: props.label });
	return `(async () => {
				const input = ${input};
				const terminalOwner = (${reviewWaitTerminalOwner.toString()});
				let workerSessionState = window.__bridgeReviewSelectionDiagnostic?.sessionState ?? null;
				const immediate = terminalOwner({ inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null, workerSessionState });
				if (immediate !== null) throw new Error(input.label + ' ended: ' + immediate);
				let diagnostics = null;
				if (location.protocol === 'http:' || location.protocol === 'https:') {
					diagnostics = await import(new URL('/src/foundation/diagnostics/bridge-review-selection-diagnostic.ts', location.href).href);
					workerSessionState = diagnostics.readBridgeReviewSelectionDiagnostic()?.sessionState ?? null;
				}
				await new Promise((resolve, reject) => {
					let unsubscribeWorker = () => {};
					let ended = false;
					const finish = error => {
						if (ended) return;
						ended = true;
						observer.disconnect(); unsubscribeWorker();
						document.removeEventListener('__bridge_selected_content_owner_changed', inspect);
						window.removeEventListener('pagehide', retired);
						if (error === null) resolve(); else reject(error);
					};
					const retired = () => finish(new Error(input.label + ' ended: document-retired'));
					const inspect = () => {
						if (ended) return;
						try {
							const owner = terminalOwner({ inactiveSession: document.querySelector('[data-testid="bridge-dev-session-inactive"]') !== null, workerSessionState });
							const observation = window.bridgeSelectedContentOwnerObservation?.read(input.surface);
							const panel = input.surface === 'review'
								? [...document.querySelectorAll('[data-testid="bridge-code-view-panel"]')].find(element => element.getAttribute('data-selected-item-id') === input.itemId)
								: document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
							// Bind failures to the requested operation, even if last-complete content unmounts.
							const itemId = input.itemId ?? observation?.selectedItemId ?? panel?.getAttribute('data-worktree-rendered-item-id');
							const activePublicationId = window.__bridgeReviewSelectionDiagnostic?.reviewInstallationGate?.activeIdentity?.publicationId ?? null;
							const matchesDisplayedPublication = input.surface !== 'review' || activePublicationId === null || observation?.publicationId === activePublicationId;
							// Replacement retires the predecessor before a successor channel can reset its cached facts.
							// Only the ready worker may close its current selected operation; owner terminals stay separate.
							const failure = workerSessionState === 'ready' && observation != null && observation.selectedItemId === itemId && matchesDisplayedPublication ? observation.failure : null;
							if (owner !== null || failure != null) {
								finish(new Error(input.label + ' ended: ' + (owner ?? failure.reason) + '; ' + JSON.stringify(observation ?? null)));
								return;
							}
							const painted = panel?.querySelector('diffs-container[data-bridge-painted-source-correlations]');
							const correlations = JSON.parse(painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]');
						const ready = input.surface === 'file' && input.goal != null
							? workerSessionState === 'ready' && observation?.selectedItemId === itemId && (input.goal === 'descriptor-prepared' ? observation?.preparedSha256 : observation?.contentClosedSha256) === input.expectedSha256
							: input.surface === 'review'
								? panel?.getAttribute('data-selected-content-state') === 'ready' && painted != null
								: (input.itemId == null || panel?.getAttribute('data-worktree-rendered-item-id') === input.itemId) && panel?.getAttribute('data-worktree-open-file-state') === 'ready' && Array.isArray(correlations) && correlations.some(correlation => correlation?.observedSha256 === input.expectedSha256);
							if (ready) finish(null);
						} catch (error) { finish(error); }
					};
					const observer = new MutationObserver(inspect);
					observer.observe(document, { attributes: true, childList: true, subtree: true });
					document.addEventListener('__bridge_selected_content_owner_changed', inspect);
					window.addEventListener('pagehide', retired, { once: true });
					if (diagnostics !== null) unsubscribeWorker = diagnostics.observeBridgePaneCommWorkerSessionDiagnosticSnapshots(snapshot => { workerSessionState = snapshot.state; inspect(); });
					inspect();
				});
			})()`;
}

export async function waitForSelectedContentOwnerReady(props: {
	readonly page: Page;
	readonly label: string;
	readonly target: SelectedContentReadyTarget;
}): Promise<void> {
	await waitForOwnerOrRetirement({
		label: props.label,
		subscribeRetirement: (retire): (() => void) => {
			const closed = (): void => retire('page-closed');
			const crashed = (): void => retire('page-crashed');
			props.page.on('close', closed);
			props.page.on('crash', crashed);
			if (props.page.isClosed()) closed();
			return (): void => {
				props.page.off('close', closed);
				props.page.off('crash', crashed);
			};
		},
		run: async (): Promise<void> => {
			await props.page.evaluate(selectedContentOwnerWaitScript(props));
		},
	});
}

/** Both branches have owners; no elapsed-time or scheduler-turn verdict is involved. */
export function waitForOwnerOrRetirement(props: {
	readonly label: string;
	readonly subscribeRetirement: (retire: (reason: string) => void) => () => void;
	readonly run: () => Promise<void>;
}): Promise<void> {
	return new Promise((resolve, reject): void => {
		let ended = false;
		let unsubscribe: (() => void) | null = null;
		const finish = (error: unknown): void => {
			if (ended) return;
			ended = true;
			unsubscribe?.();
			if (error === null) resolve();
			else reject(error);
		};
		unsubscribe = props.subscribeRetirement((reason): void => {
			finish(new Error(`${props.label} ended: ${reason}`));
		});
		if (ended) {
			unsubscribe?.();
			return;
		}
		void Promise.resolve()
			.then(props.run)
			.then(
				(): void => finish(null),
				(error: unknown): void => finish(error),
			);
	});
}
