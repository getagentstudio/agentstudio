import { List, ListFilter, MessagesSquareIcon, X } from 'lucide-react';
import type { MouseEvent, ReactElement, ReactNode, Ref } from 'react';

import { Alert, AlertDescription } from '@/components/ui/alert.js';
import { Button } from '@/components/ui/button.js';
import {
	DrawerBody,
	DrawerFooter,
	DrawerHeader,
	DrawerTitle,
	DrawerTrigger,
} from '@/components/ui/drawer.js';
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu.js';
import { Field } from '@/components/ui/field.js';
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group.js';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip.js';

import { BridgeViewerButton, BridgeViewerIcon } from '../app/bridge-viewer-button.js';
import { worktreeAnnotationActionSpec } from './worktree-annotation-action-spec.js';
export type WorktreeAnnotationShareScope = 'pending' | 'all';
export type WorktreeAnnotationShareMembership =
	| { readonly kind: 'unknown' }
	| { readonly allCount: number; readonly kind: 'ready'; readonly pendingCount: number };

export function WorktreeAnnotationShareTrigger(props: {
	readonly buttonRef: Ref<HTMLButtonElement>;
	readonly disabled: boolean;
	readonly open: boolean;
}): ReactElement {
	return (
		<Tooltip>
			<DrawerTrigger
				render={
					<TooltipTrigger
						render={
							<BridgeViewerButton
								ariaLabel="Annotations"
								ariaPressed={props.open}
								buttonRef={props.buttonRef}
								size="sm"
								variant="outline"
								data-tooltip="Annotations"
								disabled={props.disabled}
							/>
						}
					/>
				}
			>
				<BridgeViewerIcon>
					<MessagesSquareIcon aria-hidden="true" />
				</BridgeViewerIcon>
				<span>Annotations</span>
			</DrawerTrigger>
			<TooltipContent side="bottom">View and share annotations</TooltipContent>
		</Tooltip>
	);
}

