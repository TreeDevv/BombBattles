# AGENTS.md

This file defines the required workflow for agents working in `C:\dev\GameTemplate`.

## Core Rule

- Treat the local Rojo project as the source of truth for code.
- Treat Roblox Studio, accessed through the MCP server, as the source of truth for non-code content.
- Do not mix those ownership boundaries unless this file explicitly allows it.

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
2. Make script and code changes locally in the Rojo project.
3. Use Studio MCP for assets, hierarchy changes, property changes, and playtesting.
4. Keep ownership clean so the same content is not being managed from both places.

## Current Source Layout

- Shared low-level utilities live under `src/game/ReplicatedStorage/Shared/Foundation`.
- Shared authored config lives under `src/game/ReplicatedStorage/Shared/Config`.
- Shared UI/audio/camera/effect helpers live under `src/game/ReplicatedStorage/Shared/Presentation`.
- Server services are grouped locally by role under `src/game/ServerScriptService/Services`.
- Client controllers are grouped locally by role under `src/game/StarterPlayer/StarterPlayerScripts/Controllers`.
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
