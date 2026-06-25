# Client Code Examples

These files are curated examples derived from production Bomb Battles modules. They are meant for code review and portfolio sharing, not as drop-in replacements for the live game.

The examples keep the important architectural ideas while trimming project-specific telemetry and debug noise:

- `RoundMapRuntime.lua` shows server-side map preloading, prepared clone reuse, active map swapping, and cleanup.
- `ReplayClipPolicy.lua` shows replay payload caps, sanitization, importance-based trimming, and send-readiness checks.
- `ReplayMapSimulator.lua` shows client-side replay map prewarming, isolated replay scene creation, coordinate transforms, and destruction playback.

The production versions live under `src/game/` and remain the source of truth for runtime behavior.