export function WorktreeAnnotationShareModeRow(props: {
	readonly regionIndicator?: ReactNode;
	readonly children?: ReactNode | undefined;
	readonly error: string | null;
	readonly errorCanChooseFolder?: boolean | undefined;
	readonly history: ReactNode;
	readonly isOutputPending: boolean;
	readonly isOutputReady?: boolean | undefined;
	readonly membership: WorktreeAnnotationShareMembership;
	readonly onCopy: (scope: WorktreeAnnotationShareScope) => void;
	readonly onDone: () => void;
	readonly onExport: (scope: WorktreeAnnotationShareScope) => void;
	readonly onExportTo?: ((scope: WorktreeAnnotationShareScope) => void) | undefined;
	readonly onChangeFolder?: (() => void) | undefined;
	readonly onReveal?: (() => void) | undefined;
	readonly savedFilename?: string | null | undefined;
	readonly onScopeChange: (scope: WorktreeAnnotationShareScope) => void;
	readonly scope: WorktreeAnnotationShareScope;
}): ReactElement {
	const displayedCount =
		props.membership.kind === 'unknown'
			? null
			: props.scope === 'pending'
				? props.membership.pendingCount
				: props.membership.allCount;
	const outputDisabled =
		displayedCount === null ||
		displayedCount === 0 ||
		props.isOutputPending ||
		props.isOutputReady === false;
	const pendingCountLabel =
		props.membership.kind === 'unknown' ? 'unknown' : String(props.membership.pendingCount);
	const allCountLabel =
		props.membership.kind === 'unknown' ? 'unknown' : String(props.membership.allCount);
	const copySpec = worktreeAnnotationActionSpec('copyAnnotations');
	const exportSpec = worktreeAnnotationActionSpec('exportJSON');
	const exportToSpec = worktreeAnnotationActionSpec('exportJSONToFolder');
	const changeFolderSpec = worktreeAnnotationActionSpec('changeExportFolder');
	const chooseFolderSpec = worktreeAnnotationActionSpec('chooseExportFolder');
	const revealSpec = worktreeAnnotationActionSpec('revealExport');
	const optionsSpec = worktreeAnnotationActionSpec('exportOptions');
	const CopyIcon = copySpec.icon;
	const ExportIcon = exportSpec.icon;
	const ExportToIcon = exportToSpec.icon;
	const ChangeFolderIcon = changeFolderSpec.icon;
	const ChooseFolderIcon = chooseFolderSpec.icon;
	const RevealIcon = revealSpec.icon;
	const OptionsIcon = optionsSpec.icon;
	return (
		<section
			aria-label="Annotations"
			className="flex h-full min-h-0 flex-col"
			data-testid="worktree-annotation-share-mode"
		>
			<DrawerHeader>
				<div className="flex items-center justify-between gap-2">
					<DrawerTitle>Annotations</DrawerTitle>
					{props.regionIndicator}
					<WorktreeAnnotationShareActionButton
						ariaLabel="Close Annotations"
						size="icon-sm"
						disabled={props.isOutputPending}
						onClick={props.onDone}
						tooltip="Close Annotations (Esc)"
					>
						<BridgeViewerIcon>
							<X aria-hidden="true" />
						</BridgeViewerIcon>
					</WorktreeAnnotationShareActionButton>
				</div>
			</DrawerHeader>
			<DrawerBody>
				<Field>
					<ToggleGroup
						aria-label="Annotation list"
						onValueChange={(scopes): void => {
							const nextScope = scopes[0];
							if (nextScope === 'pending' || nextScope === 'all') props.onScopeChange(nextScope);
						}}
						className="grid w-full grid-cols-2"
						role="group"
						size="sm"
						value={[props.scope]}
						variant="segmented"
					>
						<ToggleGroupItem
							aria-label={`Pending comments, ${pendingCountLabel}`}
							autoFocus
							className="w-full"
							value="pending"
						>
							<ListFilter aria-hidden="true" />
							Pending {props.membership.kind === 'unknown' ? '—' : props.membership.pendingCount}
						</ToggleGroupItem>
						<ToggleGroupItem
							aria-label={`All comments, ${allCountLabel}`}
							className="w-full"
							value="all"
						>
							<List aria-hidden="true" />
							All {props.membership.kind === 'unknown' ? '—' : props.membership.allCount}
						</ToggleGroupItem>
					</ToggleGroup>
				</Field>
				{props.error === null ? null : (
					<Alert className="mt-4" variant="destructive">
						<AlertDescription>{props.error}</AlertDescription>
						{props.errorCanChooseFolder && props.onChangeFolder ? (
							<Button onClick={props.onChangeFolder} size="sm" type="button" variant="outline">
								<ChooseFolderIcon aria-hidden="true" />
								{chooseFolderSpec.accessibleName}
							</Button>
						) : null}
					</Alert>
				)}
				{props.savedFilename ? (
					<div className="flex items-center gap-2" role="status">
						<span>Saved to {props.savedFilename}</span>
						{props.onReveal ? (
							<Button onClick={props.onReveal} size="sm" type="button" variant="outline">
								<RevealIcon aria-hidden="true" />
								{revealSpec.accessibleName}
							</Button>
						) : null}
						{props.onChangeFolder ? (
							<Button onClick={props.onChangeFolder} size="sm" type="button" variant="outline">
								<ChangeFolderIcon aria-hidden="true" />
								{changeFolderSpec.accessibleName}
							</Button>
						) : null}
					</div>
				) : null}
				{props.children}
				{props.history}
			</DrawerBody>
			<DrawerFooter>
				<WorktreeAnnotationDrawerActionButton
					ariaLabel={copySpec.accessibleName}
					disabled={outputDisabled}
					onClick={() => props.onCopy(props.scope)}
					tooltip={copySpec.tooltip}
				>
					<CopyIcon aria-hidden="true" data-icon="inline-start" />
					{props.isOutputPending ? 'Working…' : 'Copy'}
				</WorktreeAnnotationDrawerActionButton>
				<WorktreeAnnotationDrawerActionButton
					ariaLabel={exportSpec.accessibleName}
					disabled={outputDisabled}
					onClick={() => props.onExport(props.scope)}
					tooltip={exportSpec.tooltip}
				>
					<ExportIcon aria-hidden="true" data-icon="inline-start" />
					Export
				</WorktreeAnnotationDrawerActionButton>
				{props.onExportTo && props.onChangeFolder ? (
					<DropdownMenu>
						<DropdownMenuTrigger
							aria-label={optionsSpec.accessibleName}
							disabled={props.isOutputPending}
							render={<Button size="icon-sm" type="button" variant="outline" />}
						>
							<OptionsIcon aria-hidden="true" />
						</DropdownMenuTrigger>
						<DropdownMenuContent align="end">
							<DropdownMenuItem
								disabled={outputDisabled}
								onClick={() => props.onExportTo?.(props.scope)}
							>
								<ExportToIcon aria-hidden="true" />
								{exportToSpec.accessibleName}
							</DropdownMenuItem>
							<DropdownMenuItem onClick={props.onChangeFolder}>
								<ChangeFolderIcon aria-hidden="true" />
								{changeFolderSpec.accessibleName}
							</DropdownMenuItem>
						</DropdownMenuContent>
					</DropdownMenu>
				) : null}
			</DrawerFooter>
		</section>
	);
}

function WorktreeAnnotationDrawerActionButton(props: {
	readonly ariaLabel: string;
	readonly children: ReactNode;
	readonly disabled: boolean;
	readonly onClick: (event: MouseEvent<HTMLButtonElement>) => void;
	readonly tooltip: string;
}): ReactElement {
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<Button
						aria-label={props.ariaLabel}
						disabled={props.disabled}
						onClick={props.onClick}
						size="sm"
						type="button"
						variant="outline"
					/>
				}
			>
				{props.children}
			</TooltipTrigger>
			<TooltipContent side="left">{props.tooltip}</TooltipContent>
		</Tooltip>
	);
}

function WorktreeAnnotationShareActionButton(props: {
	readonly ariaLabel: string;
	readonly children: ReactNode;
	readonly size?: 'icon-sm' | undefined;
	readonly disabled: boolean;
	readonly onClick: (event: MouseEvent<HTMLButtonElement>) => void;
	readonly tooltip: string;
}): ReactElement {
	return (
		<Tooltip>
			<TooltipTrigger
				render={
					<BridgeViewerButton
						ariaLabel={props.ariaLabel}
						disabled={props.disabled}
						onClick={props.onClick}
						size={props.size ?? 'icon-sm'}
					/>
				}
			>
				{props.children}
			</TooltipTrigger>
			<TooltipContent side="bottom">{props.tooltip}</TooltipContent>
		</Tooltip>
	);
}
