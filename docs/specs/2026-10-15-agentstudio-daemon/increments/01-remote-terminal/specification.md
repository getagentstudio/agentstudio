# I1 — Remote-terminal MVP integrated into AgentStudio

**Candidate first product increment.** The user can view and control continuing remote execution through the real AgentStudio app. This profile is proposed for owner confirmation; exact method names, controller-handoff/trust/platform/restoration details and its structural realization remain incomplete.

Basis: U1/U6/U7–U12/U14/U17–U19; execution-continuity part of U15; R1–R8/R11–R13 and relevant authority/data distinctions. Complete U15 agent/fact coverage remains I2, not silently claimed by a shell-only milestone. DS01/02/03/04/09/10/11 contribute; none is completed wholesale by I1.

## Visible journey and contract boundaries

| User step | Observable obligation | Failure or decision to preserve |
| --- | --- | --- |
| Select/reach a Host | Frontend access goes Swift→socket→Mac Gateway→addressed Mac/Linux Host | Invalid/ambiguous/unavailable target never redirects to another Host |
| Establish/access execution | Host owns backend establishment independently of Swift | Prepared handle, accepted start, established process and attach-ready are different observations |
| Open terminal view | Real Ghostty surface receives selected restored state plus ordered continuing output | No dropped/duplicated VT continuation hidden by a matching text screenshot |
| Type, send control or resize | Actual child effect follows the selected input/controller/viewport/focus contract | Native handoff/transport acceptance does not prove child consumption; no unsafe input replay |
| Close final pane/app | Ending the attachment leaves the execution continuing | Existing pane/Undo cleanup cannot become implicit target termination; no timer default selected |
| Return/reconnect | Same execution can be accessed through the supported route | Connection replacement, attachment identity and restoration cut need explicit profiles |
| Explicitly terminate | A separate authorized operation reports the actual observed termination boundary | Sending kill or losing a socket is not proof of process extinction/cleanup |

## App and backend integration

Current native entry: `WorkspaceSurfaceCoordinator.prepareTerminalSurfaceStartup` → `SurfaceManager` → `GhosttySurfaceView` command configuration → local `zmx attach`. Proposed entry: that owning surface/startup integration binds a Gateway-backed terminal attachment through a qualified PTY-facing relay; Host owns its ZMX adapter and execution readiness. Native display/input remain in the client. The [structural workbench](../../designs/11-operations-integration/program-design-workbench.md#the-terminal-integration-path) shows the proposal and its feasibility gaps.

The [lifecycle realization](../../designs/04-terminal-runtime/execution-lifecycle-design.md) details how client view/Undo cleanup must cease to be an implicit execution-retirement owner, including the old queued-work cutover case. It changes no observable obligation or selected profile in this increment.

Control DTOs, terminal buffers and source facts are separate lanes. A Host-directed request carries Host-qualified session intent and an admitted caller context. Stream/ticket binding is tied to that admitted attachment. The exact framing, schemas, handshake and restoration/controller outcomes must be fixed in the contributing contracts before implementation can invent them.

## Dependencies that block closure

- I0's real native-output, restoration/continuation and Swift/socket feasibility results.
- Session establishment/readiness, termination, detach/reattach identity and controller/focus policy in DS04.
- Actual pairing/auth/origin/scope admission and supported Mac/Linux/backend resource profiles in DS01/03/11.
- Any persistence/lease profile this implementation requires; deferred central-server work does not permit a temporary Gateway issuer.
- Explicit handling of current installed session identities and app cleanup/cutover. No live-session replacement or compatibility bridge is selected here.

## What proves this increment

The real app, Rust Gateway, real Mac and Linux Host realizations and ZMX backend must be identified and exercised. Observe a known terminal corpus and continuation, actual input/resize/query replies under the selected policy, final-view/app/Gateway absence with independently continuing workload, reconnect and explicit termination. Exercise both target isolation and declared failure/unknown/refusal cases, bounded slow viewers and the selected version matrix. Real cross-language Unix-socket schemas and separate remote compatibility are mandatory. No mock, same-codec roundtrip, surviving shell alone or standalone echo substitutes.

Many-to-many identities are structural inputs from the start. Whole U16/U18 closure needs actual multiple Gateways/Hosts and isolation proof; a one-box demonstration is not the whole system. Git/agent/review/storage-sharing features outside I1 remain explicit later profiles.
