# MLX Player: handover

A lightweight native macOS menu bar app that installs and manages `mlx-lm` (via `uv`), runs `mlx_lm.server`,
browses and downloads Hugging Face MLX models, and tells you what will actually run on your Mac.

The design was approved by the user. Mockup source is in `design/` (`*.dc.html`, one per screen; open them in a
browser, or see the published canvas: https://claude.ai/artifact/PtGiNC8E4Wk8ig7mF6HxYX).

## State at handover

| Part | Status |
|---|---|
| `Sources/MLXPlayerCore` | Done. **42 tests pass** (`swift test`). |
| `Sources/mlxplayer-mcp` | Done. Verified end to end against the running app (get_status, start_server, stop_server). |
| `Sources/MLXPlayer` | Compiles. App entry, popover, sidebar shell and all screens written (Setup, Discover, Library, Server, Advisor, Memory, Usage, Logs, Settings). |
| `scripts/bundle.sh` | Builds `dist/MLX Player.app` (Info.plist, LSUIElement, macOS 14, icon, mcp copied, ad-hoc signed, sandbox off). |
| Visual pass | **Not done.** Layouts have not been compared with `design/` on screen yet; check each screen at 1240x820 for clipping and scrolling. |
| Untested on hardware | First-run installer from the UI, downloads from the UI, real memory-pressure responses, notarization. |

The macOS target is only declared on macOS (`#if os(macOS)` in `Package.swift`), so Linux CI still builds the core.
**The first job on a Mac is `swift build` and fixing compile errors in `Sources/MLXPlayer`.**

## Architecture

```
MLXPlayerCore (no UI)
  Hardware / ChipTable      chip, memory, GPU wired limit, bandwidth (published figures)
  ModelInfo                 name parsing (params, MoE active, bits), config.json -> KV bytes/token, variant detection
  Advisor                   fit (comfortable/tight/won't fit), recommended + safe context, tok/s estimate, quality rank
  ServerSettings            per-model settings, builds mlx_lm.server args, drops flags the installed version lacks
  AppSettings/SettingsStore app-wide settings, profiles, JSON persistence
  FlagProbe                 parses `mlx_lm.server --help` to learn supported flags
  Installer                 downloads uv tarball, `uv venv --python 3.12`, `uv pip install mlx-lm` (all under app folder)
  ServerSupervisor (actor)  starts/stops mlx_lm.server, waits for /v1/models
  LazyProxy                 public port; starts model on first request, enforces context limit, meters usage,
                            streams SSE through, injects stream_options.include_usage, answers /v1/models & /health
                            & CORS preflight without loading the model
  UsageStore                JSONL request log + summaries (today/7d/30d), CSV
  MemoryPolicy / Monitor    pressure -> actions (trim cache, cap context, unload)
  HuggingFaceClient         search (expand[] fields), config.json, repo size, filters (size/bits/capability/family/variant)
  Library / ModelDownload   scans HF cache; downloads via `hf download` and reports progress by watching the cache dir
  Control / MCP             loopback JSON API with bearer token (control.json, 0600) + MCP tools
MLXPlayer (macOS app, SwiftUI)
  AppModel                  @Observable owner of everything above; control API handler with approval dialogs
```

Everything the app owns lives in `~/Library/Application Support/MLX Player/` (uv, python, venv, settings, usage log).

## Screens to build (match `design/`)

1. **Menu bar popover** (`MenuBarExtra` `.window` style): status pill, loaded model card (Stop / Restart / Unload),
   endpoint with Copy URL + cURL/Env/Model ID, speed/memory/requests tiles, "Today" usage row, switch-model list,
   search field, footer (Open / Logs / Quit). Menu bar label uses `Brand.menuBarImage(...)` + optional "54 t/s".
2. **Setup** (first run, from `AppModel.runSetup`): steps Check Mac, Install uv, Python env, mlx-lm, choose first model
   (Advisor picks), optional Agent access (MCP). "Use existing mlx-lm" sets `customServerPath`.
3. **Discover**: search + filters (size, quantization, capability, family, **Alignment: Standard/Uncensored/Abliterated**,
   Fits my Mac), results with fit badge, Download / Pause / Cancel / Installed / Load.
4. **Library**: installed models, size, last used, Load/Unload/Settings, Reveal, Copy ID, Delete, disk usage bar.
5. **Server**: header + unapplied-changes banner; tabs Context & memory / Sampling / Model / Network;
   right rail: memory budget + tabs Endpoint / Command / Log.
6. **Advisor**: job chips + free text, variant chips; tabs Recommended / Compare sizes / Context & command.
7. **Memory**: tabs Live & limits / Loading & rules; GPU wired limit; on-demand + idle unload; automatic responses; safeguards.
8. **Usage**: range, KPI row, tokens/hour chart, by client, by model, loaded vs idle.
9. **Settings > Agents (MCP)**: enable, permission level, tool list, "claude mcp add" command, Install automatically.
10. **Logs** (sidebar item; the Playground item in the mockup is not planned yet, drop it from the sidebar).

Design rules the user set (keep them):
- Short button labels, always one line (`.lineLimit(1)`, `.fixedSize()`; see `PillButtonStyle`). No long sentences on buttons.
- Short, quiet copy. Descriptions only where a label is not self-explanatory.
- **No default scrolling.** Every screen fits a ~1240x820 window by using tabs. Only long lists (models, logs) scroll,
  inside their own panel with thin overlay scrollbars.
- Modern, consistent vector icons (SF Symbols are used in the app, custom vector for the app/menu bar mark).
- Popover is native `MenuBarExtra`, so the arrow connects to the icon automatically.
- App icon + menu bar glyph: five rounded bars forming a play triangle, middle bar mint. See `BrandIcons.swift`
  and `design/Brand.dc.html`.

## Known gaps and decisions to revisit

- **Context length** (verified on mlx-lm 0.32.2): `mlx_lm.server` has **no** `--max-kv-size`. The proxy enforces the limit by estimating prompt tokens
  (about 3.2 chars/token) and returning an OpenAI-style `context_length_exceeded`. If `--max-kv-size` exists, it is also passed.
  Verify against the installed mlx-lm (`FlagProbe`).
- **KV cache quantization**: `--kv-bits` exists (also `--kv-group-size`, `--quantized-kv-start`). Exposed as Server > KV cache. mlx-lm serves one request at a time when it is set.
- **Trim prompt cache** cannot be done live (no API). `AppModel.trimCacheWhenIdle` restarts with a smaller
  `--prompt-cache-bytes` once idle. The Memory screen should say so.
- **Speed estimates** use memory bandwidth x efficiency (0.8 dense, 0.45 MoE). Calibrate against real runs, ideally with a
  "benchmark this model" button.
- **Quality score** is a size/quantization heuristic, not a benchmark. Replace with a refreshable benchmark table.
- **GPU wired limit** (`sudo sysctl iogpu.wired_limit_mb=N`) needs admin rights. Planned: `SMAppService` privileged helper
  or an `osascript` admin prompt, plus an optional launch daemon to persist. Not implemented.
- **Launch at login**: use `SMAppService.mainApp.register()` (setting exists, not wired).
- **HF token**: store in Keychain, pass via `HF_TOKEN` env (not wired).
- Model Advisor free-text uses keyword matching (`AdvisorTask.infer`), no AI.
- The proxy forces `Connection: close` per exchange and reads Content-Length or chunked request bodies.
  Thread per connection; fine for local use.
- Sandbox must stay **off** (the app spawns processes). Distribute as a notarized DMG; Sparkle for updates.
- `Brand.appIconImage` draws the icon at runtime; ship a real `AppIcon.icns` (generate from it in a build script).

## Commands

```
swift build                 # core + mcp (+ app on macOS)
swift test                  # 40 tests, includes proxy streaming against Tests/MLXPlayerCoreTests/Fixtures/fake_backend.py (needs python3)
swift run mlxplayer-mcp     # stdio MCP server
```

## Suggested order

1. On a Mac: `swift build`, fix `Sources/MLXPlayer` compile errors.
2. `MLXPlayerApp.swift` (`@main`, `MenuBarExtra`, `Window("MLX Player", id: "main")`, `LSUIElement`), then the popover and sidebar shell.
3. Screens in the order above, each backed by `AppModel`.
4. Bundle script: `.app`, Info.plist (`LSUIElement`, min macOS 14), icon, copy `mlxplayer-mcp` into `Contents/MacOS`.
5. Real-hardware pass: install flow, load a model, stream through the proxy, idle unload, memory pressure, MCP from Claude Code.

## Verified on hardware (M4 Max, mlx-lm 0.32.2)

- On-demand load on first request, SSE streaming through the proxy, usage log, `context_length_exceeded`, and idle unload (1 min) all work.
- All flags we emit exist in `mlx_lm.server --help` (pinned in `SettingsTests`). Not in 0.32.2: `--max-kv-size`.
- Settings files with missing keys used to reset everything; loading is now lenient (`SettingsStore.decodeLeniently`).
- Bundle: `scripts/bundle.sh` then `open "dist/MLX Player.app"`.

(update test marker)
