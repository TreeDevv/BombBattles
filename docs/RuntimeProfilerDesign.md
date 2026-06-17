# Runtime Profiler Design

## Purpose

Build an opt-in runtime profiler for Bomb Battles that answers two questions during real playtests:

- Which server systems consume frame time, network budget, memory, and instance churn?
- Which client controllers, VFX paths, UI loops, and replay systems consume render/heartbeat time?

This profiler should complement Roblox MicroProfiler, not replace it. Our code should emit stable labels and aggregate data that are easy to compare across test sessions, while `debug.profilebegin()` / `debug.profileend()` can make the same spans visible in MicroProfiler captures.

## Constraints

- Rojo-managed scripts remain the source of truth for profiler code and script instrumentation.
- Studio remains the source of truth for non-code UI, assets, hierarchy changes, and live playtesting.
- The profiler must be disabled by default outside explicit debug sessions.
- Disabled overhead must be close to one branch and no allocations in hot paths.
- Enabled overhead must be bounded: aggregate by label first, record raw traces only in short windows.
- Client data must be summarized before sending to the server. Do not stream per-frame raw spans from every client.

## Sources Checked

- Roblox MicroProfiler documentation: https://create.roblox.com/docs/performance-optimization/microprofiler
- Roblox `debug` library reference for profile markers: https://create.roblox.com/docs/reference/engine/libraries/debug
- Roblox `Stats` service reference: https://create.roblox.com/docs/reference/engine/classes/Stats
- Online searches were run for Roblox DevForum and Reddit discussions around MicroProfiler and `debug.profilebegin`; no specific thread should be treated as a design dependency.

## Proposed Modules

### Shared RuntimeProfiler

Path:

`src/game/ReplicatedStorage/Shared/Foundation/Common/RuntimeProfiler.lua`

Runtime path:

`ReplicatedStorage.Shared.Common.RuntimeProfiler`

Responsibilities:

- Maintain enabled state and profiling mode.
- Provide zero-allocation fast exits when disabled.
- Time named spans with `os.clock()`.
- Optionally mirror spans to `debug.profilebegin(label)` and `debug.profileend()`.
- Aggregate span data by label:
  - `calls`
  - `totalMs`
  - `maxMs`
  - `lastMs`
  - rolling average
  - slow-call count
  - optional raw trace samples for a bounded capture window
- Track counters:
  - remote calls
  - estimated payload size
  - created/destroyed visual objects
  - active projectiles
  - active VFX
  - replay frames/events
  - voxel/debris counts
- Track gauges:
  - player count
  - workspace descendant count
  - base part count
  - unanchored part count
  - projectile count
  - active render loop count
  - memory category snapshots, where available

API sketch:

```lua
RuntimeProfiler.SetEnabled(enabled: boolean, options: ProfilerOptions?)
RuntimeProfiler.IsEnabled(): boolean
RuntimeProfiler.Begin(label: string): number?
RuntimeProfiler.End(label: string, token: number?)
RuntimeProfiler.Profile(label: string, callback: () -> any): ...any
RuntimeProfiler.Count(label: string, amount: number?)
RuntimeProfiler.Gauge(label: string, value: number)
RuntimeProfiler.Flush(): ProfilerSnapshot
RuntimeProfiler.Reset()
RuntimeProfiler.WithMicroProfilerMarkers(enabled: boolean)
```

Hot-path usage should prefer constant label strings:

```lua
local token = RuntimeProfiler.Begin("Server/BombProjectile/StepAll")
stepAll(fixedDt)
RuntimeProfiler.End("Server/BombProjectile/StepAll", token)
```

### Server RuntimeProfilerService

Path:

`src/game/ServerScriptService/Services/Core/RuntimeProfilerService.lua`

Responsibilities:

- Own profiler activation policy.
- Create profiler remotes under `ReplicatedStorage.Remotes.RuntimeProfiler`.
- Broadcast enable/disable state to selected clients.
- Receive client aggregate snapshots.
- Emit periodic server summaries while profiling is enabled.
- Provide dump/export helpers for Studio playtests.
- Enforce access: only Studio by default, or a small allowlist/admin gate in live environments.

Suggested remotes:

- `ProfilerControl`: server to client control messages.
- `ProfilerClientSnapshot`: client to server aggregate snapshots.

The service should not use DataStore. Profiler data is diagnostic and should remain session-local unless we later add an explicit export path.

### Client RuntimeProfilerController

Path:

`src/game/StarterPlayer/StarterPlayerScripts/Controllers/Core/RuntimeProfilerController.lua`

Responsibilities:

- Listen for server control messages.
- Enable local profiling modes.
- Flush client summaries on a low-frequency interval, such as every 2 seconds.
- Print local summaries in Studio when requested.
- Avoid building a profiler UI in Rojo. If we later want an in-game panel, create the UI hierarchy through Studio and keep only script behavior in Rojo.

## Profiling Modes

`Off`

- No timing, no counters, no remotes.
- Default in production.

`Counters`

- Count events and gauges only.
- Useful for low-overhead always-on Studio sessions.

