import { LoaderCircleIcon } from 'lucide-react';
import {
	useEffect,
	useId,
	useLayoutEffect,
	useRef,
	useState,
	type FormEvent,
	type ReactElement,
} from 'react';

import { Button, buttonVariants } from '../components/ui/button.js';
import { Drawer, DrawerTrigger } from '../components/ui/drawer.js';
import type { BridgeMainPanelChromeSlice } from '../core/comm-worker/bridge-main-review-comparison-presentation.js';
import type { BridgeWorkerReviewComparisonUpdateCommand } from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeReviewPackage } from '../foundation/review-package/bridge-review-package.js';
import type { BridgeReviewComparisonTargetsQueryState } from './bridge-app-review-render-snapshot-controller.js';
import type { BridgeRegionSurfaceStatus } from './bridge-region-presentation-state.js';
import type { BridgeReviewComparisonBranchBasis } from './bridge-review-comparison-branch-selector.js';
import {
	BridgeReviewComparisonDrawerContent,
	type BridgeReviewComparisonDisplayedContribution,
	type BridgeReviewComparisonStatePresentation,
} from './bridge-review-comparison-drawer-content.js';
import { BridgeReviewComparisonIcon } from './bridge-review-comparison-icon.js';
import {
	bridgeReviewComparisonTargetLabel,
	type BridgeReviewComparisonTarget,
} from './bridge-review-comparison-target.js';
import { bridgeReviewRegionDisplaySpec } from './bridge-review-region-display-spec.js';
import { BridgeViewerContextPanel } from './bridge-viewer-context-panel.js';

export interface BridgeReviewComparisonFinalFocusContext {
	readonly closeReason: string | null;
	readonly trigger: HTMLButtonElement | null;
}

export interface BridgeReviewComparisonControlProps {
	readonly regionSurfaceStatus?: BridgeRegionSurfaceStatus;
	readonly comparisonPresentation: BridgeMainPanelChromeSlice['reviewComparison'];
	readonly displayedReviewPackage: BridgeReviewPackage | null;
	readonly disabled?: boolean;
	readonly isActive?: boolean;
	readonly finalFocus: (
		context: BridgeReviewComparisonFinalFocusContext,
	) => false | HTMLElement | null;
	readonly onOpenChange: (open: boolean) => boolean;
	readonly open: boolean;
	readonly onApplyTarget: (target: BridgeWorkerReviewComparisonUpdateCommand['target']) => void;
	readonly onCancelTargetQuery?: () => void;
	readonly onQueryTargets?: () => void;
	readonly targetQueryState?: BridgeReviewComparisonTargetsQueryState;
}

