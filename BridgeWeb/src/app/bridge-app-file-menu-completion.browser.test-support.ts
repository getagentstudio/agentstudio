import {
	act,
	Children,
	createElement,
	isValidElement,
	type ComponentProps,
	type ReactElement,
} from 'react';
import { beforeEach, expect, test, vi } from 'vitest';

import { actClick } from './bridge-app-browser-test-actions.js';
import {
	dispatchBridgeViewerFilterShortcut,
	requireActiveContextButton,
	requireHTMLElement,
} from './bridge-app-pane-runtime-control-test-support.js';

const popupSelector = '[data-testid="worktree-file-filter-menu-popover"]';
let lastWaitStep: string | undefined;

beforeEach((context): void => {
	lastWaitStep = undefined;
	context.onTestFinished((): void => {
		if (
			lastWaitStep !== undefined &&
			(context.signal.aborted || context.task.result?.state === 'fail')
		) {
			console.info(`GO30 failed/aborted while awaiting ${lastWaitStep}.`);
		}
	});
});

function beginFileMenuWait(step: string): void {
	lastWaitStep = step;
	console.info(`GO30 awaiting ${step}.`);
}

export function withEagerAppFileShell(
	original: typeof import('../file-viewer/bridge-file-viewer-app.js'),
	shellComponent: typeof import('../file-viewer/bridge-file-viewer-shell.js').BridgeFileViewerShell,
): typeof original {
	return {
		...original,
		BridgeFileViewerApp: (
			props: ComponentProps<typeof original.BridgeFileViewerApp>,
		): ReactElement =>
			createElement(original.BridgeFileViewerAppImplementation, { ...props, shellComponent }),
	};
}

export async function waitForFilesShell(): Promise<Element> {
	beginFileMenuWait('Files shell DOM mount');
	const selector = '[data-testid="bridge-file-viewer-shell"]';
	const currentShell = document.querySelector(selector);
	if (currentShell !== null) return currentShell;
	let observer: MutationObserver | undefined;
	try {
		return await new Promise<Element>((resolve): void => {
			observer = new MutationObserver((): void => {
				const shell = document.querySelector(selector);
				if (shell !== null) resolve(shell);
			});
			observer.observe(document.body, { childList: true, subtree: true });
		});
	} finally {
		observer?.disconnect();
	}
}

export async function dismissFilesFilterMenu(props: {
	readonly appRoot: HTMLElement;
	readonly host: HTMLElement;
	readonly popup: HTMLElement;
	readonly onAwaitUnmount?: () => Promise<void>;
}): Promise<void> {
	const dismissal = observeFilesFilterDismissal(props);
	try {
		beginFileMenuWait('Review switch: active context lookup and click');
		await actClick(requireActiveContextButton('review'));
		await act(async (): Promise<void> => {
			await props.onAwaitUnmount?.();
			await finishFilesFilterAnimations(props.popup);
			beginFileMenuWait('Files filter popup unmount with retained host inactive');
			await dismissal.promise;
		});
		expect(props.appRoot.getAttribute('data-bridge-viewer-mode')).toBe('review');
		expect(props.host.getAttribute('data-bridge-viewer-mode-active')).toBe('false');
		expect(props.host.isConnected).toBe(true);
		expect(props.popup.isConnected).toBe(false);
		expect(document.querySelector(popupSelector)).toBeNull();
	} finally {
		dismissal.dispose();
	}
}

export function observeFilesFilterDismissal(props: {
	readonly host: HTMLElement;
	readonly popup: HTMLElement;
}): { readonly promise: Promise<void>; readonly dispose: () => void } {
	let resolveDismissal: (() => void) | undefined;
	const promise = new Promise<void>((resolve): void => {
		resolveDismissal = resolve;
	});
	const observer = new MutationObserver((): void => {
		if (
			props.host.getAttribute('data-bridge-viewer-mode-active') === 'false' &&
			!props.popup.isConnected
		) {
			observer.disconnect();
			resolveDismissal?.();
		}
	});
	observer.observe(document.body, { attributes: true, childList: true, subtree: true });
	return { promise, dispose: (): void => observer.disconnect() };
}

