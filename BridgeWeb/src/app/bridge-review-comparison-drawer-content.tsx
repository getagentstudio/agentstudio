import { X } from 'lucide-react';
import type { FormEvent, ReactElement, RefObject } from 'react';

import { Alert, AlertAction, AlertDescription, AlertTitle } from '../components/ui/alert.js';
import { Button } from '../components/ui/button.js';
import { Card, CardHeader, CardTitle, CardContent } from '../components/ui/card.js';
import { DrawerBody, DrawerClose, DrawerHeader, DrawerTitle } from '../components/ui/drawer.js';
import { Field, FieldTitle } from '../components/ui/field.js';
import { Input } from '../components/ui/input.js';
import { ToggleGroup, ToggleGroupItem } from '../components/ui/toggle-group.js';
import { Tooltip, TooltipContent, TooltipTrigger } from '../components/ui/tooltip.js';
import type { BridgeWorkerPanelChromePatchPayload } from '../core/comm-worker/bridge-worker-contracts.js';
import type { BridgeReviewComparisonTargetsQueryState } from './bridge-app-review-render-snapshot-controller.js';
import {
	BridgeReviewComparisonBranchSelector,
	type BridgeReviewComparisonBranchBasis,
} from './bridge-review-comparison-branch-selector.js';
import { BridgeReviewComparisonIcon } from './bridge-review-comparison-icon.js';
import {
	bridgeReviewComparisonTargetLabel,
	type BridgeReviewComparisonTarget,
} from './bridge-review-comparison-target.js';

type ContributionOrigin = Extract<
	NonNullable<
		import('../foundation/review-package/bridge-review-package.js').BridgeReviewPackage['comparisonOrigin']
	>,
	{ readonly kind: 'contribution' }
>;

export interface BridgeReviewComparisonDisplayedContribution {
	readonly heading: 'Current comparison' | 'Previous comparison';
	readonly origin: ContributionOrigin;
}

export interface BridgeReviewComparisonStatePresentation {
	readonly description: string | null;
	readonly heading: string;
	readonly kind: 'message';
}

export interface BridgeReviewComparisonDrawerContentProps {
	readonly activeTarget: BridgeReviewComparisonTarget | null;
	readonly branchSearchInputRef: RefObject<HTMLInputElement | null>;
	readonly commitInputRef: RefObject<HTMLInputElement | null>;
	readonly commitOID: string;
	readonly comparisonBasis: BridgeReviewComparisonBranchBasis;
	readonly descriptionId: string;
	readonly displayedContribution: BridgeReviewComparisonDisplayedContribution | null;
	readonly onApplyCommitOID: (event: FormEvent<HTMLFormElement>) => void;
	readonly onComparisonBasisChange: (basis: BridgeReviewComparisonBranchBasis) => void;
	readonly onQueryTargets: () => void;
	readonly onSelectTarget: (target: BridgeReviewComparisonTarget) => void;
	readonly onSelectionModeChange: (mode: 'branch' | 'commit') => void;
	readonly onCommitOIDChange: (commitOID: string) => void;
	readonly repositoryDefaultTarget: NonNullable<
		BridgeWorkerPanelChromePatchPayload['reviewComparison']
	>['repositoryDefaultTarget'];
	readonly selectionMode: 'branch' | 'commit';
	readonly statePresentation: BridgeReviewComparisonStatePresentation | null;
	readonly targetQueryState: BridgeReviewComparisonTargetsQueryState;
	readonly validationMessage: string | null;
}

