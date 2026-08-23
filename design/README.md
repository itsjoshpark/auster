# design/

Source design assets for Auster — **reference only**.

Nothing in this folder is referenced by the Xcode project or build. When
implementation needs an asset, **copy** it into the app target (the app icon
document into the project, menu bar SVGs into `Assets.xcassets`) per the phase
plans. This folder stays the canonical, regenerable source (each subfolder has
a parametric `generate.py`); edit here first, then re-copy.

- `AppIcon/` — Icon Composer document + layer sources for the app icon
- `MenuBarIcon/` — monochrome template icon set for the menu bar status item
