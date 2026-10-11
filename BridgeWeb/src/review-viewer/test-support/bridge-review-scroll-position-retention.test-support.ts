interface ReviewViewportAnchor {
	readonly itemId: string;
	readonly viewportOffsetPixels: number;
}

export interface ReviewScrollPositionRetentionInput {
	readonly maximumScrollTopAfterReplacement: number;
	readonly rawScrollTopAfterReplacement: number;
	readonly rawScrollTopBeforeReplacement: number;
	readonly semanticAnchorAfterReplacement: ReviewViewportAnchor;
	readonly semanticAnchorBeforeReplacement: ReviewViewportAnchor;
}

export interface ReviewScrollPositionRetentionDiagnostic {
	readonly rawScrollCoordinateRetained: boolean;
	readonly scrollClampedToNewMaximum: boolean;
	readonly scrollPositionRetained: boolean;
	readonly semanticViewportAnchorRetained: boolean;
}

export function evaluateReviewScrollPositionRetention(
	props: ReviewScrollPositionRetentionInput,
): ReviewScrollPositionRetentionDiagnostic {
	const rawScrollCoordinateRetained =
		Math.abs(props.rawScrollTopAfterReplacement - props.rawScrollTopBeforeReplacement) <= 1;
	const semanticViewportAnchorRetained =
		props.semanticAnchorAfterReplacement.itemId === props.semanticAnchorBeforeReplacement.itemId &&
		Math.abs(
			props.semanticAnchorAfterReplacement.viewportOffsetPixels -
				props.semanticAnchorBeforeReplacement.viewportOffsetPixels,
		) <= 1;
	const scrollClampedToNewMaximum =
		props.rawScrollTopBeforeReplacement > props.maximumScrollTopAfterReplacement &&
		Math.abs(props.rawScrollTopAfterReplacement - props.maximumScrollTopAfterReplacement) <= 1;

	return {
		rawScrollCoordinateRetained,
		scrollClampedToNewMaximum,
		scrollPositionRetained:
			props.rawScrollTopAfterReplacement > 0 &&
			(rawScrollCoordinateRetained || semanticViewportAnchorRetained || scrollClampedToNewMaximum),
		semanticViewportAnchorRetained,
	};
}
