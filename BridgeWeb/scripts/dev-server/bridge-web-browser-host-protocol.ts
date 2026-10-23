import { z } from 'zod';

export const browserHostMessageSchema = z.discriminatedUnion('kind', [
	z.object({ kind: z.literal('browserSpawned'), pid: z.number().int().positive() }),
	z.object({
		kind: z.literal('ready'),
		wsEndpoint: z.url().refine((value): boolean => value.startsWith('ws://')),
	}),
	z.object({ kind: z.literal('failed'), message: z.string() }),
]);
export type BrowserHostMessage = z.infer<typeof browserHostMessageSchema>;
