import type { Page, Response } from 'playwright';

import { bridgeProductWorktreeAnnotationCommandOutcomeSchema } from '../../src/core/comm-worker/bridge-product-worktree-annotation-contracts.js';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';

export interface CommittedAnnotationOutcome {
	readonly context: {
		readonly path: string;
		readonly sourceIdentity: string;
		readonly sourceRole: 'file' | 'review_base' | 'review_head';
		readonly threadId: string;
	};
	readonly messageId: string;
	readonly messageRevision: number;
	readonly requestId: string;
	readonly sessionId: string;
	readonly sessionRevision: number;
	readonly threadRevision: number;
}

export async function waitForCommittedAnnotationOutcome(
	page: Page,
	operationKind: 'draft.flush' | 'draft.save' | 'reply.create' | 'root.create',
	surface: 'file' | 'review' = 'review',
): Promise<CommittedAnnotationOutcome> {
	const settled = await waitForProductCallSettlement(page, (candidate): boolean =>
		annotationCommandResponseMatches(candidate, operationKind, surface),
	);
	const body: unknown = settled.result;
	if (!isRecord(body) || body['kind'] !== 'call.completed' || !isRecord(body['call'])) {
		throw new Error(`Malformed committed ${operationKind} response.`);
	}
	const result = body['call']['result'];
	if (!isRecord(result) || result['kind'] !== 'completed' || !isRecord(result['outcome'])) {
		throw new Error(`Missing committed ${operationKind} outcome.`);
	}
	const parsedOutcome = bridgeProductWorktreeAnnotationCommandOutcomeSchema.safeParse(
		result['outcome'],
	);
	if (!parsedOutcome.success) {
		throw new Error(`Malformed canonical ${operationKind} outcome.`);
	}
	const outcome = parsedOutcome.data;
	if (outcome.status.kind !== 'committed') {
		throw new Error(
			`Non-committed ${surface} ${operationKind} outcome: ${JSON.stringify(outcome.status)}.`,
		);
	}
	if (outcome.receipt?.kind !== 'message') {
		throw new Error(`Committed ${operationKind} outcome is missing its message receipt.`);
	}
	if (outcome.sessionId === null) {
		throw new Error(`Committed ${operationKind} outcome has invalid identity.`);
	}
	return {
		context: {
			path: outcome.receipt.context.path,
			sourceIdentity: outcome.receipt.context.sourceIdentity,
			sourceRole: outcome.receipt.context.sourceRole,
			threadId: outcome.receipt.context.threadId,
		},
		messageId: outcome.receipt.message.messageId,
		messageRevision: outcome.receipt.message.messageRevision,
		requestId: outcome.requestId,
		sessionId: outcome.sessionId,
		sessionRevision: outcome.receipt.message.sessionRevision,
		threadRevision: outcome.receipt.message.threadRevision,
	};
}

function annotationCommandResponseMatches(
	response: Response,
	operationKind: 'draft.flush' | 'draft.save' | 'reply.create' | 'root.create',
	surface: 'file' | 'review',
): boolean {
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	) {
		return false;
	}
	const body: unknown = request.postDataJSON();
	return (
		isRecord(body) &&
		body['kind'] === 'product.call' &&
		isRecord(body['call']) &&
		body['call']['method'] === `${surface}.annotations.command` &&
		isRecord(body['call']['request']) &&
		isRecord(body['call']['request']['operation']) &&
		body['call']['request']['operation']['kind'] === operationKind
	);
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
