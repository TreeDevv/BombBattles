# GameTemplate

A Rojo-first Roblox game template with code organized by source ownership and runtime role.

The local filesystem owns scripts and modules. Roblox Studio owns non-code content such as models, UI hierarchy, animations, VFX, sounds, map content, and `GameAssets`.

## Layout

- `src/game/ReplicatedStorage/Loader.lua`: shared bootstrap loader
- `src/game/ReplicatedStorage/Shared/Foundation/Common`: low-level shared utilities exposed as `ReplicatedStorage.Shared.Common`
- `src/game/ReplicatedStorage/Shared/Config`: shared config and lists exposed as `ReplicatedStorage.Shared.Config`
- `src/game/ReplicatedStorage/Shared/Presentation`: UI, audio, camera, effects, and formatting helpers exposed under `ReplicatedStorage.Shared`
- `src/game/ServerScriptService/Services/Core`: core server services
- `src/game/ServerScriptService/Services/Economy`: purchase and monetization services
- `src/game/ServerScriptService/Services/Social`: chat/social services
- `src/game/StarterPlayer/StarterPlayerScripts/Controllers/Core`: core client controllers
- `src/game/StarterPlayer/StarterPlayerScripts/Controllers/UI`: UI client controllers
- `src/game/StarterPlayer/StarterPlayerScripts/Controllers/Social`: social client controllers
- `src/game/StarterGui`: code-owned scripts inside Studio-owned UI areas
- `src/wally.toml` and `src/wally.lock`: dependency source of truth

`default.project.json` maps grouped local service/controller folders back into flat runtime folders:

- `ServerScriptService.Services`
- `StarterPlayer.StarterPlayerScripts.Controllers`

That keeps runtime requires and lifecycle loading predictable while the repo stays easier to navigate.

## Ownership Notes

- Do code changes locally in this Rojo project.
- Do asset, hierarchy, property, placement, UI layout, animation, sound, VFX, and playtest work through Studio/MCP.
- Keep visual assets in Studio-managed `GameAssets`, not in Rojo-managed code folders.
- Wally output folders are generated and ignored: run `wally install --project-path src` to restore them locally.

## Visual Effects Best Practices

- Keep authoritative gameplay state on the server, but render cosmetic effects on the client whenever the server does not need to own the result.
- Prefer a lightweight effect-intent flow: the server validates the gameplay outcome, then broadcasts compact data such as effect name, position, target, duration, or payload.
- Let clients spawn particles, sounds, camera shake, beams, highlights, UI flourishes, and other cosmetic tweens locally from that effect intent.
- Tween UI and non-authoritative world effects locally with `TweenService` for smoother presentation and less replication noise.
- Store visual assets in Studio-managed `GameAssets`; keep Rojo-owned modules focused on resolving, cloning, playing, and cleaning up those assets.

### UI Editing Notes

- When UI work is requested, inspect the live UI model with Studio MCP before changing hierarchy, properties, or layout.
- Preserve the native UI structure, object names, rich text settings, fonts, sizing, and text formatting unless the requested change requires otherwise.
- When changing text, do not infer or rewrite `TextLabel`, `TextButton`, or other UI copy unless the user explicitly asks for text changes; prefer filling the intended value into the existing format.

## Tooling

Install tools and packages:

```powershell
rokit install
wally install --project-path src
```

Build the place:

```powershell
rojo build -o "GameTemplate.rbxlx"
```

Serve into Studio:

```powershell
rojo serve
```
