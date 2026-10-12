import type {
	BridgeViewerProductOnlyContractViolation,
	BridgeViewerReviewFreshRouteProof,
	BridgeViewerReviewHydrationMilestone,
	BridgeViewerReviewTreeSelectionProof,
} from './product-only-real-router-contract.ts';

export function requireReviewTreeSelection(props: {
	readonly proof: BridgeViewerReviewTreeSelectionProof;
	readonly violations: BridgeViewerProductOnlyContractViolation[];
}): void {
	if (
		props.proof.codeViewManifestItemCountAfterSelection !==
		props.proof.codeViewManifestItemCountBeforeSelection
	) {
		props.violations.push({
			actual: props.proof,
			code: 'REVIEW_TREE_SELECTION_MANIFEST_CHANGED',
			expected: 'tree selection hydrates one existing CodeView item without changing manifest size',
		});
	}
	if (props.proof.mountedHeaderOrderViolation !== null) {
		props.violations.push({
			actual: props.proof.mountedHeaderOrderViolation,
			code: 'REVIEW_TREE_SELECTION_LOGICAL_ORDER_MISMATCH',
			expected: "tree-selected hydration remains at the item's authoritative catalog position",
		});
	}
	if (
		props.proof.targetItemId === props.proof.selectedItemIdAtStart ||
		props.proof.selectedItemIdAtCompletion !== props.proof.targetItemId ||
		(props.proof.selectedContentState !== 'hydrated' &&
			props.proof.selectedContentState !== 'windowed')
	) {
		props.violations.push({
			actual: props.proof,
			code: 'REVIEW_TREE_SELECTION_CONTENT_MISSING',
			expected:
				'a distinct tree target becomes selected and hydrates as an existing continuous CodeView item',
		});
	}
}