export function BridgeReviewComparisonDrawerContent(
	props: BridgeReviewComparisonDrawerContentProps,
): ReactElement {
	const hasCurrentState = props.statePresentation !== null || props.displayedContribution !== null;
	return (
		<>
			<DrawerHeader>
				<div className="flex items-center justify-between gap-2">
					<DrawerTitle>Compare Worktree</DrawerTitle>
					<Tooltip>
						<DrawerClose
							render={
								<TooltipTrigger
									render={<Button size="icon-sm" variant="ghost" aria-label="Close Compare" />}
								/>
							}
						>
							<X aria-hidden="true" />
						</DrawerClose>
						<TooltipContent>Close Compare (Esc)</TooltipContent>
					</Tooltip>
				</div>
			</DrawerHeader>
			<DrawerBody className="flex flex-col">
				{hasCurrentState ? (
					<>
						<div className="mb-2 flex shrink-0 flex-col gap-2">
							{props.displayedContribution === null ? null : (
								<ComparisonCurrentState
									contribution={props.displayedContribution}
									repositoryDefaultTarget={props.repositoryDefaultTarget}
								/>
							)}
							{props.statePresentation === null ? null : (
								<ComparisonAttemptState presentation={props.statePresentation} />
							)}
						</div>
					</>
				) : null}
				<Card className="flex min-h-0 flex-1 flex-col">
					<CardContent className="flex min-h-0 flex-1 flex-col">
						<section
							className={`grid grid-cols-[max-content_minmax(0,1fr)] gap-y-2 ${props.selectionMode === 'branch' ? 'min-h-0 flex-1 grid-rows-[auto_minmax(0,1fr)]' : 'shrink-0'}`}
							data-testid="bridge-review-comparison-target-selection"
						>
							<Field
								className="col-span-2 grid grid-cols-subgrid items-center gap-x-3 px-1"
								orientation="horizontal"
							>
								<FieldTitle>
									<BridgeReviewComparisonIcon kind="target-kind" />
									<span>Compare with</span>
								</FieldTitle>
								<ToggleGroup
									aria-label="Comparison target kind"
									className="grid w-full grid-cols-2"
									role="group"
									size="sm"
									spacing={0}
									value={[props.selectionMode]}
									variant="outline"
								>
									<ToggleGroupItem
										className="w-full"
										onPressedChange={(pressed): void => {
											if (pressed) props.onSelectionModeChange('branch');
										}}
										value="branch"
									>
										Branch
									</ToggleGroupItem>
									<ToggleGroupItem
										className="w-full"
										onPressedChange={(pressed): void => {
											if (pressed) props.onSelectionModeChange('commit');
										}}
										value="commit"
									>
										Commit
									</ToggleGroupItem>
								</ToggleGroup>
							</Field>
							{props.selectionMode === 'branch' ? (
								<BridgeReviewComparisonBranchSelector
									activeTarget={props.activeTarget}
									comparisonBasis={props.comparisonBasis}
									onComparisonBasisChange={props.onComparisonBasisChange}
									onSelectTarget={props.onSelectTarget}
									searchInputRef={props.branchSearchInputRef}
									targetQueryState={props.targetQueryState}
									onRetry={props.onQueryTargets}
								/>
							) : (
								<form className="col-span-2 flex flex-col gap-2" onSubmit={props.onApplyCommitOID}>
									<div className="min-w-0">
										<label className="sr-only" htmlFor={`${props.descriptionId}-commit-input`}>
											Commit hash
										</label>
										<Input
											aria-invalid={props.validationMessage === null ? undefined : true}
											id={`${props.descriptionId}-commit-input`}
											onChange={(event): void => props.onCommitOIDChange(event.currentTarget.value)}
											placeholder="Enter a full commit hash…"
											ref={props.commitInputRef}
											value={props.commitOID}
										/>
										{props.validationMessage === null ? null : (
											<p className="mt-1 text-xs/relaxed text-destructive" role="alert">
												{props.validationMessage}
											</p>
										)}
									</div>
									<Button className="self-end" size="sm" type="submit" variant="secondary">
										Compare to this commit
									</Button>
								</form>
							)}
						</section>
					</CardContent>
				</Card>
			</DrawerBody>
		</>
	);
}

