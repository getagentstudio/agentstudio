import { act, type ReactElement } from 'react';
import { useState } from 'react';
import { afterEach, expect, test, vi } from 'vitest';

// oxlint-disable-next-line import/no-unassigned-import -- Exercise native Base UI CSS transitions.
import '../app/bridge-app.css';
import { cleanup, render } from 'vitest-browser-react';

import { actClickAndSettleFileViewerMenu } from './bridge-file-viewer-app-startup.browser.test-support.js';
import { BridgeFileViewerFacetMenu } from './bridge-file-viewer-facet-menu.js';
import {
	fileMenuCompleted,
	prepareFileMenuCompletion,
	observeFileMenuCompletionWait,
} from './bridge-file-viewer-menu-completion.browser.test-support.js';

function RealFileMenu(): ReactElement {
	const [open, setOpen] = useState(false);
	return (
		<BridgeFileViewerFacetMenu
			filterMode="all"
			onFilterModeChange={(): void => {}}
			onOpenChange={setOpen}
			open={open}
		/>
	);
}
afterEach(async (): Promise<void> => {
	vi.restoreAllMocks();
	await act(cleanup);
});

test('File menu helper joins native open completion after its animation finished promise is held', async (): Promise<void> => {
	await render(<RealFileMenu />);
	const trigger = document.querySelector('[data-testid="worktree-file-filter-menu"]');
	if (!(trigger instanceof HTMLElement)) throw new Error('Expected File menu trigger.');
	let releaseFinished: (() => void) | undefined;
	const holdFinished = new Promise<void>((resolve): void => {
		releaseFinished = resolve;
	});
	// oxlint-disable-next-line unbound-method -- The native method is explicitly rebound to its original Element receiver below.
	const originalGetAnimations = Element.prototype.getAnimations;
	let nativeCaptureCount = 0;
	const animationSpy = vi.spyOn(Element.prototype, 'getAnimations').mockImplementation(function (
		this: Element,
		options?: GetAnimationsOptions,
	): Animation[] {
		const animations = originalGetAnimations.call(this, options);
		if (
			this.getAttribute('data-testid') !== 'worktree-file-filter-menu-popover' ||
			options?.subtree === true
		)
			return animations;
		nativeCaptureCount += 1;
		return animations.map(
			(animation): Animation =>
				new Proxy(animation, {
					get: (target, key): unknown => {
						if (key === 'finished')
							return target.finished.then(async (): Promise<Animation> => {
								await holdFinished;
								return target;
							});
						return Reflect.get(target, key, target);
					},
				}),
		);
	});
	const completion = prepareFileMenuCompletion(true);
	const restoreWaitObservation = observeFileMenuCompletionWait((open): void => {
		if (open) releaseFinished?.();
	});
	try {
		await actClickAndSettleFileViewerMenu(trigger);
		expect(nativeCaptureCount).toBeGreaterThan(0);
		expect(
			fileMenuCompleted(true),
			'Rendered open state cannot substitute for native completion.',
		).toBe(true);
	} finally {
		restoreWaitObservation();
		animationSpy.mockRestore();
		await act(async (): Promise<void> => {
			releaseFinished?.();
			await completion.promise;
		});
		completion.dispose();
	}
});

vi.mock('../components/ui/dropdown-menu.js', async (importOriginal) => {
	const original = await importOriginal<typeof import('../components/ui/dropdown-menu.js')>();
	const { withFileMenuCompletion } =
		await import('./bridge-file-viewer-menu-completion.browser.test-support.js');
	return withFileMenuCompletion(original);
});
