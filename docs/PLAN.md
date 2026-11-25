# Blazma Tweak — plan

## Goal
A very strong Windows tweaking tool in the Blazma family, run like Blazma Boost from PowerShell:
`irm mr-kateba.github.io/tweak | iex`. Arabic first (RTL), English toggle. Owner: kateba (mr-kateba).
Owner's request (verbatim): "اداة تسوي تويك لل ويندز و تعديل علي الخام زي بلازما بوست ... يشتغل علي باور شيل ... تسميه بلازما تويك و تكون اداة قوية جدا".
"الخام" was read as RAM (الرام) — not confirmed by the owner.

## Design
- Single ASCII-only script `dist/BlazmaTweak.ps1` built by `build.ps1` from:
  - `src/core.ps1` — engine: registry (.NET API, 64-bit view), services (`sc.exe config`), scheduled tasks, backup/undo (`%LOCALAPPDATA%\BlazmaTweak\backup.json`), restore point, memory (NtSetSystemInformation via Add-Type), cleanup, power (powercfg), network (DNS, ping, reset), system info.
  - `src/main.ps1` + `src/ui.xaml` — WPF window, right sidebar, 7 pages: Home, Tweaks, Memory, Power, Cleanup, Network, Backup & undo. Background work in a runspace pool.
  - `config/tweaks.json` — 60 tweaks (id, cat, risk safe/advanced/expert, presets basic/gaming/max, restart reboot/explorer, ar/en name+desc, reg[]/svc[]/task[] and/or apply/undo/detect scripts).
  - `config/strings.json` — all UI text, ar + en (same keys; tests enforce).
- Release: tag `v*` → GitHub Actions (`.github/workflows/build.yml`) runs `tests/run.ps1`, attaches `dist/BlazmaTweak.ps1` to the release. Site launcher `mr-kateba.github.io/tweak` runs the latest release asset.
- Switches: `-DryRun` (log, write nothing), `-NoElevate`, `-Lang ar|en`, `-Shot <dir>` (render all pages to PNG and exit).

## Done
- v0.1.0 released (60 tweaks, presets, RAM live + clean + auto-clean, power plans + Ultimate, cleanup scan/clean, DNS/ping/reset, restore point, undo-all, ar/en).
- Site: `/tweak` launcher, tool entry with "نسخ الأمر", logo `logos/tweak.svg`, stats.

## Next (proposed, not agreed)
- Owner tests on his PC; fix what he reports.
- Confirm what "الخام" meant.
- Possible: per-game profiles, startup-apps manager, Windows-update control page, export/import of chosen tweaks.