function ComparisonCurrentState(props: {
	readonly contribution: BridgeReviewComparisonDisplayedContribution;
	readonly repositoryDefaultTarget: BridgeReviewComparisonDrawerContentProps['repositoryDefaultTarget'];
}): ReactElement {
	const { origin } = props.contribution;
	const symbolicTarget = origin.symbolicTarget;
	const targetLabel = comparisonTargetLabel(symbolicTarget);
	if (symbolicTarget.kind === 'commit') {
		return (
			<Card
				data-resolved-target-oid={origin.resolvedTargetOID}
				data-testid="bridge-review-comparison-current-state"
			>
				<CardHeader>
					<CardTitle role="heading" aria-level={3}>
						{props.contribution.heading}
					</CardTitle>
				</CardHeader>
				<CardContent>
					<p className="flex min-w-0 items-center gap-1.5 text-sm text-foreground">
						<BridgeReviewComparisonIcon kind="effective-commit" />
						<span className="shrink-0">Commit:</span>
						<ComparisonRevision
							testId="bridge-review-comparison-effective-revision"
							value={origin.baseOID}
						/>
					</p>
				</CardContent>
			</Card>
		);
	}
	const isDefault = targetMatchesRepositoryDefault(symbolicTarget, props.repositoryDefaultTarget);
	const effectiveBasisLabel = origin.baseRole === 'commonCommit' ? 'Common commit' : 'Branch tip';
	return (
		<Card
			data-resolved-target-oid={origin.resolvedTargetOID}
			data-testid="bridge-review-comparison-current-state"
		>
			<CardHeader>
				<CardTitle role="heading" aria-level={3}>
					{props.contribution.heading}
				</CardTitle>
			</CardHeader>
			<CardContent>
				<div className="flex flex-col gap-1.5">
					<p
						className="flex min-w-0 items-center gap-1.5 text-sm text-foreground"
						data-testid="bridge-review-comparison-current-target"
					>
						<BridgeReviewComparisonIcon kind="current-branch" />
						<span className="truncate">{targetLabel}</span>
						{isDefault ? (
							<span className="flex shrink-0 items-baseline gap-1 text-xs/relaxed text-muted-foreground">
								<span aria-hidden="true">·</span>
								<span>Default</span>
							</span>
						) : null}
					</p>
					<div
						className="flex min-w-0 items-center gap-2 text-sm text-muted-foreground"
						data-testid="bridge-review-comparison-current-basis"
					>
						<BridgeReviewComparisonIcon kind="effective-commit" />
						<span
							className="flex min-w-0 items-baseline gap-1"
							data-testid="bridge-review-comparison-effective-basis"
						>
							<span>{effectiveBasisLabel} @</span>
							<ComparisonRevision
								testId="bridge-review-comparison-effective-revision"
								value={origin.baseOID}
							/>
						</span>
					</div>
				</div>
			</CardContent>
		</Card>
	);
}

function ComparisonAttemptState(props: {
	readonly presentation: BridgeReviewComparisonStatePresentation;
}): ReactElement {
	return (
		<ComparisonAttemptMessage
			description={props.presentation.description}
			heading={props.presentation.heading}
		/>
	);
}

function ComparisonAttemptMessage(props: {
	readonly children?: ReactElement;
	readonly description: string | null;
	readonly heading: string;
}): ReactElement {
	return (
		<Alert aria-live="polite" layout="inline" role="status">
			<AlertTitle>{props.heading}</AlertTitle>
			{props.description === null ? null : <AlertDescription>{props.description}</AlertDescription>}
			{props.children === undefined ? null : <AlertAction>{props.children}</AlertAction>}
		</Alert>
	);
}

function ComparisonRevision(props: {
	readonly testId: string;
	readonly value: string;
}): ReactElement {
	return (
		<code className="font-mono text-foreground" data-testid={props.testId} title={props.value}>
			<span aria-hidden="true">{props.value.slice(0, 12)}</span>
			<span className="sr-only">{props.value}</span>
		</code>
	);
}

function targetMatchesRepositoryDefault(
	target: BridgeReviewComparisonTarget,
	defaultTarget: BridgeReviewComparisonDrawerContentProps['repositoryDefaultTarget'],
): boolean {
	if (defaultTarget === null) return false;
	return (
		(target.kind === 'originDefaultBranch' &&
			target.remoteName === defaultTarget.remoteName &&
			target.branchName === defaultTarget.branchName) ||
		(target.kind === 'ref' &&
			target.name === `${defaultTarget.remoteName}/${defaultTarget.branchName}`)
	);
}

function comparisonTargetLabel(target: BridgeReviewComparisonTarget): string {
	return bridgeReviewComparisonTargetLabel(target);
}