type FileMenuLifecycleFact =
	| { readonly kind: 'completion'; readonly open: boolean }
	| { readonly kind: 'native-finished' | 'native-cancelled' };
const lifecycleFacts: FileMenuLifecycleFact[] = [];
let recordingCloseLifecycle = false;

export function withAppFileMenuLifecycle(
	original: typeof import('../components/ui/dropdown-menu.js'),
): typeof original {
	return {
		...original,
		DropdownMenu: (props: ComponentProps<typeof original.DropdownMenu>): ReactElement => {
			if (typeof props.children === 'function') return createElement(original.DropdownMenu, props);
			const ownsFileFilter = Children.toArray(props.children).some(
				(child): boolean =>
					isValidElement<{ readonly testId?: string }>(child) &&
					child.props.testId === 'worktree-file-filter-menu',
			);
			if (!ownsFileFilter) return createElement(original.DropdownMenu, props);
			return createElement(original.DropdownMenu, {
				...props,
				onOpenChangeComplete: (open: boolean): void => {
					props.onOpenChangeComplete?.(open);
					if (recordingCloseLifecycle) lifecycleFacts.push({ kind: 'completion', open });
				},
			});
		},
	};
}

export function holdFilesFilterCloseAnimation(): {
	readonly captured: Promise<readonly Animation[]>;
	readonly release: () => void;
	readonly dispose: () => void;
	readonly facts: () => readonly FileMenuLifecycleFact[];
} {
	lifecycleFacts.length = 0;
	recordingCloseLifecycle = true;
	let releaseFinished: (() => void) | undefined;
	const heldFinished = new Promise<void>((resolve): void => {
		releaseFinished = resolve;
	});
	let publishCapture: ((animations: readonly Animation[]) => void) | undefined;
	const captured = new Promise<readonly Animation[]>((resolve): void => {
		publishCapture = resolve;
	});
	// oxlint-disable-next-line unbound-method -- Rebound to the original Element receiver.
	const originalGetAnimations = Element.prototype.getAnimations;
	const spy = vi.spyOn(Element.prototype, 'getAnimations').mockImplementation(function (
		this: Element,
		options?: GetAnimationsOptions,
	): Animation[] {
		const animations = originalGetAnimations.call(this, options);
		if (!this.matches(`${popupSelector}[data-closed]`) || options?.subtree === true)
			return animations;
		if (animations.length > 0) publishCapture?.(animations);
		return animations.map(
			(animation): Animation =>
				new Proxy(animation, {
					get: (target, key): unknown => {
						if (key === 'finished')
							return target.finished.then(
								async (): Promise<Animation> => {
									lifecycleFacts.push({ kind: 'native-finished' });
									await heldFinished;
									return target;
								},
								(error: unknown): never => {
									lifecycleFacts.push({ kind: 'native-cancelled' });
									throw error;
								},
							);
						const value: unknown = Reflect.get(target, key, target);
						return typeof value === 'function' ? value.bind(target) : value;
					},
				}),
		);
	});
	return {
		captured,
		release: (): void => releaseFinished?.(),
		dispose: (): void => {
			releaseFinished?.();
			spy.mockRestore();
			recordingCloseLifecycle = false;
			lifecycleFacts.length = 0;
		},
		facts: (): readonly FileMenuLifecycleFact[] => [...lifecycleFacts],
	};
}

export async function finishFilesFilterAnimations(popup: HTMLElement): Promise<void> {
	beginFileMenuWait('Files filter native animations finished or cancelled');
	await act(async (): Promise<void> => {
		await Promise.all(
			popup.getAnimations({ subtree: true }).map(async (animation): Promise<void> => {
				const finished = animation.finished;
				animation.finish();
				try {
					await finished;
				} catch {
					/* A replacement or removal can cancel a native transition. */
				}
			}),
		);
	});
}

