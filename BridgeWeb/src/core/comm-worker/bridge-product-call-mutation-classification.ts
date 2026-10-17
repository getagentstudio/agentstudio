import type { BridgeProductCallKind } from './bridge-product-call-contracts.js';

/** Unknown mutation outcomes stay observable; read-only calls do not take watch capacity. */
export function bridgeProductCallIsMutation(method: BridgeProductCallKind): boolean {
	switch (method) {
		case 'file.annotations.output.inspect':
		case 'file.annotations.projection.query':
		case 'file.source.current':
		case 'review.annotations.output.inspect':
		case 'review.annotations.projection.query':
		case 'review.comparisonTargets.query':
		case 'review.publication.install.admit':
			return false;
		case 'file.activeViewerMode.update':
		case 'file.annotations.command':
		case 'file.refresh.retry':
		case 'review.activeViewerMode.update':
		case 'review.annotations.command':
		case 'review.comparison.update':
		case 'review.intake.ready':
		case 'review.markFileViewed':
		case 'review.publication.applied':
			return true;
	}
}
