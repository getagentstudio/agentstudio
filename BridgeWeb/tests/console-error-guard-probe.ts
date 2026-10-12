import { describe, expect, test, type TestContext } from 'vitest';

export const actWarningProbeComponentName = 'ActWarningProbe';

interface DefineConsoleErrorGuardProbeProps {
	readonly suiteName: string;
	readonly emitActWarning: (context: TestContext) => Promise<void>;
	readonly runOwnedBody?: (context: TestContext, body: () => Promise<void>) => Promise<void>;
	// The warning text the guard failure must carry; defaults to the update form,
	// which names the component.
	readonly expectedWarningText?: string;
}

// Proves the suite's configuration loads ./console-error-guard.ts by letting the
// guard fail a real test. `test.fails` passes only when its test fails, and
// onTestFailed records why, so the following test asserts the failure came from
// the guard and names the component that updated outside act().
export function defineConsoleErrorGuardProbe(props: DefineConsoleErrorGuardProbeProps): void {
	describe(`console error guard in the ${props.suiteName} suite`, () => {
		let recordedGuardFailure = '';

		test.fails('fails a test that emits a React act() warning', async (context) => {
			const { onTestFailed } = context;
			onTestFailed(({ task }): void => {
				recordedGuardFailure = (task.result?.errors ?? [])
					.map((error: { readonly message: string }): string => error.message)
					.join('\n');
			});
			if (props.runOwnedBody !== undefined)
				await props.runOwnedBody(
					context,
					async (): Promise<void> => await props.emitActWarning(context),
				);
			else await props.emitActWarning(context);
		});

		test('reports the act() warning text', () => {
			expect(recordedGuardFailure).toContain('BridgeWeb console error guard tripped');
			expect(recordedGuardFailure).toContain(
				props.expectedWarningText ??
					`An update to ${actWarningProbeComponentName} inside a test was not wrapped in act(...)`,
			);
		});
	});
}