export function BridgeReviewComparisonControl(
	props: BridgeReviewComparisonControlProps,
): ReactElement | null {
	const descriptionId = useId();
	const isActive = props.isActive ?? true;
	const disabled = props.disabled ?? false;
	const [commitOID, setCommitOID] = useState('');
	const [comparisonBasis, setComparisonBasis] =
		useState<BridgeReviewComparisonBranchBasis>('commonCommit');
	const [locallyPendingComparison, setLocallyPendingComparison] =
		useState<LocallyPendingComparison | null>(null);
	const [selectionMode, setSelectionMode] = useState<'branch' | 'commit'>('branch');
	const [validationMessage, setValidationMessage] = useState<string | null>(null);
	const targetQueryState =
		props.targetQueryState ?? ({ catalog: null, message: null, status: 'idle' } as const);
	const onQueryTargets = props.onQueryTargets ?? ignoreTargetQuery;
	const onCancelTargetQuery = props.onCancelTargetQuery;
	const onOpenChange = props.onOpenChange;
	const branchSearchInputRef = useRef<HTMLInputElement>(null);
	const commitInputRef = useRef<HTMLInputElement>(null);
	const triggerRef = useRef<HTMLButtonElement>(null);
	const lastCloseReasonRef = useRef<string | null>(null);
	const previousOpenRef = useRef(false);
	const cancelTargetQueryAndClose = (): void => {
		lastCloseReasonRef.current = 'imperative-action';
		props.onOpenChange(false);
	};
	const applyComparisonTarget = (
		target: BridgeWorkerReviewComparisonUpdateCommand['target'],
	): void => {
		setLocallyPendingComparison({
			presentationAtRequest: props.comparisonPresentation,
			target,
		});
		try {
			props.onApplyTarget(target);
		} catch (error) {
			setLocallyPendingComparison(null);
			throw error;
		}
	};
	useEffect((): void => {
		if (!isActive && props.open) {
			lastCloseReasonRef.current = 'inactive';
			onOpenChange(false);
		}
	}, [isActive, onOpenChange, props.open]);
	useLayoutEffect((): void => {
		if (!props.open) return;
		const activeInput =
			selectionMode === 'branch' ? branchSearchInputRef.current : commitInputRef.current;
		activeInput?.focus();
	}, [props.open, selectionMode]);
	useEffect((): void => {
		const wasOpen = previousOpenRef.current;
		previousOpenRef.current = props.open;
		if (wasOpen === props.open) return;
		if (props.open) {
			setCommitOID('');
			setValidationMessage(null);
			onQueryTargets();
		} else {
			onCancelTargetQuery?.();
		}
	}, [onCancelTargetQuery, onQueryTargets, props.open]);
	useEffect((): void => {
		if (locallyPendingComparison === null) return;
		const nativePresentation = props.comparisonPresentation;
		if (nativePresentation === locallyPendingComparison.presentationAtRequest) return;
		if (
			nativePresentation?.activeTarget !== null &&
			nativePresentation?.activeTarget !== undefined &&
			comparisonTargetsEqual(nativePresentation.activeTarget, locallyPendingComparison.target)
		) {
			setLocallyPendingComparison(null);
		}
	}, [locallyPendingComparison, props.comparisonPresentation]);
	const locallyPendingTarget = locallyPendingComparison?.target ?? null;
	const isLocallyPending = locallyPendingTarget !== null;
	const isUpdating = disabled || isLocallyPending;
	const label =
		locallyPendingTarget === null
			? closedComparisonLabel(props)
			: `Compare to: ${comparisonTargetLabel(locallyPendingTarget)} · Updating`;
	const isHeld =
		props.regionSurfaceStatus?.kind === 'updating' &&
		props.regionSurfaceStatus.rest === 'held' &&
		!isLocallyPending;
	const presentsUpdatingChrome = !isHeld && (isUpdating || label.endsWith(' · Updating'));
	const visibleLabel = presentsUpdatingChrome
		? installedComparisonVisibleLabel(props)
		: closedComparisonVisibleLabel(props);
	const narrowComparisonLabel = narrowComparisonLabelForPackage(props.displayedReviewPackage);
	const activeTarget = props.comparisonPresentation?.activeTarget ?? null;
	const displayedContribution = displayedContributionForComparison(props);
	const describedTarget =
		displayedContribution?.heading === 'Previous comparison'
			? displayedContribution.origin.symbolicTarget
			: activeTarget;
	const describedTargetLabel =
		describedTarget === null ? '' : comparisonTargetLabel(describedTarget);
	const statePresentation = comparisonStatePresentation(props, displayedContribution);
	const sharedHistoryDescription =
		narrowComparisonLabel !== null
			? narrowComparisonDescription(narrowComparisonLabel)
			: describedTarget === null
				? 'Choose a local branch, remote-tracking branch, or Git reference for this review.'
				: comparisonTargetDescription(describedTarget, describedTargetLabel);
	const applyCommitOID = (event: FormEvent<HTMLFormElement>): void => {
		event.preventDefault();
		const normalizedOID = commitOID.trim();
		if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/iu.test(normalizedOID)) {
			setValidationMessage('Enter a full 40- or 64-character hexadecimal commit hash.');
			return;
		}
		applyComparisonTarget({ kind: 'commit', oid: normalizedOID });
		setValidationMessage(null);
		cancelTargetQueryAndClose();
	};
	if (!isActive) {
		return null;
	}
	if (narrowComparisonLabel !== null) {
		return (
			<span
				aria-describedby={descriptionId}
				className={buttonVariants({ size: 'sm', variant: 'outline' })}
				data-testid="bridge-review-comparison-trigger"
			>
				<span>{visibleLabel}</span>
				<span className="sr-only" id={descriptionId}>
					{sharedHistoryDescription}
				</span>
			</span>
		);
	}
	return (
		<Drawer
			modal={false}
			onOpenChange={(nextOpen, eventDetails): void => {
				if (!nextOpen) lastCloseReasonRef.current = eventDetails.reason;
				if (!props.onOpenChange(nextOpen)) eventDetails.cancel();
			}}
			open={props.open}
			swipeDirection="right"
		>
			<DrawerTrigger
				aria-busy={presentsUpdatingChrome || undefined}
				aria-describedby={descriptionId}
				aria-label={label}
				render={<Button size="sm" variant="outline" />}
				data-testid="bridge-review-comparison-trigger"
				disabled={isUpdating}
				ref={triggerRef}
				title={label}
			>
				{presentsUpdatingChrome ? (
					<LoaderCircleIcon
						aria-hidden="true"
						data-busy="true"
						data-testid="bridge-review-comparison-pending-icon"
					/>
				) : (
					<BridgeReviewComparisonIcon kind="trigger" />
				)}
				<span>{visibleLabel}</span>
			</DrawerTrigger>
			<span className="sr-only" id={descriptionId}>
				{sharedHistoryDescription}
			</span>
			<BridgeViewerContextPanel
				ariaLabel="Compare Worktree"
				finalFocus={(): false | HTMLElement | null =>
					props.finalFocus({
						closeReason: lastCloseReasonRef.current,
						trigger: triggerRef.current,
					})
				}
				height="full"
				inert={!props.open}
				initialFocus={(): HTMLElement | null =>
					selectionMode === 'branch' ? branchSearchInputRef.current : commitInputRef.current
				}
				testId="bridge-review-comparison-content"
			>
				<BridgeReviewComparisonDrawerContent
					activeTarget={activeTarget}
					branchSearchInputRef={branchSearchInputRef}
					commitInputRef={commitInputRef}
					commitOID={commitOID}
					comparisonBasis={comparisonBasis}
					descriptionId={descriptionId}
					displayedContribution={displayedContribution}
					onApplyCommitOID={applyCommitOID}
					onCommitOIDChange={setCommitOID}
					onComparisonBasisChange={setComparisonBasis}
					onQueryTargets={onQueryTargets}
					onSelectTarget={(target): void => {
						applyComparisonTarget(target);
						cancelTargetQueryAndClose();
					}}
					onSelectionModeChange={(mode): void => {
						setSelectionMode(mode);
						setValidationMessage(null);
					}}
					repositoryDefaultTarget={props.comparisonPresentation?.repositoryDefaultTarget ?? null}
					selectionMode={selectionMode}
					statePresentation={statePresentation}
					targetQueryState={targetQueryState}
					validationMessage={validationMessage}
				/>
			</BridgeViewerContextPanel>
		</Drawer>
	);
}

