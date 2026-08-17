# Screenshot shot list

The install guide (`docs/FOIAIQ-Install-Guide.pptx`) and the README leave labeled
placeholders for screenshots. They are **placeholders on purpose** — every screen in this
setup lives inside *your* tenant's admin portals and would show tenant IDs, secrets, role
assignments, or real case data. Those must never be committed to a shared repository.

Capture the shots below **from your own tenant**, redact anything sensitive (see the rules at
the bottom), and drop them into `docs/screenshots/` using the exact file names given here. The
three numbered shots are the ones the PowerPoint references directly.

---

## Required — referenced by the PowerPoint

These three appear as placeholder frames in `FOIAIQ-Install-Guide.pptx`. Replace each frame
with the matching image.

| # | File name | Portal | What to capture |
|---|-----------|--------|-----------------|
| **1** | `01-entra-api-permissions.png` | Entra admin center → App registrations → *your app* → **API permissions** | The permissions list showing **eDiscovery.ReadWrite.All** and **User.Read** as **Delegated**, each with a green **“Granted for &lt;tenant&gt;”** status. This is the shot that proves consent succeeded and that there are **no application permissions**. |
| **2** | `02-connector-security.png` | Power Platform → Custom connectors → *your connector* → **Security** tab | The OAuth 2.0 settings filled in — identity provider Microsoft Entra ID, Resource URL `https://graph.microsoft.com`, and **Enable on-behalf-of login = On**. **Blank out the Client secret field before capturing.** |
| **3** | `03-copilot-studio-agent.png` | Copilot Studio → *your FOIAIQ agent* | The agent open with the instructions pasted and the custom connector's actions listed under **Tools / Actions**. The FOIAIQ avatar as the icon is a nice touch to include. |

---

## Recommended — for the README walkthrough

Optional but they make the README much easier to follow. Same folder, same naming convention.

| File name | Portal | What to capture |
|-----------|--------|-----------------|
| `04-entra-expose-api.png` | Entra → App registrations → *your app* → **Expose an API** | The `access_as_user` scope, and the **Azure API Connections** app pre-authorized under **Authorized client applications**. |
| `05-entra-redirect-uri.png` | Entra → App registrations → *your app* → **Authentication** | The **Web** platform with the connector's generated redirect URL pasted in. |
| `06-connector-test.png` | Power Platform → Custom connectors → *your connector* → **Test** tab | A successful `ListCases` test call returning **200** (redact any real case names in the response body). |
| `07-purview-role-group.png` | Purview portal → **Roles & scopes** → **Role groups** | The **eDiscovery Manager** role group with a reviewer added as a member. |
| `08-agent-share.png` | Copilot Studio → *your FOIAIQ agent* → **Share** | The share dialog granting a reviewer access to the published agent. |
| `09-agent-preview.png` | Copilot Studio → *your FOIAIQ agent* → **Test / Preview** | A short conversation: “list my cases”, then a create request where the agent **restates and waits** for confirmation. The single best shot for showing the agent in action. |

---

## Redaction rules — read before you capture

Anything you put in `docs/screenshots/` may end up shared with the customer. Before saving each
image, remove or blur:

- **Tenant ID, Client ID, Object ID, and any `api://…` identifier.**
- **The client secret** — never capture it at all; blank the field first.
- **Redirect URLs** that contain your environment/region GUIDs (blur the host if unsure).
- **Real people** — reviewer names, email addresses, UPNs, and profile photos. Use test
  accounts with obviously synthetic names.
- **Real case data** — case names, custodian names, item counts, KQL that reveals a real
  request. Use a clearly-marked non-production case (e.g. `FOIA-TEST-001`) seeded with
  synthetic content.

A quick blur or a solid rectangle over the sensitive value is enough. When in doubt, leave it
out — a slightly cropped screenshot is always safer than a leaked identifier.

## After you add the images

The PowerPoint placeholders are static frames, so replacing them is a manual step in
PowerPoint: open `FOIAIQ-Install-Guide.pptx`, delete the dashed placeholder on the Phase 1–3
slides, and **Insert → Picture** the matching file. The README images render automatically
once the files exist at the referenced paths.
