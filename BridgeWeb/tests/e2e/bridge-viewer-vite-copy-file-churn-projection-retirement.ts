import type { Page, Request, Route } from 'playwright';

import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { bridgeProductContentRequestSchema } from '../../src/core/comm-worker/bridge-product-content-contracts.js';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';

export interface EditedProjectionRetirementEvidence {
	readonly heldDescriptorId: string | null;
	readonly retiredRequestFailure: string | null;
	readonly successorDescriptorIds: readonly string[];
}

// The pending File transfer finishes while the edited annotation's first rich
// projection is held. The real worker invalidates that projection and requests
// its successor. No response is fabricated and no clock releases either hold.
export async function holdEditedProjectionAcrossFileRefresh(props: {
	readonly expectedFileSha256: string;
	readonly page: Page;
	readonly testSignal: AbortSignal;
}): Promise<{
	readonly evidence: () => EditedProjectionRetirementEvidence;
	readonly stop: () => Promise<void>;
}> {
	const releaseFileContent = makeDeferred<void>();
	const releaseOldProjection = makeDeferred<void>();
	const demandedProjectionCorrelations = new Set<string>();
	const successorDescriptorIds = new Set<string>();
	const pendingRoutes = new Set<Promise<void>>();
	let saveSequence: number | null = null;
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
			callRequest['operation']['kind'] === 'draft.save'
		) {
			saveSequence = control.requestSequence;
		}
		if (
			saveSequence !== null &&
			control.requestSequence > saveSequence &&
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
	};
	const releaseHolds = (): void => {
		releaseFileContent.resolve();
		releaseOldProjection.resolve();
	};
	const onAbort = (): void => {
		console.error(
			`TQ45 edited projection/File refresh await aborted: heldDescriptor=${heldDescriptorId ?? 'none'} retired=${retiredRequestFailure ?? 'none'} successors=${JSON.stringify([...successorDescriptorIds])}`,
		);
		releaseHolds();
	};
	const handleContent = async (route: Route): Promise<void> => {
		const parsed = bridgeProductContentRequestSchema.safeParse(route.request().postDataJSON());
		if (parsed.success) {
			const content = parsed.data;
			if (
				content.contentKind === 'file.content' &&
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
		evidence: (): EditedProjectionRetirementEvidence => ({
			heldDescriptorId,
			retiredRequestFailure,
			successorDescriptorIds: [...successorDescriptorIds],
		}),
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
