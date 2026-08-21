# Custodia — Greeting & suggested prompts

Paste these into the agent's **Settings → Greeting & prompts** in Copilot Studio.
Changes here take effect after you save and publish the agent.

## Greeting message

```
Hi, I'm Custodia — I help set up and run Microsoft Purview eDiscovery searches
for FOIA requests. I can list and create cases, build searches, and estimate
item counts. I can't export data, apply legal holds, or decide what's
responsive — that's always your call. What would you like to do?
```

## Suggested prompts

Read-only prompts are listed first so a new reviewer's first click is a safe,
silent action. The create/build prompts intentionally trigger the agent's
restate-and-confirm flow; the last one demos the safety-scope explanation.

| Title | Message |
| --- | --- |
| Cases I can see | What eDiscovery cases do I have access to? |
| Case details | Show me the details of a case |
| Searches in a case | List the searches in a case |
| Create a case | Create a new eDiscovery case |
| Build & estimate | Build a search and estimate item counts |
| What I can/can't do | What can you and can't you do? |

## Why reads don't prompt for permission, but "Allow this agent to proceed?" still shows up once per tool

Two different confirmation mechanisms are at play, and it's easy to conflate them:

1. **`x-openai-isConsequential` in `connector/apiDefinition.swagger.json`** — controls
   Microsoft 365 Copilot's own plugin-confirmation UI. All read operations (and
   `estimateStatistics`) are marked `false`; the 10 real write operations are marked
   `true`. This is what keeps a reviewer from being asked to confirm `ListCases` on
   every single call.
2. **The Copilot Studio "Permission Required — Allow this agent to proceed?" card** —
   this is Microsoft Entra ID's on-behalf-of (OBO) connector consent, documented at
   [Configure OBO authentication for custom connectors](https://learn.microsoft.com/en-us/microsoft-copilot-studio/advanced-custom-connector-on-behalf-of).
   It is unrelated to `x-openai-isConsequential` and cannot be turned off by a swagger
   flag — by design, the agent must ask the reviewer's own identity for a token before
   it can act as them. Expect this once **per distinct tool**, the first time it's used
   in a session (e.g., once for `ListCases`, once for `ListSearches`, once for
   `CreateCase`, etc.) — not once per call.

If the same tool keeps re-prompting instead of staying silent after the first
"Allow," the connector's OAuth **Scope** field is most likely missing
`offline_access`, so Entra ID isn't issuing a refresh token and the short-lived
access token expires between calls. `connector/apiProperties.json` in this repo
already includes it:

```json
"scopes": [
  "eDiscovery.ReadWrite.All",
  "User.Read",
  "offline_access"
]
```

If you edited the connector's Security tab by hand instead of importing this
file, double-check the **Scope** field is **space-separated**, not
comma-separated — `eDiscovery.ReadWrite.All User.Read offline_access` — since
a malformed scope string can silently prevent the refresh token from being
issued at all.

Verified directly against the live agent: in a fresh conversation, a tool used
for the first time prompts once; the same tool used again later in that
session — including after the earlier access token would otherwise have
expired — runs silently once `offline_access` is present.

## Allow vs. Deny on the "Permission Required" card

- **Allow** grants the connector a token scoped to **that one tool**, for
  **that reviewer**, for **that session** — it is not a standing grant to
  every tool, and it is not shared with any other reviewer. Approving
  `ListCases` does not pre-approve `CreateSearch`.
- **Deny** stops that specific call. Custodia reports that it could not
  complete the action — per the "Never fabricate" rule in
  `agent/instructions.md`, it will not retry silently, substitute a different
  identity, or claim the action succeeded. Denying one tool does not block
  the others; a reviewer who denies `CreateSearch` can still use `ListCases`
  normally in the same conversation.
- Neither Allow nor Deny changes what the reviewer can see. The token, once
  granted, is still bounded by that reviewer's own Purview eDiscovery role —
  Allow cannot grant access to a case the reviewer's role doesn't already
  permit.

