# Implementation notes

## Deviations (from the plan / from Blazma Boost)
- Not a fork of Boost/WinUtil: own engine and UI, smaller and focused on reversible tweaks. Boost was only read for the launch pattern (`irm ... | iex`, release asset, ASCII-escaped Arabic).
- "تعديل علي الخام" implemented as a RAM page + memory tweaks — assumption, unconfirmed.
- Never applied real tweaks on the owner's PC during development: verification used `-DryRun`, read-only detection and a throw-away `HKCU\Software\BlazmaTweakTest` key (`tests/run.ps1`).
- Font is Segoe UI (WPF can't use the woff2 IBM Plex files the family site uses).

## Pitfalls hit (fixed)
- Pooled `[powershell]` with `AddStatement()` never completes on Windows PowerShell 5.1 → `Start-Job2` sends one script: `param($__arg,$__sync)` + settings + core + `& { work } $__arg $__sync`.
- `GetNewClosure()` on UI callbacks loses script-scope variables when run with `-File` → job results carry their context (`Complete-TweakChange`).
- `byte[]` / `string[]` returned from a function get unrolled → `return , $array`.
- `[math]::Max(0, <big double>)` picks Int32 overload → `[math]::Max([double]0, ...)`.
- `Test-Path` on protected folders throws "Access is denied" → `-ErrorAction SilentlyContinue` (a harmless "job warning: Access is denied" is still logged once at start).
- RTL: `DockPanel.Dock="Right"` is the visual left; RenderTargetBitmap of RTL content is mirrored (flipped back in `Save-Shot`) and has no Window background (root Grid has `Background`).
- `TemplateBinding Tag` → `Path.Data` needs a real Geometry (`[Windows.Media.Geometry]::Parse`).
- powercfg/bcdedit output is localized → detection parses hex values / presence only.
- Release job needed `permissions: contents: write`.

## Known weak spots
- Real apply/undo of system tweaks not yet exercised on a real machine as admin.
- `mem.svchost` shows "on" on the owner's PC already (Windows default may already exceed 3670016 KB on 16 GB) — detection may be too loose.
- Shader cache on the owner's PC measured ~40 GB; it is unchecked by default in Cleanup.
- English layout only spot-checked (tweaks page).
