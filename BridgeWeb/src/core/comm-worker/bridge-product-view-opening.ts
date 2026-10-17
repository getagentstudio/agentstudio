import type { BridgeProductViewScopeOwner } from './bridge-product-view-scope-owner.js';

/** W2 admits an initial view scope after its subscription open settles. */
export function bridgeProductInitialViewOpening(
	scopeOwner: Pick<BridgeProductViewScopeOwner, 'register' | 'setScope'>,
	subscriptionKind: string,
):
	| ((subscriptionId: string, signal: AbortSignal, worktreeId: string | null) => Promise<void>)
	| undefined {
	if (subscriptionKind === 'file.metadata' || subscriptionKind === 'review.metadata') {
		return async (subscriptionId, signal): Promise<void> => {
			const scope =
				subscriptionKind === 'file.metadata'
					? ({
							kind: 'file',
							changeFilter: { kind: 'none' },
							interests: [],
							pathScope: [],
						} as const)
					: ({ kind: 'review', interests: [] } as const);
			scopeOwner.register({ scope, subscriptionId, subscriptionKind });
			const settlement = await scopeOwner.setScope({ scope, signal, subscriptionId });
			if (settlement.kind === 'cancelled' && signal.aborted) {
				throw signal.reason ?? new Error('Initial metadata view scope was cancelled.');
			}
		};
	}
	if (subscriptionKind !== 'file.annotations' && subscriptionKind !== 'review.annotations') {
		return undefined;
	}
	return async (subscriptionId, signal, worktreeId): Promise<void> => {
		if (worktreeId === null) {
			throw new Error('Comment subscription open did not supply native worktree authority.');
		}
		const scope = { kind: 'comment', sessionIds: [], worktreeId } as const;
		scopeOwner.register({
			scope,
			subscriptionId,
			subscriptionKind,
		});
		const settlement = await scopeOwner.setScope({ scope, signal, subscriptionId });
		if (settlement.kind === 'cancelled' && signal.aborted) {
			throw signal.reason ?? new Error('Initial metadata view scope was cancelled.');
		}
	};
}
