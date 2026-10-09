import type { BridgeRegionPresentationState } from './bridge-region-presentation-state.js';

export type BridgePaneFailurePart = 'review' | 'file' | 'comments' | 'markdown';

/** Values supplied by the existing region and recovery owners, never collected or retained. */
export interface BridgePaneFailureEntry {
	readonly part: BridgePaneFailurePart;
	readonly state: BridgeRegionPresentationState;
	readonly fileName?: string | null | undefined;
	readonly retry?: (() => void) | undefined;
}

export const bridgePaneFailureDisplaySpec = {
	pane: "Bridge couldn't start.",
	reviewUpdate: "Review couldn't update. Showing the last version.",
	reviewLoad: "Review couldn't load.",
	comments: "Comments couldn't load.",
	commentsCorrectiveAction: 'Correct the local history failure before reopening Comments.',
	fileLoad: "Files couldn't load.",
	fileMissingRoot: "Files couldn't load. The worktree folder is missing.",
	fileUnreadableRoot: "Files couldn't load. The worktree folder can't be read.",
	fileUpdate: "Files couldn't update. Showing the last version.",
	markdownLoad: "Markdown couldn't load.",
	markdownUpdate: "Markdown couldn't update. Showing the last version.",
	stale: 'Stale',
	noReview: 'No review loaded',
	noFiles: 'No files loaded',
	noContent: 'No content loaded',
	noComments: 'No comments loaded',
	noDocument: 'No document loaded',
	diagram: "Couldn't draw this diagram",
	openFile: (fileName: string): string => `Couldn't open ${fileName}.`,
	several: (parts: readonly BridgePaneFailurePart[]): string => {
		const names = parts.map((part, index): string => {
			const name = { review: 'Review', file: 'Files', comments: 'Comments', markdown: 'Markdown' }[
				part
			];
			return index === 0 ? name : name.toLowerCase();
		});
		const sentenceSubject =
			names.length === 2
				? names.join(' and ')
				: `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
		return `${sentenceSubject} couldn't update.`;
	},
} as const;

export interface BridgePaneFailureSummary {
	readonly state: Extract<BridgeRegionPresentationState, { readonly kind: 'failed' }>;
	readonly retry: (() => void) | undefined;
	readonly correctiveAction: string | undefined;
}

/** One pane sentence and one recovery fan-out, derived only from W6's failed outputs. */
export function projectBridgePaneFailureSummary(
	entries: readonly BridgePaneFailureEntry[],
): BridgePaneFailureSummary | null {
	const failedEntries = entries.filter(
		(
			entry,
		): entry is BridgePaneFailureEntry & {
			readonly state: Extract<BridgeRegionPresentationState, { readonly kind: 'failed' }>;
		} => entry.state.kind === 'failed',
	);
	if (failedEntries.length === 0) return null;
	const paneEntry = failedEntries.find((entry): boolean => entry.state.failure.scope === 'pane');
	const parts = [...new Set(failedEntries.map((entry): BridgePaneFailurePart => entry.part))];
	const first = failedEntries[0];
	if (first === undefined) return null;
	const readEntry = failedEntries.find((entry): boolean => entry.state.failure.scope === 'read');
	const fileName = readEntry?.fileName?.split('/').at(-1);
	const fileRootMessage =
		first.part === 'file' ? fileRootFailureSummaryMessage(failedEntries) : null;
	const message =
		paneEntry !== undefined
			? bridgePaneFailureDisplaySpec.pane
			: parts.length > 1
				? bridgePaneFailureDisplaySpec.several(parts)
				: fileRootMessage !== null
					? fileRootMessage
					: fileName !== undefined
						? bridgePaneFailureDisplaySpec.openFile(fileName)
						: first.part === 'review'
							? failedEntries.some((entry): boolean => entry.state.retainsContent)
								? bridgePaneFailureDisplaySpec.reviewUpdate
								: bridgePaneFailureDisplaySpec.reviewLoad
							: first.part === 'comments'
								? bridgePaneFailureDisplaySpec.comments
								: first.part === 'file'
									? first.state.retainsContent
										? bridgePaneFailureDisplaySpec.fileUpdate
										: bridgePaneFailureDisplaySpec.fileLoad
									: first.state.retainsContent
										? bridgePaneFailureDisplaySpec.markdownUpdate
										: bridgePaneFailureDisplaySpec.markdownLoad;
	const permanentEntries = (paneEntry === undefined ? failedEntries : [paneEntry]).filter(
		(entry) => entry.state.failure.kind === 'permanent',
	);
	const correctiveActions = [
		...new Set(
			permanentEntries.flatMap((entry): string[] =>
				entry.state.failure.kind === 'permanent' ? [entry.state.failure.correctiveAction] : [],
			),
		),
	];
	const recoveries = [
		...new Set(
			failedEntries.flatMap((entry): (() => void)[] =>
				entry.state.failure.kind === 'retryable' && entry.retry !== undefined ? [entry.retry] : [],
			),
		),
	];
	const allFailuresPermanent = (paneEntry === undefined ? failedEntries : [paneEntry]).every(
		(entry): boolean => entry.state.failure.kind === 'permanent',
	);
	return {
		state: {
			kind: 'failed',
			retainsContent: false,
			failure: allFailuresPermanent
				? {
						kind: 'permanent',
						scope: 'surface',
						message,
						correctiveAction: correctiveActions.join(' '),
					}
				: { kind: 'retryable', scope: paneEntry === undefined ? 'surface' : 'pane', message },
		},
		retry:
			paneEntry !== undefined || allFailuresPermanent || recoveries.length === 0
				? undefined
				: (): void => {
						for (const recover of recoveries) recover();
					},
		correctiveAction: correctiveActions.length === 0 ? undefined : correctiveActions.join(' '),
	};
}

function fileRootFailureSummaryMessage(
	entries: readonly (BridgePaneFailureEntry & {
		readonly state: Extract<BridgeRegionPresentationState, { readonly kind: 'failed' }>;
	})[],
): string | null {
	for (const entry of entries) {
		const failure = entry.state.failure;
		if (failure.scope !== 'surface' || failure.kind !== 'retryable') continue;
		switch (failure.fileRootCause) {
			case 'missingRoot':
				return bridgePaneFailureDisplaySpec.fileMissingRoot;
			case 'unreadableRoot':
				return bridgePaneFailureDisplaySpec.fileUnreadableRoot;
			case undefined:
				break;
		}
	}
	return null;
}
