import type { Page, Request, Route } from 'playwright';

import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { bridgeProductContentRequestSchema } from '../../src/core/comm-worker/bridge-product-content-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export interface AnnotationProjectionRetirementEvidence {
	readonly heldDescriptorId: string | null;
	readonly sourceRefreshRequestCount: number;
	readonly retiredRequestFailure: string | null;
	readonly successorDescriptorIds: readonly string[];
}

// Hold the first demanded projection across a real File refresh. The initial
// draft case refreshes identical bytes so its composer keeps the same source;
// the edited Save case releases a pending changed-content transfer. The real
// worker retires the first projection. No response or timed release is fabricated.
export async function holdAnnotationProjectionAcrossFileRefresh(props: {
	readonly ordering:
		| { readonly kind: 'edited-save' }
		| { readonly kind: 'initial-draft'; readonly writeFileRefresh: () => Promise<void> };
	readonly expectedFileSha256: string;
	readonly page: Page;
	readonly testSignal: AbortSignal;
}): Promise<{
	readonly evidence: () => AnnotationProjectionRetirementEvidence;
	readonly stop: () => Promise<void>;
	readonly waitForRetirement: () => Promise<void>;
}> {
	const releaseFileContent = makeDeferred<void>();
	const releaseOldProjection = makeDeferred<void>();
	const requestRetirement = makeDeferred<'retired' | 'aborted'>();
	const demandedProjectionCorrelations = new Set<string>();
	const successorDescriptorIds = new Set<string>();
	const pendingRoutes = new Set<Promise<void>>();
	let anchorSequence: number | null = null;
	let sourceRefreshRequestCount = 0;
	const anchorOperation = props.ordering.kind === 'initial-draft' ? 'root.create' : 'draft.save';
	let heldRequest: Request | null = null;
	let heldCorrelationId: string | null = null;
	let heldDescriptorId: string | null = null;
	let retiredRequestFailure: string | null = null;
	const observeCommands = (request: Request): void => {
		if (new URL(request.url()).pathname !== '/__bridge-product/command') return;
		const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
		if (!parsed.success || parsed.data.kind !== 'product.call') return;
		const control = parsed.data;
		const callRequest: unknown = control.call.request;
		if (!isRecord(callRequest)) return;
		if (
			control.call.method === 'file.annotations.command' &&
			isRecord(callRequest['operation']) &&
			callRequest['operation']['kind'] === anchorOperation
		) {
			anchorSequence = control.requestSequence;
		}
		if (
			control.call.method === 'file.annotations.command' &&
			isRecord(callRequest['operation']) &&
			callRequest['operation']['kind'] === 'source.refresh'
		)
			sourceRefreshRequestCount += 1;
		if (
			anchorSequence !== null &&
			control.requestSequence > anchorSequence &&
			control.call.method === 'file.annotations.projection.query' &&
			Array.isArray(callRequest['sessionIds']) &&
			callRequest['sessionIds'].length > 0 &&
			typeof callRequest['operationCorrelationId'] === 'string'
		) {
			demandedProjectionCorrelations.add(callRequest['operationCorrelationId']);
		}
	};
	const observeRetirement = (request: Request): void => {
		if (request !== heldRequest) return;
		retiredRequestFailure = request.failure()?.errorText ?? 'request failed';
		requestRetirement.resolve('retired');
	};
	const releaseHolds = (): void => {
		releaseFileContent.resolve();
		releaseOldProjection.resolve();
	};
	const onAbort = (): void => {
		requestRetirement.resolve('aborted');
		console.error(
			`TQ45 ${props.ordering.kind} projection/File refresh await aborted: heldDescriptor=${heldDescriptorId ?? 'none'} sourceRefreshRequests=${sourceRefreshRequestCount} retired=${retiredRequestFailure ?? 'none'} successors=${JSON.stringify([...successorDescriptorIds])}`,
		);
		releaseHolds();
	};
	const handleContent = async (route: Route): Promise<void> => {
		const parsed = bridgeProductContentRequestSchema.safeParse(route.request().postDataJSON());
		if (parsed.success) {
			const content = parsed.data;
			if (
				content.contentKind === 'file.content' &&
				(props.ordering.kind === 'edited-save' || heldRequest !== null) &&
				content.descriptor.expectedSha256 === props.expectedFileSha256
			) {
				await releaseFileContent.promise;
			} else if (
				content.contentKind === 'annotation.projection' &&
				content.operationCorrelationId !== null &&
				demandedProjectionCorrelations.has(content.operationCorrelationId)
			) {
				if (heldRequest === null) {
					heldRequest = route.request();
					heldCorrelationId = content.operationCorrelationId;
					heldDescriptorId = content.descriptor.descriptorId;
					releaseFileContent.resolve();
					if (props.ordering.kind === 'initial-draft') await props.ordering.writeFileRefresh();
					await releaseOldProjection.promise;
				} else if (content.operationCorrelationId !== heldCorrelationId) {
					successorDescriptorIds.add(content.descriptor.descriptorId);
					releaseOldProjection.resolve();
				}
			}
		}
		await route.continue();
	};
	const handler = (route: Route): Promise<void> => {
		const completion = handleContent(route)
			.catch((error: unknown): void => {
				if (!props.testSignal.aborted && !props.page.isClosed()) throw error;
			})
			.finally((): void => {
				pendingRoutes.delete(completion);
			});
		pendingRoutes.add(completion);
		return completion;
	};
	const pattern = '**/__bridge-product/content**';
	await props.page.route(pattern, handler);
	props.page.on('request', observeCommands);
	props.page.on('requestfailed', observeRetirement);
	props.testSignal.addEventListener('abort', onAbort, { once: true });
	return {
		evidence: (): AnnotationProjectionRetirementEvidence => ({
			heldDescriptorId,
			sourceRefreshRequestCount,
			retiredRequestFailure,
			successorDescriptorIds: [...successorDescriptorIds],
		}),
		waitForRetirement: async (): Promise<void> => {
			if ((await requestRetirement.promise) !== 'retired') {
				throw new Error(
					'Annotation projection request retirement was not observed before test abort.',
				);
			}
		},
		stop: async (): Promise<void> => {
			releaseHolds();
			await props.page.unroute(pattern, handler);
			await Promise.allSettled(pendingRoutes);
			props.page.off('request', observeCommands);
			props.page.off('requestfailed', observeRetirement);
			props.testSignal.removeEventListener('abort', onAbort);
		},
	};
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}
