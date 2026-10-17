# Remote boxes and the daemon: problem statement

Status: draft for discussion · 2026-09-26 · orchestrator (Claude, worktrees session)
Inputs pending: research lanes in `tmp/research-workflows/2026-09-26-fast-worktrees/` (search, change tracking, gh, daemon prior art); the Astra 🦉 advisor's stepping-stone review.
Prior art: `docs/architecture/archive/remote_zmx_architecture_ideas.md` (archived; recommended SSH Unix-socket forwarding). **Superseded by owner direction (2026-09-26): the transport is not SSH socket forwarding; it will likely be Mosh-like** (UDP, roaming, state sync). See "Transport".

## Goal

Agents should be able to run **anywhere**: on this Mac, on a persistent dev box, or on a box we provision. From Agent Studio you should still see and steer all of it in one place.

Agent Studio and agentstudio-git were built for a single machine. This document keeps four concerns apart, so each can grow on its own, and then defines how they communicate.

```text
 ┌─ 1 READ (observe) ─┐  ┌─ 2 ACT on a machine ─┐  ┌─ 3 PROGRAMMABLE ─────┐  ┌─ 4 DAEMON ─────────┐
 │ what exists and    │  │ terminals, git ops,  │  │ agents drive the app │  │ a per-machine host  │
 │ what changed:      │  │ clone/create/fork,   │  │ like a user: typed   │  │ for 1 and 2, speaks │
 │ repos, worktrees,  │  │ launch agent session │  │ commands + events    │  │ 3's contract        │
 │ sessions, PR state │  │                      │  │                      │  │                     │
 └────────────────────┘  └──────────────────────┘  └──────────────────────┘  └─────────────────────┘
```

## The model

```text
 BOX (machine)         this Mac · persistent box · provisioned box
  └─ REPO              identified by remote URL (+ path on that box)
      └─ WORKTREE      a checkout; what you navigate to
          ├─ SESSIONS  agent runs (Claude, Codex, …): status, hooks, "needs you"
          └─ PANES     views: terminal (zmx), Review, Files
```

"Agents" are **sessions**. Every session runs in one worktree on one box.

## Clients and hosts (owner direction: a client could be a phone)

The Mac app is **one client among several**, not the hub. **Daemons (one per box, including this Mac) are the hosts and the source of truth.** Clients connect to them.

```text
 CLIENTS (view + steer)                     HOSTS (source of truth, one daemon per box)
 ┌ Agent Studio.app (Mac) ┐                 ┌ this-Mac daemon ┐  ┌ box A daemon ┐  ┌ box B daemon ┐
 │ Phone app             │ ◄── transport ──►│ inventory · git │  │ same          │  │ same          │
 │ CLI / agents (local)  │                  │ zmx · sessions  │  │               │  │               │
 └───────────────────────┘                  └─────────────────┘  └───────────────┘  └───────────────┘
                              (a relay/rendezvous may be needed: phones and boxes behind NAT)
```

What a phone client implies:
- **Latest-state sync is the default** (roaming, sleep, loss): inventory, session status, terminal screen.
- **"Needs you" becomes a push notification.** The daemon (or a relay) must be able to wake a sleeping client.
- **Per-device auth**: pair a phone, revoke it, and scope what it may do (read-only vs control).
- **Reachability**: phones and most boxes are behind NAT, so direct UDP may need a **relay or rendezvous** (open).
- **No heavy client logic.** Clients render facts and send commands; derivation stays on the host.

## 1. Reading: what the app observes

| Fact family | Local today | Remote (proposed) |
|---|---|---|
| Inventory: repos and worktrees under watched folders | FSEvents, then watched-folder scan (RepoScanner), then topology atom | the box daemon watches its own watched folders and **reports inventory facts** |
| Git state: branch, HEAD, dirty, line counts | agentstudio-git through the git projector (admission and backoff) | the box daemon runs git locally and **reports git facts** |
| Sessions: agent status, hooks, notifications | IPC v2 session reports and provider hooks | the same reports, **relayed** by the box daemon and tagged with box and worktree |
| Remote/GitHub state: PRs, checks | `gh` calls (inventory pending, research lane 3) | the box's own `gh`; the app merges results by repo identity |

The rule: **the app reads facts; it does not run git or fs watching on another machine.** Local facts and remote facts use the same shape. The UI shows one tree, with a box badge on remote items.

## 2. Acting on a machine

| Action | Local today | Remote (proposed) |
|---|---|---|
| Terminal (PTY, persistence) | Ghostty surface plus zmx session | zmx on the box, carried by the Mosh-like transport's latest-state channel |
| Create / fork worktree | agentstudio-git (APFS fork, clean create) | box daemon; fork capability depends on the box (APFS / reflink / none) |
| Clone repo@ref | none | box daemon, using **the box's credentials** (its own `gh` / SSH keys) or forwarded access (open question) |
| Launch an agent session | user or agent in a terminal | box daemon starts the session in a worktree and reports it |

Every action is a **command** that returns an **operation id** and later a **completion fact** (created path, or a typed failure). There are no synchronous remote calls on the UI path.

## 3. App programmable for agents

