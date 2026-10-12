import type { Page, Request } from 'playwright';

import { type HandledLaunchPromise } from '../dev-server/handled-launch-promise.ts';
import { observeVerifierStartupStep } from './browser-session.ts';

interface WorktreeFileContentRouteTimingObservation {
	readonly requestStartedMilliseconds: HandledLaunchPromise<number>;
	readonly responseStartedMilliseconds: HandledLaunchPromise<number>;
}

export function observeWorktreeFileContentRouteTiming(props: {
	readonly page: Page;
	readonly startedAt: number;
}): WorktreeFileContentRouteTimingObservation {
	const requestStartedMilliseconds = observeVerifierStartupStep(
		'initial File content request',
		props.page
			.waitForRequest(requestIsWorktreeFileContent)
			.then((): number => Math.max(0, performance.now() - props.startedAt)),
	);
	const responseStartedMilliseconds = observeVerifierStartupStep(
		'initial File content response',
		props.page
			.waitForResponse((response): boolean => requestIsWorktreeFileContent(response.request()))
			.then((): number => Math.max(0, performance.now() - props.startedAt)),
	);
	return { requestStartedMilliseconds, responseStartedMilliseconds };
}

function requestIsWorktreeFileContent(request: Request): boolean {
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/content'
	) {
		return false;
	}
	const encodedBody = request.postData();
	if (encodedBody === null) return false;
	try {
		const decodedBody: unknown = JSON.parse(encodedBody);
		return (
			typeof decodedBody === 'object' &&
			decodedBody !== null &&
			'kind' in decodedBody &&
			decodedBody.kind === 'content.open' &&
			'contentKind' in decodedBody &&
			decodedBody.contentKind === 'file.content'
		);
	} catch {
		return false;
	}
}
