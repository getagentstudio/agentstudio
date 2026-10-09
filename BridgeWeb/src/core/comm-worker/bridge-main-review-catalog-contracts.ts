export interface BridgeMainReviewCatalogSnapshot {
	readonly changeCursor: number;
	readonly epoch: number | null;
	readonly itemOrderLength: number;
	readonly revision: number;
	readonly treeRowOrderLength: number;
}

export type BridgeMainReviewCatalogOrderMutation =
	| {
			readonly kind: 'replace';
			readonly length: number;
	  }
	| {
			readonly kind: 'setRange';
			readonly length: number;
			readonly startIndex: number;
	  }
	| {
			readonly deleteCount: number;
			readonly insertCount: number;
			readonly kind: 'splice';
			readonly startIndex: number;
	  };

export interface BridgeMainReviewCatalogChange {
	readonly cursor: number;
	readonly itemIds: readonly string[];
	readonly itemOrderMutations: readonly BridgeMainReviewCatalogOrderMutation[];
	readonly reset: boolean;
	readonly treeRowIds: readonly string[];
	readonly treeRowOrderMutations: readonly BridgeMainReviewCatalogOrderMutation[];
}

export interface BridgeMainReviewCatalogChangeRead {
	readonly changes: readonly BridgeMainReviewCatalogChange[];
	readonly resetRequired: boolean;
}