The IPC v2 typed catalog is the control surface. It already has commands, `events.subscribe`, session reports, credentials and a bundled CLI. To make it fully programmable:
- every user-visible verb is an `AppCommand` with an IPC classification (already the rule);
- **targets** name box › repo › worktree › pane (today there is no `.worktree` handle and no box);
- long operations are **async**: operation id plus completion event;
- privileges cover repository mutation (gap G8 today);
- **the same catalog works on every box**. Agents on a remote box use the box-local socket with the same CLI and hooks they use on the Mac.

## 4. What a daemon does

```text
 box daemon = HOST for 1 + 2, SPEAKS 3
   watches    watched folders → inventory facts; git state → git facts
   runs       git ops (clone/create/fork), zmx sessions, agent launches
   relays     box-local agents' session reports → upward
   answers    capabilities hello, inventory snapshot on connect, then changes
   owns       nothing UI; no AppKit; restart-safe
```

## How communication happens

```text
            ┌──────────────── this Mac ────────────────┐
 CLI/agents │ SOCKET 1  local control (IPC v2, exists)   │
 ─────────► │        Agent Studio.app  (hub + UI)        │
            │ SOCKET 2  one per box (new)                │
            │   ◄── Mosh-like transport (UDP, roaming) ┐ │
            └──────────────────────────────────────────┼─┘
            ┌──────────────── remote box ─────────────┼─┐
 CLI/agents │ box-local socket (same IPC as socket 1)  │ │
 ─────────► │        box daemon ───────────────────────┘ │
            └────────────────────────────────────────────┘
```

Socket 2 carries these channels on one connection:

| Channel | Direction | Carries |
|---|---|---|
| Hello | box → app, first | box id, OS, capabilities (fork kind, zmx version, `gh` auth state) |
| Inventory | box → app | a snapshot on connect, then change facts |
| Control | app → box | commands; operation id, then completion fact |
| Session relay | box → app | box-local session reports and hooks, tagged with box and worktree |
| Terminal | both ways | terminal screen state (zmx on the box) |

- **Wire format:** JSON, as NDJSON (the IPC v2 framing). The **contract is the IPC v2 catalog**, extended with box targets, inventory facts and capabilities. Drift between languages is caught by golden fixtures (a Swift and a Rust daemon both decode and encode the same examples).
## Transport: Mosh-like (owner direction)

Mosh syncs **state**, not bytes: over UDP, it roams across networks, survives loss and sleep, and sends the latest screen instead of every byte. It is usually bootstrapped over SSH (start the server, exchange a key). It does **not** carry arbitrary sockets, so socket 2's channels split by the delivery they need:

| Delivery kind | Semantics | Channels | Why |
|---|---|---|---|
| **Latest-state sync** (Mosh-style) | only the newest state matters; drops and reordering are fine; resync on reconnect | terminal screen, inventory snapshot, session status ("needs you") | a stale intermediate state is worthless; roaming-friendly |
| **Reliable ordered** | every message delivered once, in order, acknowledged | control commands, operation ids, completion facts, session hook events, audit | a lost "create worktree" or "completed" must never happen silently |

Candidate substrates to evaluate (open): extend the Mosh SSP idea with a reliable side-channel; **QUIC**, which has reliable streams, unreliable datagrams and connection migration (roaming) in one authenticated UDP connection; or Mosh for terminals plus a separate reliable channel. Whichever is chosen, the **message contract** (the IPC catalog in JSON) stays the same; only the carrier differs.

Auth (open): bootstrap identity (SSH-style key exchange, like Mosh), then per-session keys; box identity and capability allow-lists on the app side.

## Stepping-stone candidates (for the advisor to challenge)

1. **Local inventory as facts.** Worktree added, removed, HEAD moved, dirty: emitted by the local pipeline as typed facts that search and the sidebar consume. This covers PR 2 and change tracking, and it is the exact shape remote inventory will use.
2. **Worktree handle, async operations and G8 in IPC.** Expose the worktree creation commands with a worktree/repo target, an operation id and a completion fact.
3. **Box identity in the model.** Local is box "this-mac"; ids carry the box.
4. **Capabilities hello.** Even locally: the app asks and the host answers (fork kind, zmx).
5. **First remote slice.** Read-only: a persistent box daemon sends inventory and session relay over the chosen transport. There is no control yet.
6. **Then control:** create worktree and launch session on the box. Then clone with credentials.

## Open questions

1. **Remote OS:** Linux too, or macOS only? This decides the fork capability (reflink) and daemon portability.
2. **Daemon language:** Rust, firm or a maybe? It decides whether it shares code with agentstudio-git (no, if Rust) or only the contract (yes).
3. **Mac daemon timing:** with phone clients the long-term answer is yes (daemons are hosts; the Mac app is a client). Open: when, and does the app keep an in-process host until then?
4. **Credentials:** the box's own `gh`/SSH identities, or access forwarded from the Mac? How is the per-repo GitHub account modelled?
5. **Trust:** what a box may report or do. Should facts from a box be treated as untrusted input?
6. **Reachability and push:** a relay/rendezvous for NAT'd boxes and phones; how "needs you" wakes a sleeping phone.
7. **Transport:** Mosh SSP extension vs QUIC vs Mosh plus a separate reliable channel; bootstrap and auth.
8. **Ownership:** the IPC program (workspace-control / ipc-improvements) owns the catalog. The worktrees track feeds requirements for inventory facts and worktree commands.
