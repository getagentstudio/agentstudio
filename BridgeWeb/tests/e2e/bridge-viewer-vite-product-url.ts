export function bridgeViewerViteProductFileUrl(origin: string, path: string): string {
	const url = new URL('/', origin);
	url.searchParams.set('fixture', 'worktree');
	url.searchParams.set('scenario', 'current-worktree');
	url.searchParams.set('viewer', 'file');
	url.searchParams.set('workers', 'on');
	url.searchParams.set('path', path);
	return url.toString();
}

export function bridgeViewerViteProductReviewUrl(origin: string, path: string): string {
	const url = new URL(bridgeViewerViteProductFileUrl(origin, path));
	url.searchParams.set('viewer', 'review');
	if (path !== undefined) url.searchParams.set('path', path);
	return url.toString();
}

export function requireBridgeViewerVitePrimaryReviewPath(oracle: {
	readonly reviewFiles: readonly { readonly path: string }[];
}): string {
	const firstReviewFile = oracle.reviewFiles[0];
	if (firstReviewFile === undefined) {
		throw new Error('Vite product fixture has no Review file to select.');
	}
	return firstReviewFile.path;
}
