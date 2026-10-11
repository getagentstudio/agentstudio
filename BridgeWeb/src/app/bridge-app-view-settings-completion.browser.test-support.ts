import {
	Children,
	createElement,
	isValidElement,
	useLayoutEffect,
	useRef,
	type ComponentProps,
	type ReactElement,
} from 'react';
import { afterEach, beforeEach, vi } from 'vitest';

import { BridgeProductTestFactRecorder } from '../core/comm-worker/test-fixtures/bridge-product-test-fact-recorder.js';
import { actWait } from './bridge-app-browser-test-actions.js';

type SettingsSurface = 'file' | 'review';
interface SettingsCloseFact {
	readonly kind: 'completed' | 'retired';
	readonly surface: SettingsSurface;
	readonly count: number;
}

let closeFacts = new BridgeProductTestFactRecorder<SettingsCloseFact>();
let ownerSignal: AbortSignal | undefined;
const closeCountBySurface = new Map<SettingsSurface, number>();
const expectedCloseBySurface = new Map<SettingsSurface, number>();
const activeRootBySurface = new Map<SettingsSurface, object>();
const expectedRootBySurface = new Map<SettingsSurface, object>();
let restoreAnimations: (() => void) | null = null;

beforeEach((context): void => {
	restoreAnimations?.();
	restoreAnimations = null;
	ownerSignal = context.signal;
	closeFacts = new BridgeProductTestFactRecorder<SettingsCloseFact>();
	closeCountBySurface.clear();
	expectedCloseBySurface.clear();
	activeRootBySurface.clear();
	expectedRootBySurface.clear();
	// Observe/drive the real animation dependency when its actual close owner requests it.
	// oxlint-disable-next-line unbound-method -- The original is called with its Element receiver.
	const originalGetAnimations = Element.prototype.getAnimations;
	const animationSpy = vi.spyOn(Element.prototype, 'getAnimations').mockImplementation(function (
		this: Element,
		options?: GetAnimationsOptions,
	): Animation[] {
		const animations = originalGetAnimations.call(this, options);
		const surface = surfaceForSettingsTestId(this.getAttribute('data-testid'));
		if (
			surface !== null &&
			this.hasAttribute('data-closed') &&
			expectedCloseBySurface.has(surface)
		) {
			for (const animation of animations) animation.finish();
		}
		return animations;
	});
	restoreAnimations = (): void => animationSpy.mockRestore();
	context.onTestFinished((): void => animationSpy.mockRestore());
});

afterEach((): void => {
	restoreAnimations?.();
	restoreAnimations = null;
	ownerSignal = undefined;
	closeFacts.close(new Error('View Settings completion observation closed.'));
	closeCountBySurface.clear();
	expectedCloseBySurface.clear();
	activeRootBySurface.clear();
	expectedRootBySurface.clear();
});

export function withViewSettingsPopoverLifecycle(
	original: typeof import('../components/ui/popover.js'),
): typeof original {
	return {
		...original,
		Popover: (props: ComponentProps<typeof original.Popover>): ReactElement => {
			const instance = useRef<object>({}).current;
			const content =
				typeof props.children === 'function'
					? undefined
					: Children.toArray(props.children).find(
							(child): boolean =>
								isValidElement<{ readonly 'data-testid'?: string }>(child) &&
								surfaceForSettingsTestId(child.props['data-testid']) !== null,
						);
			const surface = isValidElement<{ readonly 'data-testid'?: string }>(content)
				? surfaceForSettingsTestId(content.props['data-testid'])
				: null;
			useLayoutEffect((): (() => void) | undefined => {
				if (surface === null) return undefined;
				activeRootBySurface.set(surface, instance);
				return (): void => {
					publishSettingsEnd(surface, instance, 'retired');
					if (activeRootBySurface.get(surface) === instance) activeRootBySurface.delete(surface);
				};
			}, [instance, surface]);
			if (surface === null) return createElement(original.Popover, props);
			return createElement(original.Popover, {
				...props,
				onOpenChangeComplete: (open: boolean): void => {
					props.onOpenChangeComplete?.(open);
					if (!open) publishSettingsEnd(surface, instance, 'completed');
				},
			});
		},
	};
}

export function markViewSettingsOpening(surface: SettingsSurface): void {
	const instance = activeRootBySurface.get(surface);
	if (instance === undefined) throw new Error(`View Settings ${surface} Root was not installed.`);
	expectedRootBySurface.set(surface, instance);
	expectedCloseBySurface.set(surface, (closeCountBySurface.get(surface) ?? 0) + 1);
}

export function hasPendingViewSettingsClose(surface: SettingsSurface): boolean {
	return expectedCloseBySurface.has(surface);
}

export async function awaitViewSettingsClose(
	surface: SettingsSurface,
	expectedDisposition: 'completed' | 'completedOrRetired' = 'completedOrRetired',
): Promise<void> {
	const count = expectedCloseBySurface.get(surface);
	if (count === undefined) return;
	const signal = ownerSignal;
	if (signal === undefined) throw new Error('View Settings close observation has no test owner.');
	const cancel = (): void => closeFacts.close(new Error(`View Settings ${surface} close aborted.`));
	signal.addEventListener('abort', cancel, { once: true });
	try {
		if (signal.aborted) cancel();
		const outcome = await closeFacts.waitFor(
			(fact): boolean => fact.surface === surface && fact.count === count,
		);
		if (expectedDisposition === 'completed' && outcome.kind !== 'completed')
			throw new Error(`View Settings ${surface} retired before normal close completion.`);
		expectedCloseBySurface.delete(surface);
		expectedRootBySurface.delete(surface);
	} finally {
		signal.removeEventListener('abort', cancel);
	}
}

function publishSettingsEnd(
	surface: SettingsSurface,
	instance: object,
	kind: SettingsCloseFact['kind'],
): void {
	if (
		ownerSignal === undefined ||
		ownerSignal.aborted ||
		expectedRootBySurface.get(surface) !== instance
	)
		return;
	const count = expectedCloseBySurface.get(surface);
	if (count === undefined || (closeCountBySurface.get(surface) ?? 0) >= count) return;
	closeCountBySurface.set(surface, count);
	closeFacts.record({ kind, surface, count });
}

export function joinViewSettingsCloseWithinAct(surface: SettingsSurface): Promise<void> {
	return actWait(async (): Promise<void> => await awaitViewSettingsClose(surface, 'completed'));
}

function surfaceForSettingsTestId(testId: string | null | undefined): SettingsSurface | null {
	if (testId === 'bridge-file-view-settings-content') return 'file';
	if (testId === 'bridge-review-view-settings-content') return 'review';
	return null;
}
