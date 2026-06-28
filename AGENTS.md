# AGENTS.md

This file defines the required workflow for agents working in `C:\dev\BombBattles`.

## Core Rule

- Treat the local Rojo project as the source of truth for code.
- Treat Roblox Studio, accessed through the MCP server, as the source of truth for non-code content.
- Do not mix those ownership boundaries unless this file explicitly allows it.
- Use the converted EmitModule in `src/game/ReplicatedStorage/Packages/EmitModule` for all VFX-related emit behavior. Do not hand-roll alternate emit helpers or direct particle/beam/trail emission flows unless the current task explicitly requires replacing this module.
- For ability creation or ability changes, follow `docs/AbilityAuthoring.md`. Bias ability work toward client-side input, previews, VFX, SFX, UI, and feel; keep the server focused on state, validation, and authoritative gameplay outcomes.
- Player-owned movement must stay client-owned. For knockback, launches, pulls, and air impulses that affect a real player character, the server should validate and send a compact motion intent to the affected player's client; that client applies the physical velocity/impulse. Keep server-side physical movement for NPCs, bots, durable world objects, and validated gameplay outcomes.
- Throwable/projectile visuals should start immediately on the throwing client and reconcile to server validation. The server remains authoritative for cooldowns, damage, hit eligibility, scoring, round state, replay records, and durable world changes.

## Local Filesystem / VS Code Only

Use the local filesystem for all normal code work and all heavy code edits.

The following are local-code-owned by default:

- `src/game/ReplicatedStorage`
- `src/game/ServerScriptService`
- `src/game/StarterPlayer`
- script files under `src/game/StarterGui` when code changes are needed there
- `default.project.json`
- project-level documentation and workflow files such as `AGENTS.md` and `README.md`

When a task is about refactoring, bug fixing, implementing features, changing logic, updating module APIs, or editing scripts, do that work locally.

## Studio MCP Only

Use the Studio MCP server for all non-code Roblox content and all live-game validation work.

The following are Studio-owned by default:

- asset instances
- UI instances and their hierarchy/layout
- models
- animations
- sounds
- VFX
- map and world content
- instance properties and attributes
- tags
- placement and transforms
- folders and non-code hierarchy organization
- playtesting
- runtime inspection and validation
- asset relocation and asset cleanup

This project is intentionally code-first for Rojo ownership. `GameAssets` and world/place content should be treated as Studio/MCP-managed content, not as local code edits.

## Hard Prohibitions

- Do not edit scripts directly in Studio if the same script is Rojo-managed locally.
- Do not use MCP for heavy code edits or normal code edits.
- Do not use the local filesystem to author, move, or reorganize Studio-owned non-code assets.
- Do not turn Studio-owned asset trees into Rojo-managed folders unless the user explicitly asks for that migration.
- No visual assets should live in Rojo-managed code; visual assets should live in Studio-managed `GameAssets` so they replicate correctly.

## Default Workflow

1. Inspect the relevant local code and Studio state.
2. For ability work, read `docs/AbilityAuthoring.md` before planning or implementation.
3. For requested systems, behavior changes, Roblox engine issues, or unfamiliar implementation details, search online for related Roblox DevForum and Reddit threads before committing to an approach.
4. Make script and code changes locally in the Rojo project.
5. Use Studio MCP for assets, hierarchy changes, property changes, and playtesting.
6. Keep ownership clean so the same content is not being managed from both places.

## Current Source Layout

- Shared low-level utilities live under `src/game/ReplicatedStorage/Shared/Foundation`.
- Shared authored config lives under `src/game/ReplicatedStorage/Shared/Config`.
- Shared UI/audio/camera/effect helpers live under `src/game/ReplicatedStorage/Shared/Presentation`.
- `src/game/ReplicatedStorage/Packages/EmitModule` contains the converted EmitModule source and is the standard VFX emit module.
- Server services are grouped locally by role under `src/game/ServerScriptService/Services`.
- Client controllers are grouped locally by role under `src/game/StarterPlayer/StarterPlayerScripts/Controllers`.
- Client ability behaviors live under `src/game/StarterPlayer/StarterPlayerScripts/Controllers/Gameplay/AbilityBehaviors`.
- Server ability behaviors live under `src/game/ServerScriptService/Services/Gameplay/AbilityBehaviors`.
- `default.project.json` maps grouped services/controllers back into flat runtime folders.

## Mixed-Folder Exception

Some folders are mixed and require split handling.

- If a task touches both code and assets, split the work: code locally, assets via Studio MCP.
- If a folder contains both scripts and Studio-owned instances, edit only the script files locally.
- For mixed UI areas such as `src/game/StarterGui`, use local edits for scripts and Studio MCP for the surrounding instance structure, layout, and visual assets.

## Intent For Future Agents

Rojo is the bridge for syncing code into the game. It is not the home for all Roblox content.

When in doubt:

- code and scripts -> local filesystem
- assets, properties, hierarchy, playtesting -> Studio MCP
