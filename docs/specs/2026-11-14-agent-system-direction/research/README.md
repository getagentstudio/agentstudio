# Research for the agent-system direction

These notes supply checked evidence to the preliminary design. They do not select a terminal backend, replace the existing requirements, authorize implementation or establish runtime compatibility. The document author owns Requirements, Specification, Program Design and Verification Design; these files remain supporting research.

Research date: 14 November 2026 local time. Public reads continued into 15 November UTC.

## Read by question

| Question | Evidence and remaining gap |
| --- | --- |
| Can Rex and ZMX sit behind our terminal interface? | [Terminal backends](terminal-backends.md): creation, attachment, control, input and process custody have different meanings and evidence. |
| Can the existing native renderer display a Rex terminal without a Ghostty fork? | [Renderer boundary](ghostty-renderer-boundary.md): native embedding and standalone VT APIs are different. The conversion route is a hypothesis, not a working integration. |
| What changes in the wider architecture are settled? | [Integration constraints](integration-constraints.md): preserve source attribution, the Central conflict, mobile proposals and the limits of existing continuity evidence. |
| Which old domain/increment documents are still needed? | [Old domain map](old-domain-map.md): filename inventory and brief-level retention triage, with no qualified deletion. |
| How do machines connect without a separately installed VPN? | [Networking](networking.md): Tailscale, Iroh/noq, Nebula, alternatives and Cloudflare, separating discovery, relaying, encryption and membership. Source research only. |

## Inspected source versions

| Source | Inspected revision |
| --- | --- |
| AgentStudio worktree | `36bba3c5bb20903f47c4e294c60c04d015c20339` |
| Bundled Ghostty | `83fb95624b0439ee660c2679b43b38c8b63769cd` |
| Bundled ZMX | `35693380d1c1f6107065e52592b1bc874688bc89` |
| Herdrex | `8bab18ef035a326ead3a93fc5afec159f1b2d88f` |
| coder/ghostty-web | `640db4617c69a73ccebce437cebc598c7f73cdb7` |

Local heads were rechecked during the source walk. Public API/guide pages are dated observations of live documentation, not selected dependency pins or guarantees about an installed Rex binary.

## Reading the claims

- **Source observation:** the named code or declarations were inspected. It does not mean that path was executed.
- **Published contract:** official documentation states the behavior. It still needs qualification on the intended product version and deployment.
- **Inference or candidate:** an engineering consequence or possible integration route, explicitly separated from observed behavior.
- **Open:** neither the owner nor the evidence has settled the question.

The latest owner statements available directly to this session support exploring the server direction and a common Rex/ZMX interface while retaining AgentStudio's useful UX. Additional quotations relayed by the parallel Claude author are identified in the integration note; recommendations in that relay are not owner selections.

## Scope and limits

This walk covered current local terminal code and governing constraints, official Rex/Ghostty/WebKit documentation, and selected public Herdrex/ghostty-web source. It did not run Rex, ZMX, a PTY, an agent provider, a native renderer, an iOS build or a Host upgrade. No product files, dependencies, services or old documents were changed by this research.

The existing daemon Advisor supplied a bounded source-only second look. Its decisive code anchors were checked by the Lead. This was advice, not a formal independent design review or runtime verification. Process receipts, queries, failed lookups and exact advisory dispositions are in the [research ledger](../../../../tmp/practices-research/2026-11-14-rex-direction/research-ledger.md). The owner will run Fable's independent validation personally; neither agent dispatches that validation.
