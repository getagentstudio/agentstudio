# Native binding safety: what the compiler check establishes

**The ordinary UniFFI 0.32.1 macro consumer compiles under `forbid(unsafe_code)`, but its generated implementation contains unsafe exports. That green lint does not satisfy U10's generated-code ban.** This is a bounded source/compiler observation on macOS, not an iOS binding choice or native integration result.

| Frozen input | Observed result on rustc 1.98.1 |
| --- | --- |
| Ordinary safe function under `forbid(unsafe_code)` | Compiled, exit 0 |
| Direct `#[no_mangle]` C export, edition 2021 | Refused as unsafe attribute, exit 1 |
| Direct `#[unsafe(no_mangle)]` C export, edition 2024 | Refused as unsafe attribute, exit 1 |
| Exact registry UniFFI 0.32.1, `setup_scaffolding!`, one `#[uniffi::export]` function, edition 2024, same forbid | `cargo check` exit 0; `cargo clippy --locked … -- -D warnings` exit 0; `cargo fmt … -- --check` exit 0 |

The downloaded registry macro source emits `#[unsafe(no_mangle)]` and `pub unsafe extern "C"` buffer/future wrappers in `setup_scaffolding.rs`. Those are generated in the consumer, rather than merely called through a safe dependency interface. The consumer's own function is safe; that does not remove its scaffolding's safety obligations. The registry package records source revision `35a47433d8f015302fbf608f2b395eff6972c36f`; exact resolved packages/checksums are retained in the probe lockfile.

The initial attempt did not compile: inspected upstream main advertised a feature absent from registry 0.32.1. Its dependency-resolution failure was preserved, then the unsupported feature was removed before the second run. Main and the registry release were not assumed identical.

## What this means for iOS

The current embedded-Gateway direction requires an entry from native code. The ordinary first-party C export and this generated-scaffolding candidate do not realize the literal U10 profile. The ban remains in force; no exception has been inferred from a successful build or a third-party macro's authorship.

Two possible realizations need different evidence: a genuinely external ABI host used through safe first-party interfaces must be identified and qualified, or an authorized owner must explicitly change the binding-only safety profile. Calling our own binding crate a dependency does not provide the former. This check does not prove that every possible third-party host is impossible. It also proves no Swift linking, iOS startup, runtime lifetime, cancellation or physical-device behavior. Mac socket and browser work can continue independently.

[Frozen inputs, logs, source excerpts and lockfile](../../../../../../tmp/experiments/2026-10-22-native-binding-safety/plan.md). The probe is retained locally; system-temp Cargo/build output is not durable evidence. Public source: [registry-reported setup generator revision](https://github.com/mozilla/uniffi-rs/blob/35a47433d8f015302fbf608f2b395eff6972c36f/uniffi_macros/src/setup_scaffolding.rs).
