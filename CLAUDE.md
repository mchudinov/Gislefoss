# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Gislefoss is a **.NET 10 / .NET Aspire 13.1** application. The intended product (see `docs/idea.md`) is a **"Meteorologist" AI agent** that answers only weather-related questions and declines everything else. Planned stack: Microsoft Agent Framework, Azure AI Foundry, an OpenAI model, a persona loaded from an external Markdown file, with prompt-injection protection / prompt shields / content filters, deployed via Bicep.

**Current state: in-process Responses-path agent implemented; migrating to server-side persistent agent.** The agent runtime is wired: `src/Agent/Foundry/MeteorologistAgentFactory.cs` builds an in-process `AIAgent` via `AsAIAgent`, `src/Agent/Foundry/FoundryAgentRunner.cs` adapts it to the `IFoundryAgentRunner` port, DI is wired in `src/Agent/ServiceCollectionExtensions.cs`, and `src/Web/Program.cs` registers and eagerly validates the persona at boot — tests are green. The Blazor home page (`src/Web/Components/Pages/Home.razor`) is still the default "Hello, world!" stub, but a functional weather chat UI exists at `src/Web/Components/Pages/Chat.razor`. What exists: a complete persona at `src/Web/personas/gislefoss.md` (shipped to the app's output via a `Content` copy in `Web.csproj`), plus an `Agent` class library and an `Agent.Tests` xUnit project (Phases 1–5) holding value types, `AgentOptions`, run-outcome inspection, a conversation facade, the factory, the runner adapter, and DI — all built and green. There is no Bicep code yet (a Bicep plan lives under `docs/`). The project is **migrating to a server-side persistent Foundry agent**: the persona stays in git (`src/Web/personas/gislefoss.md`) and is pushed to the agent on each deploy by `infra/modules/agent.bicep`; the app retrieves the agent by id via `Settings:Agent:AgentId` (`PersistentAgentsClient.GetAIAgentAsync`). See the migration plan at `docs/superpowers/plans/2026-06-07-meteorologist-agent-foundry-server-side-migration.md`. `Azure.AI.OpenAI` 2.1.0 is referenced and `Settings` already has an `AzureOpenAI` config block. Treat `docs/idea.md` as the requirements spec, not a description of existing code.

## Commands

All projects target `net10.0` (SDK 10.0.300+). The solution file is `src/Gislefoss.slnx` (XML-format solution).

```powershell
dotnet restore src/Gislefoss.slnx
dotnet build src/Gislefoss.slnx

# Local development WITH the Aspire dashboard (orchestrates the Web app):
dotnet run --project src/AppHost          # dashboard on http://localhost:15175

# Run the Web app directly (no orchestration):
dotnet run --project src/Web              # app on http://localhost:8087
```

Tests live in `src/Agent.Tests` (xUnit), part of `src/Gislefoss.slnx`:

```powershell
dotnet test src/Gislefoss.slnx
```

## Architecture

Four projects (`src/Gislefoss.slnx`):

- **AppHost** — the .NET Aspire orchestrator (`Aspire.AppHost.Sdk/13.1.0`). `AppHost.cs` registers the Web project (`builder.AddProject<Projects.Web>("web")`). This is the entry point for local development with the dashboard. Holds the `UserSecretsId`, so user secrets attach here.
- **Web** — Blazor Server app: Razor Components with **Interactive Server** render mode, **MudBlazor** as the component library. Vendored Bootstrap/jQuery exist under `wwwroot/lib` but MudBlazor is what's actually used.
- **Library** — shared helpers: configuration-key enumeration/logging (`AllConfigurationKeys`, `LogStrings`, `OutputEnvironmentVariables`), an `AddOpenTelemetry` that wires **Azure Monitor**, and a `MapDefaultEndpoints(applicationStartTime)` that adds `/livez`, `/uptime`, and `/error`.
- **ServiceDefaults** — the standard Aspire defaults (OpenTelemetry, health checks, service discovery, HTTP resilience) exposed via `AddServiceDefaults()`.

### Important: Web bypasses the standard Aspire wiring

`src/Web/Program.cs` is a **custom** host setup, not the default minimal template, and this is the easiest thing to get wrong:

- It does **not** call `AddServiceDefaults()` and does **not** use ServiceDefaults' `MapDefaultEndpoints`. Instead it uses **Library's** `AddOpenTelemetry` and **Library's** `MapDefaultEndpoints`. So service discovery / standard resilience are not active, and the `/health` + `/alive` endpoints from ServiceDefaults are not mapped. If you need them, wire them explicitly.
- Configuration is built **manually**: `appsettings.json` + `appsettings.{DOTNET_ENVIRONMENT}.json` (optional) + environment variables. The `Settings` section is bound to the `Settings` POCO (`src/Web/Settings.cs`) and registered as a singleton; **startup throws if the `Settings` section is missing**.
- Logging is **Serilog**: a bootstrap console logger first, then the real logger read from the `Serilog` config section. At startup it logs every environment variable (Debug level) and every resolved configuration key — be mindful that secrets in config will surface in logs.

### Configuration & secrets

- Azure OpenAI settings live under `Settings:AzureOpenAI` → `Endpoint`, `ApiKey`, `DeploymentNameChat`.
- Local secrets go in **user secrets** (AppHost) or `appsettings.Development*.json`, which is **gitignored** (`appsettings.Development*.json`). Do not commit keys.
- OpenTelemetry → Azure Monitor activates only when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set (Aspire injects it locally).

### Endpoints & ports

- Web listens on **port 8087** (set in both `appsettings.json` Kestrel config and the Web `http` launch profile).
- Custom endpoints: `/livez` (liveness), `/uptime` (uptime JSON), `/info` (lists endpoints), `/error`; 404s re-execute to `/not-found`.
- Aspire dashboard runs on **localhost:15175** when launched via AppHost.

### Containerization

`src/Web/Dockerfile` builds the Web project on a chiseled .NET 10 ASP.NET base image, exposes 8087, entry point `dotnet Web.dll`. `DockerDefaultTargetOS` is Linux.
