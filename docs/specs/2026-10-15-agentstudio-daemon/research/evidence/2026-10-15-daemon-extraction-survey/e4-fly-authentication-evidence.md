# E4a authentication evidence: login, logout and credential retirement

Date: 2026-10-15. Source-only G9/M3 follow-up. Accepted flyctl pin: `v0.4.115`, commit `a1cf49a52b36fba66a2bf0907617bd5aadb8a727`. The Lead supplied two claims for independent checking: isolated-directory login is owner-blocked; logout revokes the newly created server token. Neither is an observed result in this task.

No CLI execution, login/logout, authentication attempt, token output, private config read/copy, browser/provider-state inspection, authenticated request, build/test, product edit, board action or helper occurred. The sole write is this report. Public source availability does not establish current credentials, owner availability or credential retirement.

## Disposition

- **Owner-blocked login: unproved.** The pinned CLI has browser, PKCE loopback/completion-code and email/password/OTP paths with explicit conditions. Source cannot tell whether the current browser is signed in, whether approval is already possible, which execution surface is available, or whether an actual owner action is needed. An isolated `FLY_CONFIG_DIR` is a local-state selection, not evidence of those facts.
- **Logout merely clears local state: refuted for ordinary successful logout at this pin.** It explicitly tries to revoke the saved login token and requires a positive API result before clearing local state. However, `--force`, no saved token, an overriding supplied token, failure or a lost reply can make a blanket “credential retired” claim false.
- **A new login token is retired: unproved until its actual saved-token identity, API outcome and local disposition are correlated.** No token was created or retired here. No replacement-token choice or authentication policy is selected.

## Three decisive primary source units

All links below are at the accepted pin; the units are bounded call graphs, not a version catalog.

