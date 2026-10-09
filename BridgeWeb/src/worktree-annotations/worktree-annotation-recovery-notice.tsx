import { useState, type ReactElement } from 'react';

import { Button } from '@/components/ui/button.js';

import {
	useWorktreeAnnotationProjection,
	useWorktreeAnnotationSurfaceClient,
} from './worktree-annotation-surface-provider.js';

export function WorktreeAnnotationRecoveryNotice(): ReactElement | null {
	const annotationClient = useWorktreeAnnotationSurfaceClient();
	const projection = useWorktreeAnnotationProjection();
	const [failureMessage, setFailureMessage] = useState<string | null>(null);
	const [isAcknowledging, setIsAcknowledging] = useState(false);
	if (projection.recoveryStatus !== 'recovered_degraded') return null;

	const acknowledgeRecovery = async (): Promise<void> => {
		if (isAcknowledging) return;
		setIsAcknowledging(true);
		setFailureMessage(null);
		try {
			const outcome = await annotationClient.execute({ kind: 'recovery.acknowledge' });
			if (outcome.status.kind !== 'committed') {
				throw new Error(
					outcome.status.kind === 'failed'
						? outcome.status.code
						: 'Recovery acknowledgement was not committed.',
				);
			}
		} catch (error: unknown) {
			setFailureMessage(
				error instanceof Error ? error.message : 'Recovery acknowledgement failed.',
			);
		} finally {
			setIsAcknowledging(false);
		}
	};

	return (
		<div
			className="flex flex-col gap-2 px-3 py-2 text-sm text-muted-foreground"
			data-testid="comments-recovery-notice"
		>
			<p>Comments recovered with missing local history</p>
			<p>
				{failureMessage ??
					'Review the recovery notice before creating or changing inline comments.'}
			</p>
			<Button
				disabled={isAcknowledging}
				onClick={() => void acknowledgeRecovery()}
				size="xs"
				variant="outline"
			>
				Acknowledge
			</Button>
		</div>
	);
}
