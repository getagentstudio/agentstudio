import type { BridgeCommWorkerAnnotationProjectionTransport } from './bridge-comm-worker-annotation-projection-query-controller.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';

export function bridgeCommWorkerAnnotationProjectionTransport(
	productTransport: BridgeProductTransportSession,
): BridgeCommWorkerAnnotationProjectionTransport {
	return {
		callProjection: (surface, request, signal): Promise<unknown> =>
			surface === 'file'
				? productTransport.call('file.annotations.projection.query', request, { signal })
				: productTransport.call('review.annotations.projection.query', request, { signal }),
		openContent: (descriptor, signal) =>
			productTransport.openContent(descriptor, signal, descriptor.page.operationCorrelationId),
		subscribe: (surface) =>
			surface === 'file'
				? productTransport.subscribe(bridgeProductFileAnnotationMetadataApplicationProtocol, {})
				: productTransport.subscribe(bridgeProductReviewAnnotationMetadataApplicationProtocol, {}),
		setScope: async ({ sessionIds, subscriptionId, worktreeId }): Promise<void> => {
			if (productTransport.setViewScopeForSubscription === undefined) {
				throw new Error('Comment view scope admission is unavailable.');
			}
			const settlement = await productTransport.setViewScopeForSubscription({
				scope: { kind: 'comment', sessionIds, worktreeId },
				subscriptionId,
			});
			if (settlement.kind === 'cancelled') {
				throw new Error('Comment view scope admission was superseded.');
			}
		},
	};
}
