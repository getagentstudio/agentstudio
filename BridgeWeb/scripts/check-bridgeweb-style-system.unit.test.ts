import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import { describe, expect, onTestFinished, test } from 'vitest';

import type { StyleSystemReport } from './check-bridgeweb-style-system-model.ts';
import {
	type CheckBridgeWebStyleSystemProps,
	checkBridgeWebStyleSystem,
} from './check-bridgeweb-style-system.ts';

const canonicalCss = `
:root {
	/* @design-primitives:start */
	--palette-canvas: #282c34;
	--palette-primary: #409cff;
	--palette-wash: rgb(255 255 255 / 0.1);
	/* @design-primitives:end */
	--background: var(--palette-canvas);
}
@layer base { button, input, textarea { font: inherit; } }
`;

const canonicalMirror = `
export const bridgeDesignPalette = {
	'--palette-canvas': '#282c34',
	'--palette-primary': '#409cff',
	'--palette-wash': 'rgb(255 255 255 / 0.1)',
} as const satisfies Readonly<Record<\`--palette-\${string}\`, string>>;
`;

describe('BridgeWeb style-system checker', () => {
	test('distinguishes renderer-internal CSS from global and slotted control styling', async () => {
		const report = await checkFixture({
			'src/app/renderer.ts': `export const options = { unsafeCSS: '[data-line] { color: var(--foreground); } [data-line] button { padding: 8px; } ::slotted(span) { color: var(--muted-foreground); }' };`,
			'src/app/global.css': `[data-line] { color: var(--foreground); }`,
		});
		expect(rulePaths(report, 'control-style-override')).toEqual([
			'src/app/global.css',
			'src/app/renderer.ts',
			'src/app/renderer.ts',
		]);
	});

	test('checks each selector branch and rejects unsupported unanchored appearance destinations', async () => {
		const report = await checkFixture({
			'src/app/unsupported-selectors.css': `
				.semantic, span { color: var(--muted-foreground); }
				[data-state="ready"] { opacity: 0.5; }
				#action-label { font-size: 9px; }
				svg { color: var(--muted-foreground); }
				strong { font-size: 9px; }
			`,
		});
		expect(rulePaths(report, 'control-style-override')).toHaveLength(5);
	});

	test('keeps comma-bearing semantic selectors and keyframe steps separate from global recipes', async () => {
		const report = await checkFixture({
			'src/app/document.css': `
				.document :where(span, code), .document [title="first, second"] { color: var(--muted-foreground); }
				@keyframes reveal { from { opacity: 0; } to { opacity: 1; } }
			`,
			'src/app/document.tsx': `export function Document() { return <article className="document"><span>Text</span><code>Code</code></article>; }`,
		});
		expect(report.ok).toBe(true);
	});

	test('allows outer composition layout without treating its child Button as the layout owner', async () => {
		const report = await checkFixture({
			'src/app/composition.tsx': `import { Button } from '@/components/ui/button.js'; export function Composition(props: { className?: string }) { return <section className={props.className}><Button>Action</Button></section>; }`,
			'src/app/consumer.tsx': `import { Composition } from './composition.js'; export function Consumer() { return <Composition className="py-2" />; }`,
		});
		expect(report.ok).toBe(true);
	});

	test('follows each styling prop to its actual destination instead of the component root', async () => {
		const report = await checkFixture({
			'src/app/wrappers.tsx': `
				import { Button } from '@/components/ui/button.js';
				type WrapperProps = { readonly className?: string; readonly style?: object };
				export function InnerControl(props: WrapperProps) {
					return <section><Button className={props.className} style={props.style}>Action</Button></section>;
				}
				export function OuterLayout({ className, style }: WrapperProps) {
					return <section className={className} style={style}><Button>Action</Button></section>;
				}
				export function MixedDestination(props: WrapperProps) {
					return <section className={props.className}><Button className={props.className}>Action</Button></section>;
				}
				export function VirtualRow({ style }: Pick<WrapperProps, 'style'>) {
					return <div style={style}><Button>Action</Button></div>;
				}
				export function LayoutLeaf({ className }: Pick<WrapperProps, 'className'>) {
					return <section className={className} />;
				}
				export function RepeatedLayout(props: Pick<WrapperProps, 'className'>) {
					return <><LayoutLeaf className={props.className} /><LayoutLeaf className={props.className} /></>;
				}
			`,
			'src/app/consumer.tsx': `
				import { InnerControl, MixedDestination, OuterLayout, RepeatedLayout, VirtualRow } from './wrappers.js';
				export function Consumer() { return <>
					<InnerControl className="text-muted-foreground" style={{ fontSize: 11 }} />
					<MixedDestination className="px-4" />
					<OuterLayout className="py-2" style={{ width: 320 }} />
					<VirtualRow style={{ height: 44, transform: 'translateY(88px)', width: '100%' }} />
					<RepeatedLayout className="py-2" />
				</>; }
			`,
		});

		expect(report.findings.filter(({ ruleId }) => ruleId === 'control-style-override')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ message: expect.stringContaining('text-muted-foreground') }),
				expect.objectContaining({ message: expect.stringContaining('fontSize') }),
				expect.objectContaining({ message: expect.stringContaining('px-4') }),
			]),
		);
		expect(
			report.findings.filter(({ ruleId }) => ruleId === 'control-style-override'),
		).toHaveLength(3);
	});

	test('revisits independent forwarding branches without mistaking them for a cycle', async () => {
		const report = await checkFixture({
			'src/app/layout.tsx': `
				export function LayoutLeaf(props: { readonly className?: string }) { return <section className={props.className} />; }
				export function RepeatedLayout(props: { readonly className?: string }) {
					return <><LayoutLeaf className={props.className} /><LayoutLeaf className={props.className} /></>;
				}
				export function Consumer() { return <RepeatedLayout className="py-2" />; }
			`,
		});

		expect(report.ok).toBe(true);
	});

	test('fails closed when styling forwarding is dynamic or cyclic', async () => {
		const report = await checkFixture({
			'src/app/cyclic-a.tsx': `
				import { CyclicB } from './cyclic-b.js';
				export function CyclicA(props: { readonly className?: string }) { return <CyclicB className={props.className} />; }
			`,
			'src/app/cyclic-b.tsx': `
				import { CyclicA } from './cyclic-a.js';
				export function CyclicB(props: { readonly className?: string }) { return <CyclicA className={props.className} />; }
			`,
			'src/app/dynamic.tsx': `
				import { Button } from '@/components/ui/button.js';
				export function Dynamic(props: { readonly className?: string; readonly asButton: boolean }) {
					const Recipient = props.asButton ? Button : 'section';
					return <Recipient className={props.className} />;
				}
			`,
			'src/app/consumer.tsx': `
				import { CyclicA } from './cyclic-a.js';
				import { Dynamic } from './dynamic.js';
				export function Consumer() { return <><CyclicA className="py-2" /><Dynamic className="py-2" asButton={false} /></>; }
			`,
		});

		expect(rulePaths(report, 'unknown-control-classes')).toEqual([
			'src/app/consumer.tsx',
			'src/app/consumer.tsx',
			'src/app/cyclic-a.tsx',
			'src/app/cyclic-b.tsx',
			'src/app/dynamic.tsx',
		]);
	});

	test('resolves named external namespace objects and finite intrinsic element aliases', async () => {
		const report = await checkFixture({
			'src/app/external-wrapper.tsx': `
				import { Widget as WidgetPrimitive } from 'external-widget';
				export function ExternalList(props: { readonly className?: string }) {
					return <WidgetPrimitive.List className={props.className} />;
				}
			`,
			'src/app/finite-element.tsx': `
				interface LayoutProps { readonly bodyClassName?: string; readonly bodyElement?: 'div' | 'section' }
				export function Layout(props: LayoutProps) {
					const BodyElement = props.bodyElement ?? 'div';
					return <BodyElement className={props.bodyClassName} />;
				}
			`,
			'src/app/consumer.tsx': `
				import { ExternalList } from './external-wrapper.js';
				import { Layout } from './finite-element.js';
				export function Consumer() { return <><ExternalList className="relative" /><Layout bodyClassName="py-2" /></>; }
			`,
		});

		expect(report.ok).toBe(true);
	});

	test('fails closed for unresolved local imports and finite aliases that may be controls', async () => {
		const report = await checkFixture({
			'src/app/finite-control.tsx': `
				interface MaybeControlProps { readonly className?: string; readonly element?: 'div' | 'button' }
				export function MaybeControl(props: MaybeControlProps) {
					const Element = props.element ?? 'div';
					return <Element className={props.className} />;
				}
			`,
			'src/app/consumer.tsx': `
				import { MissingLocal } from './missing-local.js';
				import { MaybeControl } from './finite-control.js';
				export function Consumer() { return <><MissingLocal className="py-2" /><MaybeControl className="px-4" /></>; }
			`,
		});

		expect(rulePaths(report, 'unknown-control-classes')).toContain('src/app/consumer.tsx');
		expect(report.findings).toContainEqual(
			expect.objectContaining({
				ruleId: 'control-style-override',
				message: expect.stringContaining('px-4'),
			}),
		);
	});

	test('does not lose ownership through namespace imports or local control aliases', async () => {
		const report = await checkFixture({
			'src/app/aliases.tsx': `import * as Controls from '@/components/ui/button.js'; import { Button } from '@/components/ui/button.js'; const Action = Button; export function View() { return <><Controls.Button className="text-muted-foreground"/><Action className="text-muted-foreground"/></>; }`,
		});
		expect(rulePaths(report, 'control-style-override')).toHaveLength(2);
	});

	test('rejects nested, ancestor and imported text overrides across owned content boundaries', async () => {
		const report = await checkFixture({
			'src/app/revision.tsx': `export function Revision() { return <code className="text-muted-foreground">1234</code>; }`,
			'src/app/content.tsx': `
				import { Button } from '@/components/ui/button.js';
				import { ComboboxItemDescription } from '@/components/ui/combobox.js';
				import { ItemDescription } from '@/components/ui/item-content.js';
				import { Revision } from './revision.js';
				export function Content() { return <>
				<section className="[&_button]:text-muted-foreground"><Button>Action</Button></section>
				<section className="[&_span]:text-muted-foreground"><Button><span>Enabled</span></Button></section>
				<section className="[&_code]:font-mono"><ItemDescription><code>1234</code></ItemDescription></section>
				<section className="[&_*]:text-muted-foreground"><Button>Action</Button></section>
				<Button><span className="text-muted-foreground">Action</span></Button>
				<ComboboxItemDescription className="text-foreground">Metadata</ComboboxItemDescription>
				<ItemDescription><Revision /></ItemDescription>
				</>; }
			`,
		});
		expect(rulePaths(report, 'control-style-override')).toHaveLength(7);
		expect(rulePaths(report, 'control-style-override')).toContain('src/app/revision.tsx');
	});

	test('rejects feature-local panel and card title recipes', async () => {
		const report = await checkFixture({
			'src/app/titles.tsx': `import { CardTitle, CardDescription } from '@/components/ui/card.js'; import { DrawerTitle, DrawerDescription } from '@/components/ui/drawer.js'; export function Titles() { return <><CardTitle className="text-xs"/><CardDescription className="font-medium"/><DrawerTitle className="text-muted-foreground"/><DrawerDescription className="text-foreground"/></>; }`,
		});
		expect(rulePaths(report, 'control-style-override')).toHaveLength(4);
	});

	test('keeps non-button tooltip content separate from action-button content', async () => {
		const report = await checkFixture({
			'src/app/status-tooltip.tsx': `import { TooltipTrigger } from '@/components/ui/tooltip.js'; export function Status() { return <TooltipTrigger render={<span role="img" tabIndex={0} />}><span className="text-warning">Locked</span></TooltipTrigger>; }`,
		});
		expect(report.ok).toBe(true);
	});

	test('rejects CSS selectors that bypass owned item text slots', async () => {
		const report = await checkFixture({
			'src/app/overrides.css': `[data-slot="item-label"] { color: var(--muted-foreground); }`,
		});
		expect(rulePaths(report, 'control-style-override')).toEqual(['src/app/overrides.css']);
	});

	test('links CSS descendant selectors to rendering destinations without banning semantic content', async () => {
		const report = await checkFixture({
			'src/app/descendants.css': `
				.owned-copy span { color: var(--muted-foreground); }
				.bridge-markdown-document span { color: var(--muted-foreground); }
			`,
			'src/app/composition.tsx': `
				import { Button } from '@/components/ui/button.js';
				export function Composition() { return <section><Button><span>Enabled</span></Button></section>; }
			`,
			'src/app/content.tsx': `
				import { Button } from '@/components/ui/button.js';
				import { Composition } from './composition.js';
				export function Content() { return <>
					<section className="owned-copy"><Button><span>Enabled</span></Button></section>
					<section className="owned-copy"><Composition /></section>
					<section className="[&_span]:text-muted-foreground"><Composition /></section>
					<article className="bridge-markdown-document"><span>Semantic prose</span></article>
				</>; }
			`,
		});

		expect(rulePaths(report, 'control-style-override')).toEqual([
			'src/app/content.tsx',
			'src/app/content.tsx',
			'src/app/content.tsx',
		]);
		expect(report.findings.map(({ message }) => message).join('\n')).not.toContain(
			'bridge-markdown-document',
		);
	});

	test('fails closed for native text selectors without a destination-linkable class anchor', async () => {
		const report = await checkFixture({
			'src/app/unsupported-descendants.css': `
				span { color: var(--muted-foreground); }
				#shell span { color: var(--muted-foreground); }
				[data-frame] code { font-size: 11px; }
			`,
		});

		expect(rulePaths(report, 'control-style-override')).toEqual([
			'src/app/unsupported-descendants.css',
			'src/app/unsupported-descendants.css',
			'src/app/unsupported-descendants.css',
		]);
	});

	test('rejects virtual row metrics that differ from canonical CSS', async () => {
		const report = await checkFixture(
			{
				'src/design-tokens/bridge-design-row-metrics.ts':
					'export const bridgeDesignRowMetrics = { default: 28, descriptive: 28 } as const;',
			},
			{
				cssSource: `${canonicalCss}\n:root { --row-height-default: 28px; --row-height-descriptive: 44px; }`,
			},
		);
		expect(report.ok).toBe(false);
		expect(
			report.findings.some((finding) => finding.message.includes('row-height-descriptive')),
		).toBe(true);
	});

	test('accepts canonical sources and named non-control presentation', async () => {
		const report = await checkFixture({
			'src/app/layout.tsx': `
				export const Layout = () => <section className="grid h-full gap-2 text-muted-foreground" />;
			`,
			'src/app/status.tsx': `
				export const Status = () => <span className="text-destructive size-3" />;
			`,
			'src/app/loading.tsx': `
				export const Loading = () => <div inert className="opacity-50 h-full" />;
			`,
			'src/review-viewer/code-view/pierre-metrics.ts': `
				export const pierreMetrics = { fontSize: 12, lineHeight: 16 };
			`,
		});

		expect(report).toEqual({ ok: true, findings: [] });
	});

	test('reports every raw color and bridge alias occurrence without count allowances', async () => {
		const report = await checkFixture({
			'src/app/first.ts': `export const first = '#abcdef'; export const alias = 'var(--bridge-old)';`,
			'src/app/second.css': `.one { color: #123456; } .two { --bridge-old: red; }`,
			'src/app/raw-color.unit.test.ts': `export const fixture = '#fedcba';`,
		});

		expect(rulePaths(report, 'raw-color')).toEqual([
			'src/app/first.ts',
			'src/app/second.css',
			'src/app/second.css',
		]);
		expect(rulePaths(report, 'bridge-alias')).toEqual(['src/app/first.ts', 'src/app/second.css']);
	});

	test('fails a same-count palette replacement and duplicate mirror keys', async () => {
		const report = await checkFixture(
			{},
			{
				mirrorSource: canonicalMirror
					.replace("'--palette-primary': '#409cff'", "'--palette-accent': '#409cff'")
					.replace(
						"'--palette-wash': 'rgb(255 255 255 / 0.1)'",
						"'--palette-canvas': 'rgb(255 255 255 / 0.1)'",
					),
			},
		);

		expect(report.findings.filter(({ ruleId }) => ruleId === 'palette-parity')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ message: expect.stringContaining('duplicate') }),
				expect.objectContaining({ message: expect.stringContaining('--palette-primary') }),
				expect.objectContaining({ message: expect.stringContaining('--palette-accent') }),
			]),
		);
	});

	test('detects appearance branches but not Pierre dark and light theme object keys', async () => {
		const report = await checkFixture({
			'src/app/theme.tsx': `
				export const pierreThemes = { dark: theme, light: theme };
				const appearanceRecipe = 'dark:bg-background';
				export const View = () => <div className={appearanceRecipe} />;
			`,
			'src/app/theme.css': `
				.dark .panel { color: var(--foreground); }
				@media (prefers-color-scheme: dark) { .panel { display: block; } }
			`,
		});

		expect(rulePaths(report, 'appearance-conditional')).toEqual([
			'src/app/theme.css',
			'src/app/theme.css',
			'src/app/theme.tsx',
		]);
	});

	test('follows aliased control imports and shared class constants through cn conditionals', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/control-styles.ts': `
				export const dangerousControlClassName = 'h-8 text-sm hover:bg-accent';
			`,
			'src/app/action.tsx': `
				import { Button as ActionControl } from '../components/ui/button.js';
				import { dangerousControlClassName as sharedRecipe } from './control-styles.js';
				import { cn } from '../lib/utils.js';
				export const Action = ({ active }: { active: boolean }) => (
					<ActionControl className={cn(sharedRecipe, active && 'border-primary')} />
				);
			`,
		});

		expect(report.findings.filter(({ ruleId }) => ruleId === 'control-style-override')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ message: expect.stringContaining('h-8') }),
				expect.objectContaining({ message: expect.stringContaining('hover:bg-accent') }),
				expect.objectContaining({ message: expect.stringContaining('border-primary') }),
			]),
		);
	});

	test('detects local wrappers and compound Base UI render buttons', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/wrappers.tsx': `
				import { Button } from '../components/ui/button.js';
				export function ViewerAction(props: { className?: string }) {
					return <Button {...props} />;
				}
			`,
			'src/app/view.tsx': `
				import { ViewerAction as ImportedViewerAction } from './wrappers.js';
				export const View = () => (
					<>
						<ImportedViewerAction className="rounded-xl px-4" />
						<Menu.Trigger render={<button className="h-7 bg-primary" />} />
					</>
				);
			`,
		});

		expect(
			report.findings.filter(({ ruleId }) => ruleId === 'control-style-override'),
		).toHaveLength(4);
	});

	test('classifies explicit compound controls and floating frames without taking layout ownership', async () => {
		const report = await checkFixture({
			'src/components/ui/dropdown-menu.tsx': `
				export const DropdownMenuCheckboxItem = () => null;
				export const DropdownMenuRadioItem = () => null;
				export const DropdownMenuContent = () => null;
			`,
			'src/components/ui/toggle-group.tsx': `
				export const ToggleGroup = () => null;
				export const ToggleGroupItem = () => null;
			`,
			'src/components/ui/combobox.tsx': `export const ComboboxItem = () => null;`,
			'src/app/compound-controls.tsx': `
				import { DropdownMenuCheckboxItem, DropdownMenuContent, DropdownMenuRadioItem } from '../components/ui/dropdown-menu.js';
				import { ToggleGroup, ToggleGroupItem } from '../components/ui/toggle-group.js';
				import { ComboboxItem } from '../components/ui/combobox.js';
				export const View = () => <>
					<DropdownMenuCheckboxItem className="text-blue-600" />
					<DropdownMenuRadioItem className="h-9" />
					<ToggleGroup className="rounded-xl" />
					<ToggleGroupItem className="self-end px-4" />
					<ComboboxItem className="hover:bg-red-500" />
					<DropdownMenuContent className="w-80 h-[50vh] translate-x-2 data-[swipe-axis=x]:[--bleed:0px] data-[swipe-axis=x]:[--drawer-content-width:min(384px,calc(100%_-_32px))] bg-black shadow-xl" />
				</>;
			`,
		});

		expect(report.findings).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					ruleId: 'raw-color',
					message: expect.stringContaining('blue-600'),
				}),
				expect.objectContaining({
					ruleId: 'raw-color',
					message: expect.stringContaining('red-500'),
				}),
				expect.objectContaining({
					ruleId: 'raw-color',
					message: expect.stringContaining('bg-black'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('h-9'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('rounded-xl'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('px-4'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('shadow-xl'),
				}),
			]),
		);
		expect(report.findings.map(({ message }) => message).join('\n')).not.toMatch(
			/w-80|h-\[50vh\]|translate-x-2|self-end|--bleed|--drawer-content-width/u,
		);
	});

	test('checks inline control styles and native role buttons while preserving layout width', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/inline-styles.tsx': `
				import { Button } from '../components/ui/button.js';
				export const View = () => <>
					<Button style={{ width: 240, fontSize: 99, backgroundColor: 'var(--primary)' }} />
					<div role="button" className="h-9 bg-primary" style={{ marginLeft: 4, borderRadius: 12 }} />
				</>;
			`,
		});

		expect(report.findings.filter(({ ruleId }) => ruleId === 'control-style-override')).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ message: expect.stringContaining('fontSize') }),
				expect.objectContaining({ message: expect.stringContaining('backgroundColor') }),
				expect.objectContaining({ message: expect.stringContaining('h-9') }),
				expect.objectContaining({ message: expect.stringContaining('bg-primary') }),
				expect.objectContaining({ message: expect.stringContaining('borderRadius') }),
			]),
		);
		expect(report.findings.map(({ message }) => message).join('\n')).not.toMatch(
			/width|marginLeft/u,
		);
	});

	test('checks canonical CSS control declarations outside the base reset', async () => {
		const report = await checkFixture(
			{},
			{ cssSource: `${canonicalCss}\nbutton { font-size: 99px; }` },
		);

		expect(report.findings).toContainEqual(
			expect.objectContaining({
				ruleId: 'control-style-override',
				relativePath: 'src/app/bridge-app.css',
			}),
		);
	});

	test('resolves custom CSS classes used by controls and fails unknown custom recipes closed', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/control-recipes.css': `.painted-action { color: var(--primary); padding: 4px; }`,
			'src/app/custom-control.tsx': `
				import { Button } from '../components/ui/button.js';
				export const View = () => <>
					<Button className="painted-action flex ml-2 w-full" />
					<Button className="unresolved-action" />
				</>;
			`,
		});

		expect(report.findings).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('painted-action'),
				}),
				expect.objectContaining({
					ruleId: 'unknown-control-classes',
					message: expect.stringContaining('unresolved-action'),
				}),
			]),
		);
		expect(report.findings.map(({ message }) => message).join('\n')).not.toMatch(
			/flex|ml-2|w-full/u,
		);
	});

	test('inspects unsafeCSS strings for raw and conditional appearance while permitting Pierre metrics', async () => {
		const report = await checkFixture({
			'src/review-viewer/code-view/options.ts': `
				export const options = {
					unsafeCSS: '.dark .line { color: #abcdef; } @media (prefers-color-scheme: light) { .line { display: block; } } .virtualizer { transform: translateY(4px); }',
				};
			`,
		});

		expect(report.findings).toEqual(
			expect.arrayContaining([
				expect.objectContaining({ ruleId: 'raw-color' }),
				expect.objectContaining({
					ruleId: 'appearance-conditional',
					message: expect.stringContaining('.dark'),
				}),
				expect.objectContaining({
					ruleId: 'appearance-conditional',
					message: expect.stringContaining('prefers-color-scheme'),
				}),
			]),
		);
		expect(report.findings.map(({ message }) => message).join('\n')).not.toContain('transform');
	});

	test('fails closed for unknown dynamic control classes', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/action.tsx': `
				import { Button } from '../components/ui/button.js';
				export const Action = ({ recipe }: { recipe: string }) => <Button className={recipe} />;
			`,
		});

		expect(report.findings).toContainEqual(
			expect.objectContaining({
				ruleId: 'unknown-control-classes',
				relativePath: 'src/app/action.tsx',
			}),
		);
	});

	test('checks interpolated template heads, middles, and tails for literal policies', async () => {
		const report = await checkFixture({
			'src/app/template-policies.ts': `
				const value = 'resolved';
				export const first = \`#abcdef \${value} var(--bridge-middle)\`;
				export const second = \`var(--bridge-head) \${value} rgb(1 2 3)\`;
			`,
		});

		expect(rulePaths(report, 'raw-color')).toEqual([
			'src/app/template-policies.ts',
			'src/app/template-policies.ts',
		]);
		expect(rulePaths(report, 'bridge-alias')).toEqual([
			'src/app/template-policies.ts',
			'src/app/template-policies.ts',
		]);
	});

	test('resolves unsafeCSS identifiers and cva variant output for appearance policy', async () => {
		const report = await checkFixture({
			'src/app/appearance.tsx': `
				import { cva } from 'class-variance-authority';
				const embeddedPierreCss = '.dark .line { color: var(--foreground); }';
				export const options = { unsafeCSS: embeddedPierreCss };
				const appearanceVariants = cva('', {
					variants: { appearance: { dark: 'dark:bg-background', fixed: 'bg-background' } },
				});
				export const View = () => <div className={appearanceVariants({ appearance: 'dark' })} />;
			`,
		});

		expect(rulePaths(report, 'appearance-conditional')).toEqual([
			'src/app/appearance.tsx',
			'src/app/appearance.tsx',
		]);
	});

	test('inspects static styling spreads, rejects unknown styling spreads, and preserves typed attribute-only spreads', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/spread-controls.tsx': `
				import { Button } from '../components/ui/button.js';
				const staticStylingProps = { className: 'h-9 bg-primary', style: { borderColor: 'red' } };
				type AttributeOnlyProps = { readonly 'aria-label': string; readonly 'data-testid'?: string };
				type StylingProps = { readonly className?: string };
				export const View = (props: AttributeOnlyProps) => <Button {...props} />;
				export const StaticStyle = () => <Button {...staticStylingProps} />;
				export const UnknownStyle = (props: StylingProps) => <Button {...props} />;
			`,
		});

		expect(report.findings).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('h-9'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('bg-primary'),
				}),
				expect.objectContaining({
					ruleId: 'unknown-control-classes',
					message: expect.stringContaining('spread'),
				}),
				expect.objectContaining({ ruleId: 'raw-color' }),
			]),
		);
		expect(
			report.findings.filter(({ ruleId }) => ruleId === 'unknown-control-classes'),
		).toHaveLength(1);
	});

	test('proves Omit rest spreads exclude both styling properties and fails when style returns', async () => {
		const report = await checkFixture({
			'src/components/ui/button.tsx': `export function Button() { return null; }`,
			'src/app/typed-wrapper.tsx': `
				import { Button } from '../components/ui/button.js';
				type PrimitiveProps = { className?: string; style?: object; disabled?: boolean };
				interface SafeProps extends Omit<PrimitiveProps, 'className' | 'style'> { label: string }
				interface UnsafeProps extends Omit<PrimitiveProps, 'className'> { label: string }
				export function Safe(props: SafeProps) {
					const { label, ...attributes } = props; return <Button {...attributes}>{label}</Button>;
				}
				export function Unsafe(props: UnsafeProps) {
					const { label, ...attributes } = props; return <Button {...attributes}>{label}</Button>;
				}
			`,
		});

		expect(rulePaths(report, 'unknown-control-classes')).toEqual(['src/app/typed-wrapper.tsx']);
	});

	test('detects named CSS colors only in CSS and style contexts', async () => {
		const report = await checkFixture({
			'src/app/named-colors.css': `.message { color: rebeccapurple; }`,
			'src/app/named-colors.tsx': `
				export const ordinaryStatus = 'red';
				export const View = () => <section style={{ borderColor: 'aliceblue' }} />;
				export const options = { unsafeCSS: '.line { background: papayawhip; }' };
			`,
		});

		expect(rulePaths(report, 'raw-color')).toEqual([
			'src/app/named-colors.css',
			'src/app/named-colors.tsx',
			'src/app/named-colors.tsx',
		]);
	});

	test('classifies expression role controls and fails dynamic roles closed', async () => {
		const report = await checkFixture({
			'src/app/role-controls.tsx': `
				type DynamicRoleProps = { readonly role: string };
				export const MenuItem = () => <div role={'menuitem'} className="h-9 bg-primary" />;
				export const DynamicRole = (props: DynamicRoleProps) => <div role={props.role} />;
			`,
		});

		expect(report.findings).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('h-9'),
				}),
				expect.objectContaining({
					ruleId: 'control-style-override',
					message: expect.stringContaining('bg-primary'),
				}),
				expect.objectContaining({
					ruleId: 'unknown-control-classes',
					message: expect.stringContaining('role'),
				}),
			]),
		);
	});

	test('restricts direct palette imports and CSS variable reads to canonical homes and theme adapters', async () => {
		const report = await checkFixture({
			'src/app/bridge-viewer-tree-theme.ts': `
				import { bridgeDesignPalette } from '../design-tokens/bridge-design-palette.js';
				export const treeBackground = bridgeDesignPalette['--palette-canvas'];
			`,
			'src/review-viewer/code-view/bridge-code-view-theme.ts': `
				import { bridgeDesignPalette } from '../../design-tokens/bridge-design-palette.js';
				export const codeBackground = bridgeDesignPalette['--palette-canvas'];
			`,
			'src/app/unauthorized-theme.ts': `
				import { bridgeDesignPalette } from '../design-tokens/bridge-design-palette.js';
				export const background = bridgeDesignPalette['--palette-canvas'];
			`,
			'src/app/unauthorized.css': `.panel { color: var(--palette-primary); }`,
		});

		expect(rulePaths(report, 'palette-direct-read')).toEqual([
			'src/app/unauthorized-theme.ts',
			'src/app/unauthorized-theme.ts',
			'src/app/unauthorized.css',
		]);
	});

	test('rejects unlayered control font resets while accepting the base-layer reset', async () => {
		const report = await checkFixture(
			{},
			{
				cssSource: canonicalCss.replace(
					'@layer base { button, input, textarea { font: inherit; } }',
					'button, input, textarea { font: inherit; }',
				),
			},
		);

		expect(report.findings).toContainEqual(
			expect.objectContaining({ ruleId: 'unlayered-control-reset' }),
		);
	});

	test('sorts duplicated diagnostics and reports parse and read failures by deterministic path', async () => {
		const packageRootPath = await writeFixtureTree({
			'src/app/bridge-app.css': canonicalCss,
			'src/design-tokens/bridge-design-palette.ts': canonicalMirror,
			'src/app/z-broken.tsx': `export const Broken = <div`,
			'src/app/a-broken.css': `.broken { color:`,
		});
		await writeFileAt(packageRootPath, 'src/app/unreadable.ts', 'export const value = 1;');

		const report = await checkBridgeWebStyleSystem({ packageRootPath, readFile: readFixtureFile });

		expect(report.findings.map(({ relativePath }) => relativePath)).toEqual(
			report.findings.map(({ relativePath }) => relativePath).toSorted(),
		);
		expect(rulePaths(report, 'evaluation-failure')).toEqual([
			'src/app/a-broken.css',
			'src/app/unreadable.ts',
			'src/app/z-broken.tsx',
		]);
	});
});

async function checkFixture(
	files: Readonly<Record<string, string>>,
	overrides: { readonly cssSource?: string; readonly mirrorSource?: string } = {},
): Promise<StyleSystemReport> {
	const packageRootPath = await writeFixtureTree({
		'src/app/bridge-app.css': overrides.cssSource ?? canonicalCss,
		'src/design-tokens/bridge-design-palette.ts': overrides.mirrorSource ?? canonicalMirror,
		...files,
	});
	return checkBridgeWebStyleSystem({ packageRootPath });
}

async function writeFixtureTree(files: Readonly<Record<string, string>>): Promise<string> {
	const packageRootPath = await mkdtemp(join(tmpdir(), 'bridge-style-system-'));
	onTestFinished(async (): Promise<void> => {
		await rm(packageRootPath, { recursive: true, force: true });
	});
	await joinFixtureOperations(
		Object.entries(files).map(async ([relativePath, sourceText]) => {
			await writeFileAt(packageRootPath, relativePath, sourceText);
		}),
	);
	return packageRootPath;
}

async function writeFileAt(
	rootPath: string,
	relativePath: string,
	sourceText: string,
): Promise<void> {
	const filePath = join(rootPath, relativePath);
	await mkdir(dirname(filePath), { recursive: true });
	await writeFile(filePath, sourceText);
}

function rulePaths(
	report: Awaited<ReturnType<typeof checkBridgeWebStyleSystem>>,
	ruleId: string,
): readonly string[] {
	return report.findings
		.filter((finding) => finding.ruleId === ruleId)
		.map(({ relativePath }) => relativePath);
}

void ({} satisfies CheckBridgeWebStyleSystemProps);

async function readFixtureFile(filePath: string): Promise<string> {
	if (filePath.endsWith('unreadable.ts')) {
		throw new Error('synthetic read failure');
	}
	return (await import('node:fs/promises')).readFile(filePath, 'utf8');
}

// Test-finish cleanup must not race any allocation, write, or assertion already started.
async function joinFixtureOperations(operations: readonly Promise<unknown>[]): Promise<void> {
	let firstFailure: { readonly reason: unknown } | undefined;
	await Promise.allSettled(
		operations.map((operation) =>
			operation.catch((reason: unknown): never => {
				firstFailure ??= { reason };
				throw reason;
			}),
		),
	);
	if (firstFailure !== undefined) throw firstFailure.reason;
}
