import { z } from 'zod';

import type { BridgeProductSurface } from './bridge-product-contract-primitives.js';

export const bridgeProductMetadataApplicationKindSchema = z.string().min(1);

export interface BridgeProductMetadataApplicationProtocolIdentity {
	readonly kind: string;
	readonly surface: BridgeProductSurface;
}

export interface BridgeProductMetadataApplicationProtocol<
	TKind extends string,
	TOptions,
	TOpen extends { readonly subscriptionKind: TKind },
> extends BridgeProductMetadataApplicationProtocolIdentity {
	readonly kind: TKind;
	readonly openSchema: z.ZodType<TOpen>;
	readonly optionsSchema: z.ZodType<TOptions>;
	readonly surface: BridgeProductSurface;
	initialOpen(options: TOptions): TOpen;
}

export function defineBridgeProductMetadataApplicationProtocol<
	const TKind extends string,
	const TSurface extends BridgeProductSurface,
	TOptions,
	TOpen extends { readonly subscriptionKind: TKind },
>(
	protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen> & {
		readonly surface: TSurface;
	},
): BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen> & {
	readonly surface: TSurface;
} {
	return Object.freeze(protocol);
}

export type BridgeProductMetadataApplicationKind<
	TProtocol extends BridgeProductMetadataApplicationProtocolIdentity,
> = TProtocol['kind'];

export type BridgeProductMetadataApplicationOptions<
	TProtocol extends BridgeProductMetadataApplicationProtocolIdentity,
> =
	TProtocol extends BridgeProductMetadataApplicationProtocol<
		string,
		infer TOptions,
		{ readonly subscriptionKind: string }
	>
		? TOptions
		: never;

export type BridgeProductMetadataApplicationOpen<
	TProtocol extends BridgeProductMetadataApplicationProtocolIdentity,
> =
	TProtocol extends BridgeProductMetadataApplicationProtocol<string, unknown, infer TOpen>
		? TOpen
		: never;

export interface BridgeProductMetadataApplicationRegistration extends BridgeProductMetadataApplicationProtocolIdentity {
	readonly protocol: BridgeProductMetadataApplicationProtocolIdentity;
	validateOpen(open: unknown): { readonly subscriptionKind: string };
}

export function registerBridgeProductMetadataApplicationProtocol<
	const TKind extends string,
	TOptions,
	TOpen extends { readonly subscriptionKind: TKind },
>(
	protocol: BridgeProductMetadataApplicationProtocol<TKind, TOptions, TOpen>,
): BridgeProductMetadataApplicationRegistration {
	return Object.freeze({
		kind: protocol.kind,
		protocol,
		surface: protocol.surface,
		validateOpen: (open: unknown) => protocol.openSchema.parse(open),
	});
}

export class BridgeProductMetadataApplicationRegistry {
	readonly #registrationByKind: ReadonlyMap<string, BridgeProductMetadataApplicationRegistration>;

	constructor(registrations: readonly BridgeProductMetadataApplicationRegistration[]) {
		const registrationByKind = new Map<string, BridgeProductMetadataApplicationRegistration>();
		for (const registration of registrations) {
			if (registrationByKind.has(registration.kind)) {
				throw new Error(`Duplicate Bridge product metadata application: ${registration.kind}.`);
			}
			registrationByKind.set(registration.kind, registration);
		}
		this.#registrationByKind = registrationByKind;
	}

	get registeredKinds(): readonly string[] {
		return Object.freeze([...this.#registrationByKind.keys()]);
	}

	lookup(kind: string): BridgeProductMetadataApplicationProtocolIdentity {
		return this.#registration(kind).protocol;
	}

	validateOpen(kind: string, open: unknown): { readonly subscriptionKind: string } {
		return this.#registration(kind).validateOpen(open);
	}

	#registration(kind: string): BridgeProductMetadataApplicationRegistration {
		const registration = this.#registrationByKind.get(kind);
		if (registration === undefined) {
			throw new Error(`Unknown Bridge product metadata application: ${kind}.`);
		}
		return registration;
	}

	requireProtocol<TProtocol extends BridgeProductMetadataApplicationProtocolIdentity>(
		protocol: TProtocol,
	): TProtocol {
		if (this.#registrationByKind.get(protocol.kind)?.protocol !== protocol) {
			throw new Error(`Unregistered Bridge product metadata application: ${protocol.kind}.`);
		}
		return protocol;
	}
}
