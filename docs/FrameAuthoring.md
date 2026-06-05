# Frame Authoring

Use this when adding UI frames that should be controlled by `FrameController`.

## Studio Setup

- Create the visual UI in Studio under the target `ScreenGui`; UI hierarchy, layout, tags, and attributes are Studio-owned.
- Put the frame at its final open position. `FrameController` caches this position and animates the frame down from above the screen.
- Add the CollectionService tag `Frame` to the `GuiObject` that should open and close.
- Name the tagged instance exactly what code will pass to `FrameController:OpenFrame(frameName)`. Frame names must be unique within `PlayerGui`.
- Set the boolean attribute `Exclusive` to `true` when opening this frame should move same-`ScreenGui` sibling HUD elements offscreen and show a click-to-close backdrop.

## Code Usage

From another client controller:

```lua
local FrameController = require(script.Parent:WaitForChild("FrameController"))

FrameController:OpenFrame("Shop")
FrameController:CloseFrame("Shop")
FrameController:ToggleFrame("Shop")
FrameController:CloseCurrentFrame()
```

`FrameController` also keeps compatibility aliases for `OpenWindow`, `CloseWindow`, `ToggleWindow`, and `CloseCurrentWindow`.

## Behavior Notes

- Tagged frames start hidden when `FrameController` registers them.
- `OpenFrame("Name")` resolves by `Instance.Name`, not by a display label or attribute.
- Opening a new frame closes the currently open frame first.
- Exclusive frames affect only visible sibling `GuiObject`s in the same `ScreenGui`.
- The backdrop is created at runtime by code; do not add a permanent backdrop instance for this system.
- Keep frame visuals and layout in Studio. Only script logic belongs in the Rojo project.

## Quick Checklist

- Frame is a `GuiObject` under `PlayerGui` at runtime.
- Frame has CollectionService tag `Frame`.
- Frame name is unique and matches the code call.
- Optional `Exclusive` attribute is a boolean, not a string.
- Sibling HUD elements that should slide away are direct `GuiObject` children of the same `ScreenGui`.
