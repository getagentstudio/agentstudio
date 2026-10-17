import type {
	BridgeProductPanePresentationFrame,
	BridgeProductPaneSurfaceSelectionFrame,
} from './bridge-product-transport.js';

export function ignoreBridgeProductPanePresentationFrame(
	_frame: BridgeProductPanePresentationFrame,
): void {}

export function ignoreBridgeProductPaneSurfaceSelectionFrame(
	_frame: BridgeProductPaneSurfaceSelectionFrame,
): void {}
