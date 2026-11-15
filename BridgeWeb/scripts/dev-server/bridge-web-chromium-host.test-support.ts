import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';

import type { LaunchOptions } from 'playwright';

export function spawnBrowserHostFixture(props: {
	readonly options: LaunchOptions;
	readonly ignoreSIGTERM?: boolean;
	readonly suppressGroupReport?: boolean;
	readonly inheritWitness?: boolean;
}): ChildProcessWithoutNullStreams {
	const entry = new URL('./bridge-web-browser-host.ts', import.meta.url).href;
	const source = [
		`process.argv[2] = ${JSON.stringify(JSON.stringify(props.options))};`,
		props.ignoreSIGTERM === true
			? `process.on('SIGTERM', () => {}); const originalOn = process.on; process.on = function(event, listener) { return event === 'SIGTERM' ? this : originalOn.call(this, event, listener); };`
			: '',
		props.suppressGroupReport === true
			? `const originalWrite = process.stdout.write.bind(process.stdout); process.stdout.write = function(chunk, ...rest) { return String(chunk).includes('browserSpawned') ? true : originalWrite(chunk, ...rest); };`
			: '',
		`await import(${JSON.stringify(entry)});`,
	].join('\n');
	// The extra inherited descriptor is an exit witness: only the driver and this
	// host hold it. EOF after driver death proves the host closed it too.
	return spawn(
		process.execPath,
		['--experimental-strip-types', '--input-type=module', '--eval', source],
		{
			stdio: ['pipe', 'pipe', 'pipe', ...(props.inheritWitness === true ? [3] : [])],
		},
	) as ChildProcessWithoutNullStreams;
}