| Unit | Sources and exact anchors | Establishes |
| --- | --- | --- |
| A1 — Login and selected local state | [login.go:19–105,145–186](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/auth/login.go#L19-L105); [webauth.go:26–89,127–215](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/auth/webauth/webauth.go#L26-L89); [pkce.go:40–72,141–205](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/auth/webauth/pkce.go#L40-L72); [pending.go:20–56,98–137](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/auth/webauth/pending.go#L20-L56); [helpers/config.go:8–20](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/helpers/config.go#L8-L20); [state.go:43–59](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/state/state.go#L43-L59) | Mode dispatch, browser/callback conditions, pending-login persistence, token-save order and config-directory selection. |
| A2 — Saved-token logout and local clear | [logout.go:23–87,95–119,122–151](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/auth/logout.go#L23-L119); [GraphQL LogOut:197–201](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/gql/genqclient.graphql#L197-L201); [config/file.go:20–44,105–114](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/config/file.go#L20-L44) | Saved-token-specific API logout, checked `ok`, force/failure distinction, subsequent local clearing and agent-stop attempt. |
| A3 — Other revocation targets and local session-age gate | [tokens/revoke_supplied.go:18–86](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/tokens/revoke_supplied.go#L18-L86); [tokens/revoke.go:14–52](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/tokens/revoke.go#L14-L52); [command.go:46–48,589–632,637–700](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/command/command.go#L589-L632); [config.go:119–152](https://github.com/superfly/flyctl/blob/a1cf49a52b36fba66a2bf0907617bd5aadb8a727/internal/config/config.go#L119-L152) | Separate externally supplied/limited-token revocation paths; credential precedence; the CLI's local 30-day reauthentication gate rather than a proved server token expiry. |

## Login: exact call path and interaction conditions

`runLogin(ctx context.Context) error` chooses:

1. Nonempty `--code`: `webauth.RedeemPendingLogin(ctx, code)`, followed by `SaveToken`, then pending-login completion cleanup.
2. `--interactive` or a supplied email/password/OTP flag: `runShellLogin`. Missing required email/password values require interactive prompting or produce a noninteractive error; optional OTP absence can proceed. This calls `fly.GetAccessToken`.
3. Otherwise: `webauth.RunWebLogin(ctx, false)`, then `SaveToken`.

No separate `--no-browser` login flag appears in the pinned command. Browser login calls `open.Run(auth.URL)`. Failure to open prints a manual URL route; successful opening does not prove browser sign-in or approval.

The current browser flow defines headless as stdin not being a TTY. Headless CI returns an immediate error. PKCE setup tries a loopback listener; headless mode refuses to start without that listener. An interactive terminal can instead receive a pasted completion code. The login request sends a PKCE challenge/state and optional loopback port, then starts a CLI session. A headless connection to a legacy non-PKCE server is explicitly refused.

When the server supports PKCE, the client can persist private pending-approval material under the selected config directory with mode `0600`. `auth login --code` can redeem that pending login after browser approval, including when the browser is elsewhere or the first command stopped. It needs that pending state and the approved completion code; those are not assumed available. Interrupted, not-yet-expired logins can retain pending state for this purpose. The waiting-login bound is 15 minutes; it is a browser/session-approval lifetime, not evidence that an issued access token expires after 15 minutes.

`SaveToken(ctx, token)` attempts to stop the default agent, calls `config.Clear` (its error is not checked in this function), persists the token, persists a login timestamp, then queries the current user before printing success. A failure after token persistence can therefore leave an issued/saved token despite an overall login error. Token issuance, local persistence, success output and retirement are distinct observations.

`FLY_CONFIG_DIR` is a supported directory override. `state.ConfigFile` derives its selected config from that directory; pending-login state also uses the selected directory. The initial state/config preparation remains subject to its actual filesystem and host permissions. No current directory, stored token, browser session, network permission or approval result was inspected.

## Logout: exact target and failure meanings

`runLogout` calls `revokeSavedToken(ctx, selectedConfigPath)`. That helper reads the saved login token and creates a client specifically using it, rather than revoking an external token that happens to override it for normal calls. It issues:

```graphql
mutation LogOut {
  logOut(input: {}) {
    ok
  }
}
```

No error plus `resp.LogOut.Ok == true` is the client's accepted revocation receipt. A false `ok` is an error. The client source does not implement the server mutation, so propagation/session semantics beyond the returned acceptance are not independently established here.

| Observed branch in a future invocation | Source meaning |
| --- | --- |
| Revocation fails, no `--force` | Return an error before clearing the saved token, retaining it for a later retry. No retirement claim. |
| Revocation fails with `--force` | Clear local state and explicitly warn that the token remains valid remotely. This is local removal, not server revocation. |
| Revocation accepted, local clear succeeds | Clear saved access/metrics token values, login timestamp, cached WireGuard state and app-secret-version cache. Then attempt to stop the agent; an agent-stop failure is a warning rather than a reversal of revocation. |
| Revocation accepted, local clear fails | Return a local-clear error; server acceptance and local residue remain separate facts. |
| No saved token | No revocation request for a saved token; local clear can still run and report absence. Absence does not identify or retire any independently issued token. |

Logout warns that externally supplied tokens remain set and are not revoked or removed by this saved-token path. Clearing local cached WireGuard state is not proof that every remote WireGuard peer was deleted. `config.Clear` performs local persistence only; server revocation is the separate `LogOut` operation.

## Other supported retirement/expiry paths, without choosing one

- `tokens revoke supplied` targets the selected flag/environment token (including a bundle according to its command contract), invokes `LogOut`, and requires API `ok`. Its source priority is explicit flag, then the first selected environment source. It does not clear local configuration or unset environment values. No supplied credential was read or selected here.
- `tokens revoke ID...` calls `RevokeLimitedAccessToken` for each supplied ID. It prints individual failures but ultimately returns nil; shell exit alone is not proof that every requested ID was revoked. This is a distinct limited-token interface, not evidence that it identifies the new saved login token.
- `RequireSession` enforces a local age gate from the saved login timestamp (30 days) or asks for reauthentication when no timestamp exists. Externally supplied tokens bypass that local age gate. Automatic re-login prompting requires an interactive non-CI invocation without output/no-prompt flags, followed by confirmation; otherwise it returns an authentication error. These conditions differ from an explicit `auth login` invocation.
- Neither the local 30-day gate nor the 15-minute pending-login window establishes the actual newly issued token's server-side expiry, scope, revocation propagation, validity in another client, or whether another independent credential remains active. Those facts require the relevant authenticated/server observation, outside this assignment.

## Proof boundaries and closure

DeepWiki was used first for pointers, then all decisive facts above were read at the exact pin. Its simplified logout account did not capture the saved-token-specific target, checked `ok`, force behavior, or newer PKCE/code flow; the pinned source controls this report. No unrelated primary source unit was added.

Supported source conclusions: browser approval is a flow condition; selected-directory persistence is explicit; normal successful logout attempts server revocation of the saved token; force/local clearing is weaker; supplied-token and limited-token interfaces differ. Unresolved current facts: owner availability, existing browser authorization, host permission to perform a login, token identity/state, actual server responses, and credential retirement. They cannot be inferred from source or from the existence of an isolated state directory.

This closes the bounded source check, not M3 runtime authentication. The Lead can avoid both unsupported claims: do not label the task owner-blocked without a concrete unavailable owner action, and do not label a credential retired without its correlated revocation/local-state outcome. No authentication method or token policy was selected.
