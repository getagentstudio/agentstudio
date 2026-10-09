import { describe, expect, test } from 'vitest';

import {
	annotationOutputFeedback,
	annotationOutputHistoryStatus,
} from './worktree-annotation-output-presentation.js';
import type { WorktreeAnnotationCommandOutcome } from './worktree-annotation-surface-client.js';

type WorktreeAnnotationOutputResultSummary = Extract<
	Extract<WorktreeAnnotationCommandOutcome['status'], { readonly kind: 'output' }>['outcome'],
	{ readonly kind: 'succeeded' }
>['summary'];

describe('worktree annotation output presentation', () => {
	test('reports normal Copy success and closes only its interaction', () => {
		expect(
			annotationOutputFeedback({
				kind: 'succeeded',
				summary: outputSummary({ messageCount: 2, outputKind: 'clipboard_markdown' }),
			}),
		).toEqual({
			closeInteraction: true,
			message: null,
			severity: 'success',
			toast: 'Copied 2 annotations',
		});
	});

	test('reports the actual export filename and treats destination cancellation as quiet', () => {
		expect(
			annotationOutputFeedback({
				kind: 'succeeded',
				summary: outputSummary({
					destinationFilename: 'review-comments.json',
					messageCount: 1,
					outputKind: 'json_file',
				}),
			}),
		).toEqual({
			closeInteraction: true,
			message: null,
			severity: 'success',
			toast: 'Exported 1 annotation to review-comments.json.',
		});
		expect(annotationOutputFeedback({ kind: 'destination_cancelled' })).toEqual({
			closeInteraction: false,
			message: null,
			severity: 'quiet',
			toast: null,
		});
	});

	test('states exactly what a partial Copy outcome proves', () => {
		expect(
			annotationOutputFeedback({
				finalizationError: 'forcedFailure',
				kind: 'partial_success',
				summary: outputSummary({ messageCount: 2, outputKind: 'clipboard_markdown' }),
			}),
		).toMatchObject({
			closeInteraction: true,
			message: 'Clipboard contains 2 annotations, but durable history was not recorded.',
			severity: 'warning',
		});
	});

	test('keeps a typed missing-folder error visible with its cause', () => {
		expect(
			annotationOutputFeedback({
				effectCode: 'missing_folder',
				effectError: 'The export folder no longer exists. Choose a folder and try again.',
				kind: 'effect_failed',
				summary: outputSummary({ messageCount: 1, outputKind: 'json_file' }),
			}),
		).toMatchObject({
			closeInteraction: false,
			message: 'The export folder no longer exists. Choose a folder and try again.',
			severity: 'error',
		});
	});

	test('distinguishes partial and unknown history without rebuilding content', () => {
		expect(annotationOutputHistoryStatus('succeeded', 'clipboard_markdown')).toBe('Copied');
		expect(annotationOutputHistoryStatus('succeeded', 'json_file')).toBe('Exported');
		expect(annotationOutputHistoryStatus('finalization_failed', 'json_file')).toBe(
			'Partial success — the file was written, but durable history was not recorded.',
		);
		expect(annotationOutputHistoryStatus('unknown', 'clipboard_markdown')).toBe(
			'Unknown — exact bytes are saved, but whether the clipboard was changed is not proven.',
		);
		expect(annotationOutputHistoryStatus('prepared', 'json_file')).toBe(
			'Prepared — exact bytes are saved; no file-write result or durable history is proven.',
		);
	});
});

function outputSummary(props: {
	readonly destinationFilename?: string | null;
	readonly messageCount: number;
	readonly outputKind: 'clipboard_markdown' | 'json_file';
}): WorktreeAnnotationOutputResultSummary {
	return {
		attemptId: '00000000-0000-7000-8000-000000000071',
		destinationFilename: props.destinationFilename ?? null,
		messageCount: props.messageCount,
		outputKind: props.outputKind,
		sessionId: '00000000-0000-7000-8000-000000000011',
	} as const;
}
