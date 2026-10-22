# Direct Bridge delivery through the Gateway

Start with [one bootstrap and content read](program-design.md#one-bootstrap-and-content-read), then [what a browser may do](specification.md#browser-access-and-identity). This slice separates native control, browser delivery and remote Host communication. It does not migrate all Bridge workflows at once.

## Four document identities

| Document | Source |
| --- | --- |
| Requirements | Existing [U25, U3, U17 and U19](../../../user-requirements.md#requirement-rows), with [S32](../../../research/owner-inputs/bridge-transport-direction-2026-10-22.md) |
| Specification | [Observable boundary](specification.md): E27 and R18–R23 |
| Program Design | [Owners, typed interfaces and lifetimes](program-design.md) |
| Verification Design | [Native/browser and remote qualification](verification-design.md) |

## Reading paths

- **Understand direct content delivery:** [need](../../../user-requirements.md#requirement-rows) → [R18](specification.md#delivery-and-native-control) → [one read](program-design.md#one-bootstrap-and-content-read) → [T1 proof](verification-design.md#t1-actual-macos-webview-to-rust).
- **Understand browser authority:** [U25 source](../../../research/owner-inputs/bridge-transport-direction-2026-10-22.md) → [E27/R19](specification.md#browser-access-and-identity) → [access state and schema](program-design.md#browser-access-and-schema) → [negative controls](verification-design.md#t1-actual-macos-webview-to-rust).
- **Understand mobile lifetime:** [U12/U17](../../../user-requirements.md#requirement-rows) → [R21](specification.md#platform-lifetime) → [mobile state transitions](program-design.md#mobile-lifetime) → [T2 device proof](verification-design.md#t2-physical-ios-lifetime).
- **Understand the remote leg:** [U3/U25](../../../user-requirements.md#requirement-rows) → [R20](specification.md#remote-host-communication) → [Host adapter boundary](program-design.md#components-and-dependencies) → [T3 proof](verification-design.md#t3-actual-gateway-to-host-transport).

The existing [Bridge operation map](../../../designs/08-files-review-output/bridge-operation-map.md), [annotation map](../../../designs/08-files-review-output/annotation-operation-map.md) and [native/client read needs](../../../designs/08-files-review-output/client-read-needs.md) remain the feature vocabulary. The larger [migration map](../../../designs/11-operations-integration/migration-map.md) owns the strangler sequence.
