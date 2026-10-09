export type BridgeRegionFailure =
	| {
			readonly kind: 'retryable';
			readonly scope: 'pane' | 'surface' | 'read';
			readonly message: string;
			readonly fileRootCause?: 'missingRoot' | 'unreadableRoot';
	  }
	| {
			readonly kind: 'permanent';
			readonly scope: 'pane' | 'surface' | 'read';
			readonly message: string;
			readonly correctiveAction: string;
	  };

export type BridgeRegionSurfaceStatus =
	| { readonly kind: 'current' | 'loading' }
	| { readonly kind: 'updating'; readonly rest?: 'held' | 'hidden' }
	| { readonly kind: 'failed'; readonly failure: BridgeRegionFailure };

export type BridgeRegionReadState =
	| { readonly kind: 'loading' }
	| { readonly kind: 'noSource' }
	| {
			readonly kind: 'complete' | 'partial';
			readonly identity: string;
			readonly hasContent: boolean;
	  }
	| {
			readonly kind: 'failed';
			readonly failure: BridgeRegionFailure;
			readonly retainedIdentity: string | null;
	  };

export interface BridgeRegionPresentationInput {
	readonly demandedIdentity: string | null;
	readonly read: BridgeRegionReadState;
	readonly surface: BridgeRegionSurfaceStatus;
}

export type BridgeRegionPresentationState =
	| { readonly kind: 'content' | 'loading' }
	| { readonly kind: 'empty'; readonly reason: 'noSelection' | 'certified' | 'noSource' }
	| { readonly kind: 'updating'; readonly rest: 'held' | 'hidden' | null }
	| {
			readonly kind: 'failed';
			readonly failure: BridgeRegionFailure;
			readonly retainsContent: boolean;
	  };

/** Projects existing facts only. Attempts, identity admission and recovery remain with their owners. */
export function projectBridgeRegionPresentation(
	input: BridgeRegionPresentationInput,
): BridgeRegionPresentationState {
	const readIdentity =
		input.read.kind === 'loading' || input.read.kind === 'noSource'
			? null
			: input.read.kind === 'failed'
				? input.read.retainedIdentity
				: input.read.identity;
	const hasContent =
		input.read.kind === 'failed'
			? readIdentity !== null
			: input.read.kind !== 'loading' && input.read.kind !== 'noSource' && input.read.hasContent;
	const hasDemandedContent = hasContent && readIdentity === input.demandedIdentity;
	const hasCompleteRead = input.read.kind === 'complete';
	const hasDemandedRead =
		hasDemandedContent || (hasCompleteRead && readIdentity === input.demandedIdentity);
	if (input.surface.kind === 'failed') {
		return {
			kind: 'failed',
			failure: input.surface.failure,
			retainsContent:
				input.surface.failure.scope === 'pane' ? hasContent || hasCompleteRead : hasDemandedRead,
		};
	}
	if (input.read.kind === 'noSource') return { kind: 'empty', reason: 'noSource' };
	if (input.demandedIdentity === null) return { kind: 'empty', reason: 'noSelection' };
	if (input.read.kind === 'failed')
		return { kind: 'failed', failure: input.read.failure, retainsContent: hasDemandedContent };
	if (!hasDemandedContent) {
		if (hasDemandedRead && input.surface.kind === 'updating')
			return { kind: 'updating', rest: input.surface.rest ?? null };
		return input.read.kind === 'complete' && readIdentity === input.demandedIdentity
			? { kind: 'empty', reason: 'certified' }
			: { kind: 'loading' };
	}
	return input.surface.kind === 'updating'
		? { kind: 'updating', rest: input.surface.rest ?? null }
		: { kind: 'content' };
}
