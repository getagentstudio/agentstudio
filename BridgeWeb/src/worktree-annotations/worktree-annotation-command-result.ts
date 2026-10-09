import type { WorktreeAnnotationSurfaceClient } from './worktree-annotation-surface-client.js';

export function assertCommittedAnnotationOutcome(
	outcome: Awaited<ReturnType<WorktreeAnnotationSurfaceClient['execute']>>,
): void {
	if (outcome.status.kind === 'failed') throw new Error(outcome.status.code);
	if (outcome.status.kind !== 'committed') {
		throw new Error('Annotation command did not commit.');
	}
}

export function annotationErrorMessage(error: unknown): string {
	if (error instanceof Error && error.message === 'invalidSource') {
		return 'The file changed. Your comment has not been saved. Update the file and select the intended lines again.';
	}
	return error instanceof Error ? error.message : 'Annotation operation failed.';
}

export function annotationMarkdownValidationMessage(
	code: 'bodyTooLarge' | 'emptyBody' | 'levelOneHeading' | 'rawHtml' | 'unsafeLinkDestination',
): string {
	const messages = {
		bodyTooLarge: 'Annotation Markdown must be 16 KiB or smaller.',
		emptyBody: 'Annotation Markdown cannot be empty.',
		levelOneHeading: 'Use H2-H6 headings; H1 is reserved for copied output.',
		rawHtml: 'Raw HTML is not allowed in annotation Markdown.',
		unsafeLinkDestination: 'Markdown links must use absolute HTTP(S) destinations.',
	} satisfies Readonly<Record<typeof code, string>>;
	return messages[code];
}