export function requireFreshReviewRoute(props: {
	readonly proof: BridgeViewerReviewFreshRouteProof;
	readonly violations: BridgeViewerProductOnlyContractViolation[];
}): void {
	const manifestMatches =
		props.proof.metadataItemCount === props.proof.expectedItemIds.length &&
		props.proof.codeViewManifestItemCount === props.proof.expectedItemIds.length &&
		stringArraysContainSameValues(props.proof.observedHeaderItemIds, props.proof.expectedItemIds);
	if (!manifestMatches) {
		props.violations.push({
			actual: {
				codeViewManifestItemCount: props.proof.codeViewManifestItemCount,
				expectedItemCount: props.proof.expectedItemIds.length,
				metadataItemCount: props.proof.metadataItemCount,
				observedHeaderItemCount: props.proof.observedHeaderItemIds.length,
				observedHeaderItemIds: props.proof.observedHeaderItemIds,
			},
			code: 'REVIEW_FRESH_ROUTE_MANIFEST_MISSING',
			expected:
				'fresh targetless Review traverses every expected Pierre header exactly once in catalog order before tree interaction',
		});
	}
	if (props.proof.mountedHeaderOrderViolations.length > 0) {
		props.violations.push({
			actual: props.proof.mountedHeaderOrderViolations,
			code: 'REVIEW_FRESH_ROUTE_LOGICAL_ORDER_MISMATCH',
			expected:
				'every viewport-intersecting Pierre CodeView header preserves the authoritative catalog order',
		});
	}
	const mixedInitialDisclosure = props.proof.initialDirectoryDisclosure.filter(
		(disclosure): boolean => disclosure.expanded !== 'true',
	);
	if (
		props.proof.initialDirectoryDisclosure.length === 0 ||
		mixedInitialDisclosure.length > 0 ||
		JSON.stringify(props.proof.finalDirectoryDisclosure) !==
			JSON.stringify(props.proof.initialDirectoryDisclosure)
	) {
		props.violations.push({
			actual: {
				finalDirectoryDisclosure: props.proof.finalDirectoryDisclosure,
				initialDirectoryDisclosure: props.proof.initialDirectoryDisclosure,
				mixedInitialDisclosure,
			},
			code: 'REVIEW_FRESH_ROUTE_DISCLOSURE_MIXED',
			expected:
				'all mounted fresh-route directories start expanded and CodeView-only scrolling leaves disclosure unchanged',
		});
	}
	const failedHydrationMilestones = props.proof.hydrationMilestones.filter(
		(milestone): boolean =>
			milestone.visibleNonSelectedItemIds.length > 0 &&
			!stringArraysEqual(milestone.readableNonSelectedItemIds, milestone.visibleNonSelectedItemIds),
	);
	const requiredMilestoneLabels: readonly BridgeViewerReviewHydrationMilestone['label'][] = [
		'initial',
		'quarter',
		'middle',
		'threeQuarter',
		'final',
	];
	if (
		failedHydrationMilestones.length > 0 ||
		!requiredMilestoneLabels.every((label): boolean =>
			props.proof.hydrationMilestones.some((milestone): boolean => milestone.label === label),
		)
	) {
		props.violations.push({
			actual: {
				failedHydrationMilestones,
				hydrationMilestones: props.proof.hydrationMilestones,
			},
			code: 'REVIEW_FRESH_ROUTE_VISIBLE_READABLE_MISSING',
			expected:
				'non-selected visible Review items are readable in every settled sampled CodeView window without tree clicks',
		});
	}
	const expectedHydratedNonSelectedItemIds = props.proof.expectedItemIds.filter(
		(itemId): boolean => itemId !== props.proof.selectedItemIdAtStart,
	);
	const paintLedgerByItemId = new Map(
		props.proof.paintLedger.map((entry) => [entry.itemId, entry]),
	);
	const missingPaintedItemIds = expectedHydratedNonSelectedItemIds.filter(
		(itemId): boolean => paintLedgerByItemId.get(itemId)?.status !== 'painted',
	);
	const unexpectedPaintedItemIds = props.proof.paintLedger
		.filter((entry) => entry.status === 'painted')
		.map((entry) => entry.itemId)
		.filter((itemId) => !expectedHydratedNonSelectedItemIds.includes(itemId));
	if (missingPaintedItemIds.length > 0 || unexpectedPaintedItemIds.length > 0) {
		props.violations.push({
			actual: {
				expectedPaintedNonSelectedItemCount: expectedHydratedNonSelectedItemIds.length,
				missingPaintedItemCount: missingPaintedItemIds.length,
				missingPaintedItemIds: missingPaintedItemIds.slice(0, 32),
				paintLedger: props.proof.paintLedger,
				unexpectedPaintedItemCount: unexpectedPaintedItemIds.length,
				unexpectedPaintedItemIds: unexpectedPaintedItemIds.slice(0, 32),
			},
			code: 'REVIEW_FRESH_ROUTE_VISIBLE_PAINT_COVERAGE_MISSING',
			expected:
				'every expected non-selected Review item reaches painted publication/source-correlation evidence during a settled CodeView traversal without tree clicks',
		});
	}
	if (
		!props.proof.codeScrollOwnerIdentityStable ||
		!props.proof.treeHostIdentityStable ||
		!props.proof.treeShadowRootIdentityStable
	) {
		props.violations.push({
			actual: {
				codeScrollOwnerIdentityStable: props.proof.codeScrollOwnerIdentityStable,
				treeHostIdentityStable: props.proof.treeHostIdentityStable,
				treeShadowRootIdentityStable: props.proof.treeShadowRootIdentityStable,
			},
			code: 'REVIEW_FRESH_ROUTE_IDENTITY_REPLACED',
			expected: 'CodeView scroll owner, tree host, and tree shadow root retain identity',
		});
	}
	if (
		props.proof.selectedItemIdAtStart === null ||
		props.proof.selectedItemIdAtCompletion !== props.proof.selectedItemIdAtStart
	) {
		props.violations.push({
			actual: {
				selectedItemIdAtCompletion: props.proof.selectedItemIdAtCompletion,
				selectedItemIdAtStart: props.proof.selectedItemIdAtStart,
			},
			code: 'REVIEW_FRESH_ROUTE_SELECTION_CHANGED',
			expected: 'CodeView-only scrolling leaves fresh-route Review selection unchanged',
		});
	}
	const maximumScrollTop = Math.max(
		0,
		props.proof.completedScroll.scrollHeight - props.proof.completedScroll.clientHeight,
	);
	if (maximumScrollTop <= 0 || props.proof.completedScroll.scrollTop < maximumScrollTop - 1) {
		props.violations.push({
			actual: props.proof.completedScroll,
			code: 'REVIEW_FRESH_ROUTE_TRAVERSAL_INCOMPLETE',
			expected: 'fresh-route Review traversal settles at the current CodeView bottom',
		});
	}
	const backwardTraversal = props.proof.backwardTraversal;
	if (
		backwardTraversal.completedScrollTop > 1 ||
		backwardTraversal.hydrationCoverage.settledWindowCount === 0 ||
		backwardTraversal.mountedHeaderOrderViolations.length > 0 ||
		backwardTraversal.selectedItemIdAtCompletion !== props.proof.selectedItemIdAtStart
	) {
		props.violations.push({
			actual: backwardTraversal,
			code: 'REVIEW_FRESH_ROUTE_BACKWARD_READABLE_INVALID',
			expected:
				'reverse CodeView scrolling traverses bottom-to-top through ordered readable windows with painted coverage and stable selection',
		});
	}
}

function stringArraysEqual(left: readonly string[], right: readonly string[]): boolean {
	return (
		left.length === right.length && left.every((value, index): boolean => value === right[index])
	);
}

function stringArraysContainSameValues(left: readonly string[], right: readonly string[]): boolean {
	if (left.length !== right.length) return false;
	const leftValues = new Set(left);
	const rightValues = new Set(right);
	return (
		leftValues.size === left.length &&
		rightValues.size === right.length &&
		leftValues.size === rightValues.size &&
		[...leftValues].every((value): boolean => rightValues.has(value))
	);
}
