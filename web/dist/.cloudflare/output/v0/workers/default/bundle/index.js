import { createHash } from "node:crypto";
//#region src/campaign-attribution/campaign-attribution-registry.ts
var campaignChannels = [
	"x",
	"yt",
	"c"
];
var campaignCodeLength = 4;
var campaignCodeRadix = 36;
var campaignCodeSpace = campaignCodeRadix ** campaignCodeLength;
var campaignKeyPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
var serializeCampaignIdentity = (identity) => [
	identity.campaignKey,
	identity.creativeKey,
	identity.variantKey
].join("");
var assertValidRegistryKey = (label, key) => {
	if (!campaignKeyPattern.test(key)) throw new Error(`${label} must be a lowercase kebab-case registry key; received ${key}`);
};
var deriveCampaignCode = (identity) => {
	return (createHash("sha256").update(serializeCampaignIdentity(identity)).digest().readUInt32BE(0) % campaignCodeSpace).toString(campaignCodeRadix).padStart(campaignCodeLength, "0");
};
var createCampaignAttributionRegistry = (creativeDefinitions, deriveCode = deriveCampaignCode) => {
	const routes = [];
	const identityByCode = /* @__PURE__ */ new Map();
	const routeByPath = /* @__PURE__ */ new Map();
	const creativeIdentities = /* @__PURE__ */ new Set();
	for (const creativeDefinition of creativeDefinitions) {
		assertValidRegistryKey("campaignKey", creativeDefinition.campaignKey);
		assertValidRegistryKey("creativeKey", creativeDefinition.creativeKey);
		assertValidRegistryKey("variantKey", creativeDefinition.variantKey);
		const serializedIdentity = serializeCampaignIdentity(creativeDefinition);
		if (creativeIdentities.has(serializedIdentity)) throw new Error(`Duplicate campaign creative identity: ${serializedIdentity}`);
		creativeIdentities.add(serializedIdentity);
		const code = deriveCode(creativeDefinition);
		if (!/^[a-z0-9]{4}$/.test(code)) throw new Error(`Campaign code must contain exactly four lowercase base36 characters: ${code}`);
		const existingIdentity = identityByCode.get(code);
		if (existingIdentity !== void 0 && existingIdentity !== serializedIdentity) throw new Error(`Campaign code collision for ${code}: ${existingIdentity} and ${serializedIdentity}`);
		identityByCode.set(code, serializedIdentity);
		const placementChannels = /* @__PURE__ */ new Set();
		for (const placement of creativeDefinition.placements) {
			assertValidRegistryKey("placementKey", placement.placementKey);
			if (placementChannels.has(placement.channel)) throw new Error(`Duplicate ${placement.channel} placement for campaign creative ${serializedIdentity}`);
			placementChannels.add(placement.channel);
			const path = `/${placement.channel}/${code}`;
			const route = Object.freeze({
				campaignKey: creativeDefinition.campaignKey,
				channel: placement.channel,
				code,
				creativeKey: creativeDefinition.creativeKey,
				path,
				placementKey: placement.placementKey,
				variantKey: creativeDefinition.variantKey
			});
			routes.push(route);
			routeByPath.set(path, route);
		}
	}
	return Object.freeze({
		resolve: (channel, code) => routeByPath.get(`/${channel}/${code}`),
		routes: Object.freeze(routes)
	});
};
var campaignAttributionRegistry = createCampaignAttributionRegistry([{
	campaignKey: "launch-week",
	creativeKey: "launch-overview",
	placements: [
		{
			channel: "x",
			placementKey: "post"
		},
		{
			channel: "yt",
			placementKey: "description"
		},
		{
			channel: "c",
			placementKey: "generic-share"
		}
	],
	variantKey: "default"
}]);
//#endregion
//#region src/campaign-attribution/campaign-request-attribution.ts
var aggregateCampaignDimension = "__channel_aggregate__";
var aggregatePathSet = new Set(campaignChannels.map((channel) => `/${channel}`));
var resolveCampaignRequestRoute = (pathname) => {
	const creativeRoute = campaignAttributionRegistry.routes.find((route) => route.path === pathname);
	if (creativeRoute !== void 0) return {
		kind: "creative",
		route: creativeRoute
	};
	if (aggregatePathSet.has(pathname)) {
		const channel = campaignChannels.find((candidate) => `/${candidate}` === pathname);
		if (channel !== void 0) return {
			channel,
			kind: "channel-aggregate",
			path: pathname
		};
	}
	return { kind: "unknown" };
};
var createCampaignRequestDataPoint = (route) => {
	if (route.kind === "creative") return {
		blobs: [
			"creative",
			route.route.channel,
			route.route.campaignKey,
			route.route.creativeKey,
			route.route.variantKey,
			route.route.placementKey
		],
		doubles: [1],
		indexes: [route.route.path]
	};
	return {
		blobs: [
			"channel-aggregate",
			route.channel,
			aggregateCampaignDimension,
			aggregateCampaignDimension,
			aggregateCampaignDimension,
			aggregateCampaignDimension
		],
		doubles: [1],
		indexes: [route.path]
	};
};
var isCampaignRequestEligible = (request, route, response) => request.method === "GET" && route.kind !== "unknown" && response.status === 200;
//#endregion
//#region src/campaign-attribution/campaign-request-worker.ts
var writeAnalyticsBestEffort = (analytics, dataPoint) => {
	try {
		analytics.writeDataPoint(dataPoint);
	} catch {}
};
var handleCampaignRequest = async (request, environment) => {
	const route = resolveCampaignRequestRoute(new URL(request.url).pathname);
	const assetResponse = await environment.ASSETS.fetch(request);
	if (isCampaignRequestEligible(request, route, assetResponse)) writeAnalyticsBestEffort(environment.ANALYTICS, createCampaignRequestDataPoint(route));
	return assetResponse;
};
//#endregion
//#region \0virtual:cloudflare/worker-entry
var worker_entry_default = { fetch: handleCampaignRequest };
//#endregion
export { worker_entry_default as default };
