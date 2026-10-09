import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { BridgeProductViewScopeOwner } from './bridge-product-view-scope-owner.js';

type ViewScopeOwnerProps = ConstructorParameters<typeof BridgeProductViewScopeOwner>[0];

const noDeadlineClock: BridgeProductDeadlineClock = { schedule: () => (): void => {} };

/** Existing scope tests do not advance time; deadline cases supply a controlled clock. */
export function createTestViewScopeOwner(
	props: Omit<ViewScopeOwnerProps, 'deadlineClock' | 'progressDeadlineMilliseconds'> &
		Partial<Pick<ViewScopeOwnerProps, 'deadlineClock' | 'progressDeadlineMilliseconds'>>,
): BridgeProductViewScopeOwner {
	return new BridgeProductViewScopeOwner({
		...props,
		deadlineClock: props.deadlineClock ?? noDeadlineClock,
		progressDeadlineMilliseconds: props.progressDeadlineMilliseconds ?? 5_000,
	});
}