function ignoreTargetQuery(): void {}

function displayedContributionForComparison(
	props: BridgeReviewComparisonControlProps,
): DisplayedContribution | null {
	const reviewPackage = displayedReviewPackageForComparison(props);
	if (reviewPackage?.comparisonOrigin?.kind !== 'contribution') {
		return null;
	}
	return {
		heading:
			props.comparisonPresentation?.displayedSnapshot.status === 'stale' ||
			isDisplayedPackageAwaitingPresentationDelivery(props)
				? 'Previous comparison'
				: 'Current comparison',
		origin: reviewPackage.comparisonOrigin,
	};
}

function displayedReviewPackageForComparison(
	props: BridgeReviewComparisonControlProps,
): BridgeReviewPackage | null {
	const reviewPackage = props.displayedReviewPackage;
	const displayedSnapshot = props.comparisonPresentation?.displayedSnapshot;
	if (
		reviewPackage === null ||
		displayedSnapshot === undefined ||
		displayedSnapshot.status === 'none'
	) {
		return null;
	}
	return reviewPackage;
}

function isDisplayedPackageAwaitingPresentationDelivery(
	props: BridgeReviewComparisonControlProps,
): boolean {
	const reviewPackage = props.displayedReviewPackage;
	const displayedSnapshot = props.comparisonPresentation?.displayedSnapshot;
	return (
		reviewPackage !== null &&
		displayedSnapshot !== undefined &&
		displayedSnapshot.status !== 'none' &&
		(displayedSnapshot.packageId !== reviewPackage.packageId ||
			displayedSnapshot.reviewGeneration !== reviewPackage.reviewGeneration ||
			displayedSnapshot.revision !== reviewPackage.revision)
	);
}

type ReviewComparisonTarget = BridgeReviewComparisonTarget;

interface LocallyPendingComparison {
	readonly presentationAtRequest: BridgeReviewComparisonControlProps['comparisonPresentation'];
	readonly target: ReviewComparisonTarget;
}

type DisplayedContribution = BridgeReviewComparisonDisplayedContribution;
type ComparisonStatePresentation = BridgeReviewComparisonStatePresentation;

function comparisonStatePresentation(
	props: BridgeReviewComparisonControlProps,
	displayedContribution: DisplayedContribution | null,
): ComparisonStatePresentation | null {
	const comparisonPresentation = props.comparisonPresentation;
	if (comparisonPresentation === null || comparisonPresentation === undefined) {
		return null;
	}
	switch (comparisonPresentation.attempt.status) {
		case 'selectionRequired':
			return {
				description: 'Select a branch or Git reference before reviewing changes.',
				heading: 'Choose a comparison target',
				kind: 'message',
			};
		case 'pending':
			return displayedContribution?.heading === 'Previous comparison'
				? null
				: {
						description: 'No comparison is displayed yet.',
						heading: 'Preparing comparison',
						kind: 'message',
					};
		case 'settled':
			return null;
		case 'unavailable':
			return null;
	}
	return unreachableComparisonValue(comparisonPresentation.attempt);
}