export async function mountOpenFilesFilterMenu(mount: () => Promise<unknown>): Promise<{
	readonly appRoot: HTMLElement;
	readonly host: HTMLElement;
	readonly popup: HTMLElement;
}> {
	beginFileMenuWait('Files filter fixture React mount commit');
	await act(async (): Promise<void> => {
		await mount();
	});
	expect(await waitForFilesShell()).not.toBeNull();
	beginFileMenuWait('Files filter shortcut open commit');
	await dispatchBridgeViewerFilterShortcut();
	const popup = requireHTMLElement(
		document.querySelector('[data-testid="worktree-file-filter-menu-popover"][data-open]'),
	);
	return {
		appRoot: requireHTMLElement(document.querySelector('[data-testid="bridge-app-root"]')),
		host: requireHTMLElement(
			document.querySelector('[data-testid="bridge-viewer-mode-host-file"]'),
		),
		popup,
	};
}

export async function proveHeldFilesFilterDismissal(mount: () => Promise<unknown>): Promise<void> {
	const { appRoot, host, popup } = await mountOpenFilesFilterMenu(mount);
	const heldClose = holdFilesFilterCloseAnimation();
	try {
		await dismissFilesFilterMenu({
			appRoot,
			host,
			popup,
			onAwaitUnmount: async (): Promise<void> => {
				beginFileMenuWait('Files filter native close animation capture');
				const animations = await heldClose.captured;
				expect(host.getAttribute('data-bridge-viewer-mode-active')).toBe('false');
				expect(popup.isConnected).toBe(true);
				heldClose.release();
				for (const animation of animations) animation.finish();
			},
		});
		await act(async (): Promise<void> => {
			beginFileMenuWait('Files filter native close animation capture receipt');
			await heldClose.captured;
		});
		expect(
			popup.isConnected,
			'Dismissal must join popup unmount, not just removal of data-open.',
		).toBe(false);
		expect(host.isConnected).toBe(true);
		expect(heldClose.facts()).toContainEqual({ kind: 'native-finished' });
		expect(heldClose.facts()).toContainEqual({ kind: 'completion', open: false });
		console.info('[go30-close-lifecycle]', JSON.stringify(heldClose.facts()));
	} finally {
		heldClose.release();
		heldClose.dispose();
	}
}

export function registerFilesFilterDismissalTests(mount: () => Promise<unknown>): void {
	test('dismisses the Files filter menu before its retained host becomes inactive', async (): Promise<void> => {
		await dismissFilesFilterMenu(await mountOpenFilesFilterMenu(mount));
	});
	test('joins Files filter popup unmount when its native close completion is held after host inactivity', async (): Promise<void> => {
		await proveHeldFilesFilterDismissal(mount);
	});
	test('preserves a named pre-switch failure and disposes the held Files menu observation', async (): Promise<void> => {
		// oxlint-disable-next-line unbound-method -- Compare the restored method identity; do not invoke it unbound.
		const originalGetAnimations = Element.prototype.getAnimations;
		const switchFailure = new Error('GO30 injected failure before Review switch');
		// oxlint-disable-next-line unbound-method -- Rebound below to the original clicked element.
		const originalClick = HTMLElement.prototype.click;
		const clickSpy = vi
			.spyOn(HTMLElement.prototype, 'click')
			.mockImplementation(function (this: HTMLElement): void {
				if (this.getAttribute('data-testid') === 'bridge-viewer-context-review')
					throw switchFailure;
				originalClick.call(this);
			});
		try {
			await expect(proveHeldFilesFilterDismissal(mount)).rejects.toBe(switchFailure);
			console.info(`GO30 preserved original failure: ${switchFailure.message}.`);
			// oxlint-disable-next-line unbound-method -- Compare the restored method identity; do not invoke it unbound.
			expect(Element.prototype.getAnimations).toBe(originalGetAnimations);
			expect(recordingCloseLifecycle).toBe(false);
		} finally {
			clickSpy.mockRestore();
		}
	});
}
