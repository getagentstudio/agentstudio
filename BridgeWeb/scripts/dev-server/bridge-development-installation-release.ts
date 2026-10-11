// Development HTTP lifecycle only; this is not a shipped product control verb.
export const bridgeDevelopmentInstallationReleaseRoute = '/__bridge-product/release';

export async function releaseBridgeDevelopmentInstallation(props: {
	readonly endpoint: string;
	readonly headers: HeadersInit;
	readonly paneSessionId: string;
	readonly workerInstanceId: string;
	readonly signal: AbortSignal;
}): Promise<void> {
	const response = await fetch(props.endpoint, {
		body: JSON.stringify({
			paneSessionId: props.paneSessionId,
			workerInstanceId: props.workerInstanceId,
		}),
		headers: props.headers,
		method: 'POST',
		signal: props.signal,
	});
	if (response.status !== 204 || (await response.text()).length !== 0)
		throw new Error(`Development installation release failed with status ${response.status}.`);
}