`Aggregate`

- Time spans and aggregate by label.
- Default active mode for playtests.

`TraceWindow`

- Aggregate plus bounded raw span samples for 5-15 seconds.
- Used when a spike is detected and we need call order/context.

`MicroProfilerMarkers`

- Mirrors active spans to Roblox MicroProfiler markers.
- Use sparingly because high-frequency labels can clutter captures.

## First Instrumentation Points

### Loader and Lifecycle

File: `src/game/ReplicatedStorage/Loader.lua`

Measure:

- `Require/<ModuleName>` in `LoadChildren` and `LoadDescendants`.
- `Lifecycle/<ModuleName>/<MethodName>` in `SpawnAll`.
- Spawn count and lifecycle errors.

Why:

This gives immediate startup cost, service/controller startup cost, and player lifecycle cost without touching every module first.

### Server Frame Loops

File: `src/game/ServerScriptService/Services/Gameplay/BombService.lua`

Measure:

- `Server/BombService/Heartbeat`
- `Server/BombService/UpdateProjectileStates`
- `Server/BombService/SyncPlayerRoundState`
- `Server/BombService/UpdateRecharge`
- player count and cook state count

File: `src/game/ServerScriptService/Services/Gameplay/BombProjectileService.lua`

Measure:

- `Server/BombProjectile/Heartbeat`
- `Server/BombProjectile/FixedStep`
- `Server/BombProjectile/StepAll`
- `Server/BombProjectile/StepProjectile`
- `Server/BombProjectile/ProjectilePhysicsStep`
- `Server/BombProjectile/AbilityHook/<HookName>`
- `Server/BombProjectile/FindSweptPlayerContact`
- active projectile count
- fixed steps per heartbeat
- max-step clamping count
- player parts scanned for swept contact

Why:

Projectile simulation is the most obvious recurring server CPU path. It also calls ability hooks, physics, raycasts, snapshots, and effect dispatch.

### Terrain and Voxel Destruction

File: `src/game/ServerScriptService/Services/Gameplay/DestructionService.lua`

Measure:

- `Server/Destruction/GetTargets`
- `Server/Destruction/DestroySphere`
- `Server/Destruction/DestroyCylinderDown`
- `Server/Destruction/VoxelizePosition`
- destructible root count
- target part count
- targets hit
- debris payload count
- voxelize errors

Why:

`DestroySphere` currently rebuilds destructible targets from `CollectionService:GetTagged()` and root descendants before each voxelize call. This is likely expensive during heavy explosions and should be measured before changing it.

### Ability System

File: `src/game/ServerScriptService/Services/Gameplay/AbilityService.lua`

Measure:

- `Server/Ability/HandleClientMessage`
- `Server/Ability/Activate/<AbilityId>`
- `Server/Ability/CanActivate/<AbilityId>`
- `Server/Ability/OnActivate/<AbilityId>`
- `Server/Ability/CollectHookCandidates/<HookName>`
- `Server/Ability/RunHook/<HookName>`
- `Server/Ability/Hook/<HookName>/<AbilityId>`
- candidate count per hook
- handled-result count by result kind

Why:

Projectile steps call hooks, and hooks scan active ability slots across players. We need to know whether time is spent collecting candidates, sorting them, or executing individual behavior modules.

### Replay

Files:

- `src/game/ServerScriptService/Services/Gameplay/ReplayService.lua`
- `src/game/StarterPlayer/StarterPlayerScripts/Controllers/Gameplay/Replay/*`

Measure server:

- `Server/Replay/Heartbeat`
- `Server/Replay/CaptureFrame`
- `Server/Replay/GetPlayerSnapshot`
- `Server/Replay/GetBombSnapshots`
- `Server/Replay/StoreClientSample`
- `Server/Replay/BuildKillPayload`
- `Server/Replay/BuildPOTGPayload`
- `Server/Replay/OptimizePayload`
- frames in buffer
- events in buffer
- estimated payload size
- client sample records

Measure client:

- `Client/Replay/BuildState`
- `Client/Replay/Step`
- `Client/Replay/MapSimulator`
- `Client/Replay/AvatarFactory`
- replay object count
- replay visual count

Why:

Replay has frame sampling, payload optimization, client sample ingestion, and replay playback. Those can be expensive even if core gameplay is fine.

### Client Render and Heartbeat Controllers

Files to instrument first:

- `CameraController.lua`
- `MovementController.lua`
- `CharacterPoseController.lua`
- `CharacterAnimationController.lua`
- `BombController.lua`
- `AbilityController.lua`
- `ScreenEffectsController.lua`
- `MovementEffectsController.lua`
- `TeamCoreCrystalController.lua`
- `POTGCutsceneController.lua`

Measure:

- one span per bound render/heartbeat callback
- active loop count
- slow-frame count per controller
- effect instance count
- preview raycast/spherecast count
- UI update count

Why:

Client render time is usually death by many small loops. We need per-controller totals and max spikes.

### Ability Client Behaviors

Folder:

`src/game/StarterPlayer/StarterPlayerScripts/Controllers/Gameplay/AbilityBehaviors`

