import { cva, type VariantProps } from 'class-variance-authority';
import * as React from 'react';

import { cn } from '@/lib/utils';

const alertVariants = cva(
	"group/alert relative grid w-full gap-0.5 rounded-lg border px-2 py-1.5 text-left text-xs/relaxed grid-cols-1 has-data-[slot=alert-action]:grid-cols-[minmax(0,1fr)_auto] has-[>svg]:grid-cols-[auto_minmax(0,1fr)] has-data-[slot=alert-action]:has-[>svg]:grid-cols-[auto_minmax(0,1fr)_auto] has-[>svg]:gap-x-1.5 *:[svg]:row-span-2 *:[svg]:translate-y-0.5 *:[svg]:text-current *:[svg:not([class*='size-'])]:size-3.5",
	{
		variants: {
			layout: {
				card: '',
				banner: 'rounded-none border-x-0 border-t-0',
				floating: 'w-fit shadow-popover',
				inline: 'rounded-none border-0 bg-transparent',
			},
			variant: {
				default: 'bg-card text-card-foreground',
				floating: 'border-popover-border bg-popover text-popover-foreground',
				warning: 'border-warning/35 bg-warning/10 text-foreground *:[svg]:text-warning',
				destructive:
					'bg-card text-destructive *:data-[slot=alert-description]:text-destructive/90 *:[svg]:text-current',
			},
		},
		defaultVariants: {
			layout: 'card',
			variant: 'default',
		},
	},
);

function Alert({
	className,
	variant,
	layout,
	...props
}: React.ComponentProps<'div'> & VariantProps<typeof alertVariants>): React.ReactElement {
	return (
		<div
			data-slot="alert"
			role="alert"
			className={cn(alertVariants({ variant, layout }), className)}
			{...props}
		/>
	);
}

function AlertTitle({ className, ...props }: React.ComponentProps<'div'>): React.ReactElement {
	return (
		<div
			data-slot="alert-title"
			className={cn(
				'col-start-1 font-medium group-has-[>svg]/alert:col-start-2 [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground',
				className,
			)}
			{...props}
		/>
	);
}

function AlertDescription({
	className,
	...props
}: React.ComponentProps<'div'>): React.ReactElement {
	return (
		<div
			data-slot="alert-description"
			className={cn(
				'col-start-1 text-sm text-balance text-muted-foreground group-has-[>svg]/alert:col-start-2 md:text-pretty [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground [&_p:not(:last-child)]:mb-4',
				className,
			)}
			{...props}
		/>
	);
}

function AlertAction({ className, ...props }: React.ComponentProps<'div'>): React.ReactElement {
	return (
		<div
			data-slot="alert-action"
			className={cn(
				'col-start-2 row-start-1 row-span-2 self-start group-has-[>svg]/alert:col-start-3',
				className,
			)}
			{...props}
		/>
	);
}

export { Alert, AlertTitle, AlertDescription, AlertAction };
