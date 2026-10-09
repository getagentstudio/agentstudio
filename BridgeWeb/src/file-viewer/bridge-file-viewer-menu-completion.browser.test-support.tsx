import {
	createElement,
	type ComponentProps,
	type ReactElement,
	isValidElement,
	Children,
} from 'react';
import { afterEach } from 'vitest';

interface MenuCompletionFact {
	readonly testId: string;
	readonly open: boolean;
	readonly sequence: number;
}
const menuFacts = {
	sequence: 0,
	awaitingCompletion: undefined as ((open: boolean) => void) | undefined,
	completed: [] as MenuCompletionFact[],
	waiters: new Set<{
		readonly testId: string;
		readonly open: boolean;
		readonly after: number;
		readonly resolve: () => void;
		readonly reject: (error: Error) => void;
	}>(),
};

export function withFileMenuCompletion(
	original: typeof import('../components/ui/dropdown-menu.js'),
): typeof original {
	return {
		...original,
		DropdownMenu: (props: ComponentProps<typeof original.DropdownMenu>): ReactElement => {
			if (typeof props.children === 'function') return createElement(original.DropdownMenu, props);
			const trigger = Children.toArray(props.children).find(
				(child) =>
					isValidElement<{ readonly testId?: string }>(child) &&
					child.props.testId === 'worktree-file-filter-menu',
			);
			if (!isValidElement<{ readonly testId?: string }>(trigger))
				return createElement(original.DropdownMenu, props);
			const testId = trigger.props.testId;

			return createElement(original.DropdownMenu, {
				...props,
				onOpenChangeComplete: (open: boolean): void => {
					props.onOpenChangeComplete?.(open);
					if (testId === undefined) return;
					const fact = { testId, open, sequence: ++menuFacts.sequence };
					menuFacts.completed.push(fact);
					for (const waiter of menuFacts.waiters) {
						if (
							waiter.testId === fact.testId &&
							waiter.open === open &&
							waiter.after < fact.sequence
						) {
							menuFacts.waiters.delete(waiter);
							waiter.resolve();
						}
					}
				},
			});
		},
	};
}

afterEach((): void => {
	for (const waiter of menuFacts.waiters)
		waiter.reject(
			new Error(
				`File menu ${waiter.testId} awaited Base UI onOpenChangeComplete(${waiter.open}) at disposal.`,
			),
		);
	menuFacts.awaitingCompletion = undefined;
	menuFacts.waiters.clear();
	menuFacts.completed.length = 0;
});

export function fileMenuCompleted(open: boolean): boolean {
	return menuFacts.completed.at(-1)?.open === open;
}

export function prepareFileMenuCompletion(open: boolean): {
	readonly promise: Promise<void>;
	readonly dispose: () => void;
} {
	let waiter: (typeof menuFacts.waiters extends Set<infer TWaiter> ? TWaiter : never) | undefined;
	const promise = new Promise<void>((resolve, reject): void => {
		waiter = {
			testId: 'worktree-file-filter-menu',
			open,
			after: menuFacts.sequence,
			resolve,
			reject,
		};
		menuFacts.waiters.add(waiter);
	});
	void promise.catch((): void => {});
	return {
		promise,
		dispose: (): void => {
			if (waiter !== undefined) menuFacts.waiters.delete(waiter);
		},
	};
}

export function observeFileMenuCompletionWait(observer: (open: boolean) => void): () => void {
	menuFacts.awaitingCompletion = observer;
	return (): void => {
		menuFacts.awaitingCompletion = undefined;
	};
}

export async function waitForCurrentFileMenuCompletion(open: boolean): Promise<void> {
	menuFacts.awaitingCompletion?.(open);
	if (fileMenuCompleted(open)) return;
	const fact = prepareFileMenuCompletion(open);
	try {
		await fact.promise;
	} finally {
		fact.dispose();
	}
}
