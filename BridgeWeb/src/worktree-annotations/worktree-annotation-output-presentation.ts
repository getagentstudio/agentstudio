import type {
	WorktreeAnnotationCommandOutcome,
	WorktreeAnnotationOutputHistorySummary,
} from './worktree-annotation-surface-client.js';

type WorktreeAnnotationOutputOutcome = Extract<
	WorktreeAnnotationCommandOutcome['status'],
	{ readonly kind: 'output' }
>['outcome'];

export interface WorktreeAnnotationOutputFeedback {
	readonly closeInteraction: boolean;
	readonly message: string | null;
	readonly severity: 'error' | 'quiet' | 'success' | 'warning';
	readonly toast: string | null;
}

export function annotationOutputFeedback(
	outcome: WorktreeAnnotationOutputOutcome,
): WorktreeAnnotationOutputFeedback {
	switch (outcome.kind) {
		case 'destination_cancelled':
			return quietOutputFeedback;
		case 'destination_selection_failed':
			return visibleOutputFeedback(
				`Export destination could not be selected: ${outcome.selectionError}`,
				'error',
			);
		case 'succeeded':
			if (outcome.summary.outputKind === 'clipboard_markdown') {
				return {
					closeInteraction: true,
					message: null,
					severity: 'success',
					toast: `Copied ${annotationCountLabel(outcome.summary.messageCount)}`,
				};
			}
			return {
				closeInteraction: true,
				message: null,
				severity: 'success',
				toast: successfulExportMessage(outcome.summary),
			};
		case 'effect_failed':
			if (outcome.effectCode === 'missing_folder' || outcome.effectCode === 'permission_denied') {
				return visibleOutputFeedback(outcome.effectError, 'error');
			}
			return visibleOutputFeedback(
				outcome.summary.outputKind === 'clipboard_markdown'
					? 'Clipboard copy failed. The clipboard was not changed and no output history was recorded.'
					: 'Export failed. No file was written and no output history was recorded.',
				'error',
			);
		case 'effect_and_cleanup_failed':
			if (outcome.effectCode === 'missing_folder' || outcome.effectCode === 'permission_denied') {
				return visibleOutputFeedback(
					`${outcome.effectError} Output-history cleanup also failed.`,
					'error',
				);
			}
			return visibleOutputFeedback(
				outcome.summary.outputKind === 'clipboard_markdown'
					? 'Clipboard copy failed, so the clipboard was not changed. Cleanup was not recorded; this attempt may later appear as unknown.'
					: 'Export failed, so no file was written. Cleanup was not recorded; this attempt may later appear as unknown.',
				'error',
			);
		case 'partial_success':
			return {
				...visibleOutputFeedback(partialSuccessMessage(outcome.summary), 'warning'),
				closeInteraction: true,
			};
		default:
			return assertNeverOutputOutcome(outcome);
	}
}

export function annotationOutputHistoryStatus(
	state: WorktreeAnnotationOutputHistorySummary['state'],
	outputKind: WorktreeAnnotationOutputHistorySummary['outputKind'],
): string {
	switch (state) {
		case 'succeeded':
			return outputKind === 'clipboard_markdown' ? 'Copied' : 'Exported';
		case 'finalization_failed':
			return outputKind === 'clipboard_markdown'
				? 'Partial success — the clipboard was changed, but durable history was not recorded.'
				: 'Partial success — the file was written, but durable history was not recorded.';
		case 'unknown':
			return outputKind === 'clipboard_markdown'
				? 'Unknown — exact bytes are saved, but whether the clipboard was changed is not proven.'
				: 'Unknown — exact bytes are saved, but whether a file was written is not proven.';
		case 'prepared':
			return outputKind === 'clipboard_markdown'
				? 'Prepared — exact bytes are saved; no clipboard result or durable history is proven.'
				: 'Prepared — exact bytes are saved; no file-write result or durable history is proven.';
		default:
			return assertNeverHistoryState(state);
	}
}

export function annotationCountLabel(messageCount: number): string {
	return messageCount === 1 ? '1 annotation' : `${messageCount} annotations`;
}

function successfulExportMessage(
	summary: Extract<WorktreeAnnotationOutputOutcome, { readonly kind: 'succeeded' }>['summary'],
): string {
	const count = annotationCountLabel(summary.messageCount);
	return summary.destinationFilename === null
		? `Exported ${count}, but no destination filename was returned.`
		: `Exported ${count} to ${summary.destinationFilename}.`;
}

function partialSuccessMessage(
	summary: Extract<
		WorktreeAnnotationOutputOutcome,
		{ readonly kind: 'partial_success' }
	>['summary'],
): string {
	const count = annotationCountLabel(summary.messageCount);
	if (summary.outputKind === 'clipboard_markdown') {
		return `Clipboard contains ${count}, but durable history was not recorded.`;
	}
	return summary.destinationFilename === null
		? `A file containing ${count} was written, but durable history and its destination filename were not recorded.`
		: `${summary.destinationFilename} contains ${count}, but durable history was not recorded.`;
}

function visibleOutputFeedback(
	message: string,
	severity: Exclude<WorktreeAnnotationOutputFeedback['severity'], 'quiet'>,
): WorktreeAnnotationOutputFeedback {
	return { closeInteraction: false, message, severity, toast: null };
}

const quietOutputFeedback: WorktreeAnnotationOutputFeedback = {
	closeInteraction: false,
	message: null,
	severity: 'quiet',
	toast: null,
};

function assertNeverOutputOutcome(_outcome: never): never {
	throw new Error('Unhandled worktree annotation output outcome.');
}

function assertNeverHistoryState(_state: never): never {
	throw new Error('Unhandled worktree annotation output history state.');
}
