# Follow real AgentStudio workflows

These are walkthroughs of the proposed system, not recordings of implemented remote features. Each starts with a user action and ends with the distinction between a backend result and what the UX client actually displays. Open the named presentation to move through the steps.

## Remote terminal

### Choose a machine and session

The UX client identifies a Host and a continuing execution session. The Gateway routes to that Host. Host identity is part of the target; an unavailable Host must not silently redirect the operation to another machine.

### Establish execution without a viewer

The Host session owner establishes or discovers the qualified terminal backend and records the selected session state. Creating a handle, establishing execution and committing registry state are separate outcomes. Starting an execution must not require an UX client window or attachment. The current ZMX boundary and its renderer-free sources need the recorded backend experiments.

### Attach and render

The UX client requests an attachment through the Gateway. The Host binds that attachment to the continuing execution and delivers restoration/live terminal data. The Gateway transports the stream; the UX client's terminal renderer displays it. Restoration must hand off to live output in order. A snapshot and live bytes cannot be joined by assuming nothing changed between them.

### Type and resize

Input travels back to the Host's attachment/backend boundary. The initial profile selects one input/resize controller with other attachments viewing; merely viewing from a phone does not take control. Actual acquisition/handoff and focus rules still need their contract. Reliable bytes, bounded queues and truthful input uncertainty matter; a transport choice does not make uncertain keystrokes safe to resend.

### Close and return

Closing the UX client pane detaches the view while execution continues on the Host. A new connection and attachment can return to the same execution. Explicit termination, natural exit and backend failure are separate. The Host acquires selected execution/agent facts independently of whether a viewer is attached.

### Integrate and prove the whole terminal feature

The proposed first terminal slice needs the Host backend adapter, Gateway routing/stream handling, typed UX client socket adapter and native renderer/input path together. Its planned proof includes real input/output, two attachments, detach/reconnect, ordered restore/live delivery and bounded slow-viewer behavior. The existing increment is a proposal, not a product approval or passing run.

## Create a worktree

### Choose the creation mode

The UX client supplies the addressed Host, repository, branch and creation intent. Current interactive behavior distinguishes a new worktree from the default branch, one from a selected branch and a fork of current files. The separate typed command wrapper currently refuses some creation names; its refusal must not be mistaken for the interactive feature being absent.

### Validate and create on the Host

The Gateway routes the operation. The Host resolves and validates the destination, applies the selected application policy and invokes the Git mechanics boundary. Current app creation excludes concurrent work on the same destination and holds the destination out of discovery during mutation. Complete fork behavior includes Git administration, HEAD/index/files and the supported metadata/name profile; a file-clone benchmark alone is insufficient.

### Reconcile success and failure

Current creation releases the publication hold and rescans the owning watched folder after success or failure. The proposed Host owner must account for that reconciliation, including partial residue. Cancellation, failed cleanup and unsupported Linux profiles need truthful outcomes. A successful row or transport response is not proof that every filesystem effect completed.

### Prepare the repository view

The Gateway consumes admitted operation/inventory information and prepares the appropriate repository/sidebar view. Completion of Git work, admission of refreshed discovery and delivery to a subscriber are separate milestones. A copied database observation cannot retroactively authorize the operation.

### Apply the result in the UX client

The UX client publishes the prepared update and performs any selected local follow-up, such as opening an actual pane. The Host does not own native window focus. Launch-after-create behavior and its failure/result contract remain explicit design work, rather than an automatic consequence of creation success.

### Integrate and prove the whole worktree feature

The feature needs the Host application policy and Git adapter, complete Mac/Linux counterpart, Gateway prepared inventory and native interaction together. Proof must observe actual refs/index/files, discovery, failure residue and supported platform profiles. See the full worktree specification and worksheet; no Fly or product probe was run by this walkthrough.

## Review an annotated diff

### Read the addressed source

The UX client selects the Host, worktree and comparison. The Host reads the actual Git/file source and prepares qualified finite content. Source revision, comparison selection, stale/error and empty results remain distinct. The Gateway prepares authorized file/review observations; the UX client hosts the viewer.

### Publish the view and track actual viewing

The UX client applies a prepared review to its actual viewer. Source acquisition, candidate preparation, native publication and user viewing remain separate. A background delivery cannot mark the review viewed merely because bytes arrived. Completed-agent viewed sharing is settled. Whether review-file and annotation viewed marks join that set is still the scoped question with Sun. If included, their subject mapping, source coverage, authority and sync/conflict semantics need explicit contracts.

### Edit and save annotations

The UX client or declared editor owner holds the live edit buffer. Admitted annotation operations reach the Host's workflow owner, where current revisions and edit custody govern saved state. Draft acquisition, flush, save, revert and thread/session changes have different outcomes; they cannot all be treated as one generic replicated mutation.

### Prepare an exact output attempt

The Host annotation workflow prepares the selected immutable output bytes and attempt metadata. The Gateway routes and exposes the authorized result. Inspecting an attempt proves what its content is; it does not prove clipboard or file output occurred. A repeat must follow the selected explicit workflow rather than a blind transport retry.

### Perform the destination effect

The addressed UX client performs an actual native clipboard, folder-choice, reveal or other selected client effect and reports its outcome. Host-local file effects remain at their declared machine. A remote path is not automatically a usable Mac or phone URL. The Host records admitted finalization separately from the external effect, including failed or uncertain outcomes.

### Integrate and prove the whole review feature

The feature combines Host source/workflow ownership, Gateway content/views and native viewer/editor/output. Proof must observe source currentness, exact saved revisions, prepared bytes and the actual destination effect. Durable history/export scope and output authority remain their recorded decisions. The 16 Bridge calls and 22 nested annotation kinds are linked detail, not 38 independent product features.
