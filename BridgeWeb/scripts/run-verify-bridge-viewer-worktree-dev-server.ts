import { BridgeWebTestLaunch } from './dev-server/bridge-web-test-launch.ts';

const launch = await BridgeWebTestLaunch.start();
const moduleLoader = await launch.startVite({
	configFile: false,
	optimizeDeps: { noDiscovery: true },
	server: { hmr: false, middlewareMode: true },
});

try {
	await launch.run(async (): Promise<void> => {
		await launch.runStep(
			'verifier module and owned stack',
			async () =>
				await moduleLoader.ssrLoadModule('/scripts/verify-bridge-viewer-worktree-dev-server.ts'),
		);
	});
} finally {
	await launch.dispose();
}