Measure:

- preview update spans
- targeting update spans
- render/heartbeat spans for active visuals
- VFX activation counts by ability
- raycast/spherecast counts by ability

Start with the heavier-looking files:

- `GrappleHook.lua`
- `OrbitalStrike.lua`
- `GravityField.lua`
- `MagnetField.lua`
- `Interceptor.lua`
- `WallBuilder.lua`
- `ReflectShield.lua`

### VFX and EmitModule

Path:

`src/game/ReplicatedStorage/Packages/EmitModule`

Measure only the public emit entry points first:

- `VFX/Emit/<EffectName>`
- emitted particle count where available
- cloned object count
- active render-step effect count
- effect duration

Do not replace EmitModule behavior. Add timing around entry points and high-level effect dispatch only.

### Remotes

Measure at connection/send sites:

- server receives per remote
- client receives per remote
- server sends per remote
- client sends per remote
- approximate payload weight by recursively counting primitive/table fields, capped to avoid deep traversal

Do not monkey-patch Roblox remotes globally. Add small wrappers around project-owned remote bind/send paths as we touch each system.

## Reporting

Periodic summary format:

```text
[Profiler][Server][10s] top spans
1. Server/BombProjectile/StepProjectile calls=842 total=74.2ms avg=0.09ms max=2.8ms slow=3
2. Server/Destruction/VoxelizePosition calls=14 total=62.5ms avg=4.46ms max=11.7ms slow=6
3. Server/Replay/CaptureFrame calls=300 total=38.0ms avg=0.13ms max=1.2ms slow=0
```

Client summaries should be keyed by player:

```text
[Profiler][Client:PlayerName][10s] render avg=1.8ms max=9.6ms fpsMin=42
1. Client/BombController/Preview calls=600 total=41.0ms avg=0.07ms max=1.9ms
2. Client/CameraController/Render calls=600 total=35.0ms avg=0.06ms max=0.8ms
```

Thresholds:

- server heartbeat span warning: `> 4 ms`
- server event span warning: `> 8 ms`
- client render callback warning: `> 2 ms`
- any single client frame total warning: `> 16.7 ms`
- trace trigger: configurable, default single span `> 10 ms`

## Activation

Studio defaults:

- `Off` when no profiler attribute/command is set.
- Allow enabling through server-side debug command or a temporary attribute such as `ReplicatedStorage:SetAttribute("RuntimeProfilerMode", "Aggregate")`.

Live defaults:

- `Off`.
- Only server-authorized users can request client profiling.
- Client upload interval should be at least 2 seconds and top-N summarized.

Suggested commands for later:

- `profiler start aggregate 60`
- `profiler start trace 10`
- `profiler stop`
- `profiler dump server`
- `profiler dump clients`
- `profiler reset`

## Data Model

Snapshot shape:

```lua
type SpanAggregate = {
	label: string,
	calls: number,
	totalMs: number,
	maxMs: number,
	lastMs: number,
	slowCalls: number,
}

type ProfilerSnapshot = {
	source: "Server" | "Client",
	playerUserId: number?,
	startedAt: number,
	endedAt: number,
	mode: string,
	spans: { SpanAggregate },
	counters: { [string]: number },
	gauges: { [string]: number },
	traces: { TraceRecord }?,
}
```

Keep labels stable and hierarchical:

- `Server/BombProjectile/StepProjectile`
- `Server/Ability/Hook/OnProjectileStep/GravityField`
- `Client/BombController/Preview`
- `Client/VFX/Emit/Explosion`

## Rollout Plan

1. Add `RuntimeProfiler` shared module, server service, client controller, and project mappings.
2. Instrument loader lifecycle and top-level server/client frame loops.
3. Instrument projectile simulation, destruction, ability hooks, and replay capture.
4. Instrument high-frequency client controllers and selected ability previews.
5. Add VFX entry-point counters and remote wrappers.
6. Add Studio playtest workflow and export/dump helpers.
7. Run baseline captures before making optimization changes.

## Validation Plan

- Run `rojo build` and `rojo sourcemap` after adding modules/mappings.
- Playtest in Studio with profiler off and confirm no summary output or client uploads.
- Enable `Counters` and confirm gauges/counters update without span timings.
- Enable `Aggregate` for a 60-second bot/player session and confirm server plus client summaries.
- Enable `MicroProfilerMarkers` for a short capture and confirm labels appear in Roblox MicroProfiler.
- Stress-test with heavy bomb/ability usage and verify summaries identify projectile, destruction, replay, VFX, or client render hotspots.

## Risks

- Profiling can become the bottleneck if raw traces are left on. Keep trace windows bounded.
- Dynamic labels can explode cardinality. Use fixed labels and put IDs in counters only when necessary.
- Client uploads can distort network measurements. Summarize top-N locally and send infrequently.
- MicroProfiler markers in every tight loop can create noise. Use aggregate mode first, markers only when capturing a focused spike.
- Instrumenting too broadly at once can make results harder to interpret. Add spans in layers and baseline after each layer.
