import { z } from 'zod';

import type { BridgeProductBatchFrame } from './bridge-product-batch-wire-contracts.js';
import type { BridgeWorkerHealthEvent } from './bridge-worker-contracts.js';

export type BridgeProductBatchRejectionReason =
	| 'missingReceiver'
	| 'changeBeforeSnapshot'
	| 'revisionGap'
	| 'conflictingBegin'
	| 'overlappingChange'
	| 'missingStage'
	| 'partRevisionAhead'
	| 'partIndexOutsideBatch'
	| 'conflictingPart'
	| 'receiptBaselineRegressed'
	| 'coveredScopeMismatch'
	| 'incompleteBatch'
	| 'missingPart'
	| 'payloadVerificationFailed';

export interface BridgeProductBatchDiagnostic {
	readonly step:
		| 'receiverRejection'
		| 'payloadVerification'
		| 'applicationInstall'
		| 'reviewPresentationApply';
	readonly subscriptionKind: BridgeProductBatchFrame['subscriptionKind'];
	readonly subscriptionId: string;
	readonly frameKind: BridgeProductBatchFrame['kind'];
	readonly rejection: BridgeProductBatchRejectionReason | null;
	readonly exception: { readonly name: string; readonly message: string } | null;
}

export function bridgeProductBatchDiagnostic(props: {
	readonly frame: BridgeProductBatchFrame;
	readonly step: BridgeProductBatchDiagnostic['step'];
	readonly rejection?: BridgeProductBatchRejectionReason;
	readonly error?: unknown;
}): BridgeProductBatchDiagnostic {
	return {
		step: props.step,
		subscriptionKind: props.frame.subscriptionKind,
		subscriptionId: props.frame.subscriptionId,
		frameKind: props.frame.kind,
		rejection: props.rejection ?? null,
		exception: props.error === undefined ? null : scrubBatchException(props.error),
	};
}

export function recordBridgeProductBatchDiagnostic(
	observer: ((sample: BridgeProductBatchDiagnostic) => void) | undefined,
	sample: BridgeProductBatchDiagnostic,
): void {
	try {
		observer?.(sample);
	} catch {
		/* An unavailable diagnostic sink cannot change batch recovery. */
	}
}

export function bridgeProductBatchDiagnosticHealthMessage(
	diagnostic: BridgeProductBatchDiagnostic,
): BridgeWorkerHealthEvent {
	return {
		wireVersion: 1,
		direction: 'serverWorkerToMain',
		transferDescriptors: [],
		kind: 'health',
		status: 'ready',
		message: `productBatchDiagnostic:${JSON.stringify(diagnostic)}`,
	};
}

function scrubBatchException(error: unknown): { readonly name: string; readonly message: string } {
	if (error instanceof z.ZodError) {
		return {
			name: 'ZodError',
			message: error.issues
				.slice(0, 4)
				.map(
					(issue) =>
						`${issue.code} at ${issue.path
							.map((part) =>
								typeof part === 'number' ? String(part) : diagnosticPropertyName(String(part)),
							)
							.join('.')}`,
				)
				.join('; '),
		};
	}
	if (!(error instanceof Error)) return { name: 'ThrownValue', message: 'Non-Error exception' };
	const name = [
		'Error',
		'TypeError',
		'RangeError',
		'SyntaxError',
		'ReferenceError',
		'DOMException',
	].includes(error.name)
		? error.name
		: 'Error';
	return {
		name,
		message: error.message
			.replace(/(["'`])[^"'`]*\1/g, '<value>')
			.replace(/(?:\/|[A-Za-z]:\\)[^\s,;)}\]]+/g, '<path>')
			.replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, '<id>')
			.replace(/\b[0-9a-f]{32,}\b/gi, '<digest>')
			.replace(/\s+/g, ' ')
			.slice(0, 256),
	};
}

function diagnosticPropertyName(property: string): string {
	const known = new Set([
		'recordKind',
		'revision',
		'publicationId',
		'desired',
		'displayed',
		'status',
		'packageId',
		'generation',
		'query',
		'queryKind',
		'queryId',
		'baseEndpoint',
		'headEndpoint',
		'endpointId',
		'kind',
		'providerIdentity',
		'contentSetHash',
		'contentByRole',
		'base',
		'head',
		'diff',
		'file',
		'source',
		'reviewGeneration',
		'sourceIdentity',
		'itemId',
		'parentPath',
		'headPath',
		'basePath',
		'extentByRole',
		'state',
		'expectedSha256',
		'expectedByteLength',
	]);
	return known.has(property) ? property : '<field>';
}