function closedComparisonLabel(props: BridgeReviewComparisonControlProps): string {
	const narrowComparisonLabel = narrowComparisonLabelForPackage(props.displayedReviewPackage);
	if (narrowComparisonLabel !== null) {
		return narrowComparisonLabel;
	}
	const displayedContribution = displayedContributionForComparison(props);
	if (
		props.regionSurfaceStatus?.kind === 'updating' &&
		props.regionSurfaceStatus.rest === 'held' &&
		displayedContribution !== null
	) {
		return `Compare to: ${comparisonTargetLabel(displayedContribution.origin.symbolicTarget)}`;
	}
	if (displayedContribution?.heading === 'Previous comparison') {
		const displayedTargetLabel = comparisonTargetLabel(displayedContribution.origin.symbolicTarget);
		const attemptStatus = props.comparisonPresentation?.attempt.status;
		const requestedTarget = props.comparisonPresentation?.activeTarget;
		const requestedTargetLabel =
			requestedTarget === undefined || requestedTarget === null
				? displayedTargetLabel
				: comparisonTargetLabel(requestedTarget);
		return attemptStatus === 'pending' ||
			(attemptStatus === 'settled' && isDisplayedPackageAwaitingPresentationDelivery(props))
			? `Compare to: ${requestedTargetLabel} · Updating`
			: `Compare to: ${displayedTargetLabel} · ${bridgeReviewRegionDisplaySpec.staleComparison}`;
	}
	const activeTarget = props.comparisonPresentation?.activeTarget;
	if (activeTarget === undefined || activeTarget === null) {
		return 'Choose target';
	}
	return `Compare to: ${comparisonTargetLabel(activeTarget)}`;
}

function closedComparisonVisibleLabel(props: BridgeReviewComparisonControlProps): string {
	const accessibleLabel = closedComparisonLabel(props);
	return accessibleLabel.startsWith('Compare to: ')
		? accessibleLabel.slice('Compare to: '.length)
		: accessibleLabel;
}

function installedComparisonVisibleLabel(props: BridgeReviewComparisonControlProps): string {
	const displayedContribution = displayedContributionForComparison(props);
	if (displayedContribution !== null) {
		return comparisonTargetLabel(displayedContribution.origin.symbolicTarget);
	}
	return closedComparisonVisibleLabel(props).replace(/ · Updating$/u, '');
}

function narrowComparisonLabelForPackage(
	reviewPackage: BridgeReviewPackage | null,
): 'Staged only' | 'Unstaged only' | null {
	if (
		reviewPackage?.query.comparisonSemantics === 'indexDelta' &&
		reviewPackage.headEndpoint.kind === 'index'
	) {
		return 'Staged only';
	}
	if (
		reviewPackage?.query.comparisonSemantics === 'workingTreeDelta' &&
		reviewPackage.baseEndpoint.kind === 'index' &&
		reviewPackage.headEndpoint.kind === 'workingTree'
	) {
		return 'Unstaged only';
	}
	return null;
}

function narrowComparisonDescription(
	narrowComparisonLabel: 'Staged only' | 'Unstaged only',
): string {
	return narrowComparisonLabel === 'Staged only'
		? 'Shows changes added to the staging area.'
		: 'Shows tracked working tree changes that have not been staged.';
}

function comparisonTargetDescription(target: ReviewComparisonTarget, targetLabel: string): string {
	if (target.kind === 'commit') {
		return `Shows committed and uncommitted changes directly from commit ${targetLabel}.`;
	}
	return target.basis === 'branchTip'
		? `Shows committed and uncommitted changes directly from the latest locally available ${targetLabel} revision.`
		: `Shows committed and uncommitted changes since this worktree's latest shared commit with ${targetLabel}. Changes only on ${targetLabel} are excluded.`;
}

function comparisonTargetLabel(target: ReviewComparisonTarget): string {
	return bridgeReviewComparisonTargetLabel(target);
}

function comparisonTargetsEqual(
	left: ReviewComparisonTarget,
	right: ReviewComparisonTarget,
): boolean {
	if (left.kind !== right.kind) return false;
	switch (left.kind) {
		case 'localDefaultBranch':
			return (
				right.kind === 'localDefaultBranch' &&
				left.basis === right.basis &&
				left.branchName === right.branchName
			);
		case 'originDefaultBranch':
			return (
				right.kind === 'originDefaultBranch' &&
				left.basis === right.basis &&
				left.branchName === right.branchName &&
				left.remoteName === right.remoteName
			);
		case 'branch':
			return right.kind === 'branch' && left.basis === right.basis && left.name === right.name;
		case 'commit':
			return right.kind === 'commit' && left.oid === right.oid;
		case 'ref':
			return right.kind === 'ref' && left.basis === right.basis && left.name === right.name;
		default:
			return unreachableComparisonValue(left);
	}
}

function unreachableComparisonValue(value: never): never {
	throw new Error(`Unexpected Review comparison value: ${JSON.stringify(value)}`);
}
