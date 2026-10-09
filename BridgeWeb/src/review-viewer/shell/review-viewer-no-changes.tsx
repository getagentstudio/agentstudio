import type { ReactElement } from 'react';

export function BridgeReviewEmptyCanvas(): ReactElement {
	return (
		<div
			className="flex h-full items-center justify-center px-8 text-center"
			data-testid="bridge-review-empty-canvas"
		>
			<p className="text-sm font-medium text-foreground">Nothing to review</p>
		</div>
	);
}

export function BridgeReviewEmptyFileTree(): ReactElement {
	return (
		<div
			className="flex h-full items-center justify-center px-4 text-center"
			data-testid="bridge-review-empty-file-tree"
		>
			<p className="text-xs text-muted-foreground">No changed files</p>
		</div>
	);
}
