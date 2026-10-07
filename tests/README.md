# InstantHub offline checks

From the workspace root:

```powershell
tools\luajit\luajit.exe mods\active\InstantHub\tests\darktide_113_compat_spec.lua
```

The harness drives the loaded mod's profile callback and session hooks with source-shaped stubs. This is offline evidence, not an in-game result. Last result: PASS (2026-09-29, LuaJIT 2.1).

```powershell
tools\luajit\luajit.exe mods\active\InstantHub\tests\instanthub_preload.lua
```

Preload regression cases for deferred package callbacks (moved here from `tools/tests/` on 2026-10-07). Last result: 23 passed (2026-10-07, LuaJIT 2.1, Linux).
