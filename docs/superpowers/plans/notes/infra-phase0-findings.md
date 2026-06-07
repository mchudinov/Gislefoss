# Infra Phase 0 — confirmed schema findings

Recorded against subscription `AdraDevSubscription` (tenant `AdraDevDirectory`) on 2026-06-05
via **read-only** `az provider show` / `az role definition list` queries. No resources were
created. Items needing a *write* (throwaway Guardrail, portal connection) are **deferred** — they
need a deploy and are flagged `[deploy-verify]` below.

> These confirmations feed the Bicep modules. Where a value could not be confirmed read-only, the
> module keeps the plan's assumed shape and a `[verify]` marker; `az bicep build` + a real
> `what-if`/`deploy` remain the arbiters (see the plan's Provisionality caveat).

## Task 0.1 — Foundry project resource type ✅ CONFIRMED

- Projects are modeled as **`Microsoft.CognitiveServices/accounts/projects`** (child of the
  AIServices account). Confirmed present in the provider.
- **`Microsoft.Foundry` is not a valid resource namespace** in this subscription
  (`az provider show --namespace Microsoft.Foundry` → `InvalidResourceNamespace`). The plan's
  alternative does not exist — use the CognitiveServices child type.
- **Latest stable API versions** (newer than the plan's `2025-06-01`):
  - `accounts` → **`2026-03-01`**
  - `accounts/projects` → **`2026-03-01`**
  - `accounts/projects/connections` → **`2026-03-01`**

  Decision: modules use `2025-06-01` (the plan's value, safely inside the Bicep type catalog) unless
  `az bicep build` proves a newer version is needed. Bumping to `2026-03-01` is a one-line change if
  a property is missing on the older version.

## Task 0.2 — Guardrail (RAI policy) filter names + `block` ⏳ DEFERRED (`[deploy-verify]`)

- Confirming the exact `contentFilters[].name` strings for the **Jailbreak** and **Indirect Attack**
  controls requires creating a throwaway policy (a *write*), so it is not done read-only.
- The module keeps the plan's assumed names (`Jailbreak`, `Indirect Attack`) with `[verify]`. Note:
  `az provider show` lists a top-level `raiPolicy` type and `locations/raiContentFilters`; the
  conventional deployable child type is `accounts/raiPolicies` (see Task note below).

## Task 0.3 — App Insights → project connection shape ⏳ DEFERRED (`[deploy-verify]`)

- `accounts/projects/connections` **exists** as a type (latest stable `2026-03-01`), so the
  connection resource is plausible. The exact `category`/`target`/`authType` fields still need a
  portal export to confirm — deferred. The connection is **optional** (Responses-path reconcile):
  app-side tracing works via `APPLICATIONINSIGHTS_CONNECTION_STRING` regardless.

## Task 0.4 — Minimal inference RBAC role ✅ CONFIRMED (with a correction)

- **Cognitive Services User** = `a97b65f3-24c7-4388-baec-2e87135dc908` ✅
- **Azure AI Developer** = `64702f94-c441-49e6-a78b-ef80e0188fee` ✅ (broader — adds project/agent authoring)
- **Correction to the app plan + infra PR #13:** **`Azure AI User` is NOT present** in this tenant's
  role definitions (`az role definition list` returns no such role). The reconcile note in PR #13
  cited it as the escalation target — that role is unavailable here. Practical choices for the
  Responses-path inference role in this tenant are therefore:
  1. **Cognitive Services User** (account-level data-plane inference) — the default in `roles.bicep`.
  2. **Azure AI Developer** — broader fallback if a project-scoped run is denied.

  (Other `Azure AI *` roles that DO exist: Azure AI Administrator, Azure AI Developer, Azure AI
  Inference Deployment Operator, Azure AI Safety Evaluator — none is the narrow "user/inference"
  role the reconcile assumed.)

**Update (2026-06-07 — server-side migration):** RBAC now splits. The app's runtime identity keeps the least-privilege inference role (Cognitive Services User). A separate user-assigned identity used by the Bicep deployment-script provisioner gains an agent-author role (Azure AI Developer 64702f94-c441-49e6-a78b-ef80e0188fee, or "Foundry Project Manager" if narrower). See the 2026-06-07 migration plan.

## Note — provider metadata gaps (not blockers)

`az provider show --namespace Microsoft.CognitiveServices` does **not** enumerate
`accounts/deployments` or `accounts/raiPolicies` in its `resourceTypes` list, even though both are
standard deployable child types. This is a known limitation of provider-metadata enumeration for
nested types, **not** evidence the types are invalid. The modules use them; `az bicep build` (type
catalog) and a real `what-if` are the arbiters.
