# MLX Player: handover

A lightweight native macOS menu bar app that installs and manages `mlx-lm` (via `uv`), runs `mlx_lm.server`,
browses and downloads Hugging Face MLX models, and tells you what will actually run on your Mac.

The design was approved by the user. Mockup source is in `design/` (`*.dc.html`, one per screen; open them in a
browser, or see the published canvas: https://claude.ai/artifact/PtGiNC8E4Wk8ig7mF6HxYX).

## State at handover

| Part | Status |
|---|---|
| `Sources/MLXPlayerCore` | Done. **94 tests pass** (plus 1 live test that is skipped unless `MLX_LIVE_MODEL` is set) (`swift test`). |
| `Sources/mlxplayer-mcp` | Done. Verified end to end against the running app (get_status, start_server, stop_server). |
| `Sources/MLXPlayer` | Compiles. App entry, popover, sidebar shell and all screens written (Setup, Discover, Library, Server, Advisor, Memory, Usage, Logs, Settings). |
| `scripts/bundle.sh` | Builds `dist/MLX Player.app` (Info.plist, LSUIElement, macOS 14, icon, mcp copied, ad-hoc signed, sandbox off). |
| Visual pass | Done for Overview, Discover, Library, Server, Memory, Usage, Logs, Settings, Advisor via `MLXPlayer --snapshot DIR [dark] [collapsed] [gguf] [toast] [screen]` (renders the real window to PNG). Compare against `design/` still manual. |
| Untested on hardware | First-run installer from the UI, downloads from the UI, real memory-pressure responses, notarization. |

The macOS target is only declared on macOS (`#if os(macOS)` in `Package.swift`), so Linux CI still builds the core.
**The first job on a Mac is `swift build` and fixing compile errors in `Sources/MLXPlayer`.**

## Added since the first handover

- **Overview** screen (landing page): memory, GPU, VRAM (GPU memory vs GPU wired limit) and CPU gauges with history, memory map (model / wired / apps / compressed / cached / free, with the GPU limit marked), per-core CPU bars (E and P cores), health. Core: `SystemSampler` (host_processor_info, vm_statistics64, IOAccelerator `PerformanceStatistics`).
- **Discover**: full-width toolbar, filter popovers with Select all / Clear, format filter (MLX, GGUF, Safetensors, GPTQ, AWQ, ONNX, Core ML; only MLX can be downloaded, others show "Other runtime"), language models only (`pipeline_tag=text-generation`), cursor paging via the Hub `Link` header, skeleton loading, detail overlay, cached results (`ResponseCache`, 5 min; Refresh/Retry/token change invalidate).
- **Hub API gotcha**: `expand[]` accepts only a fixed field list (no `usedStorage`); `HFSearchTests` pins it. A bad field gives HTTP 400.
- **Library**: search, select all, bulk delete, typed-name confirmation (`TypedConfirmPanel`) in a right overlay.
- **UI kit** (`Overlay.swift`, `Toasts.swift`, `HelpContent.swift`): `sideOverlay`, `CopyIcon`, `HelpButton`, `SkeletonRows`, `FilterMenu`, `ChoiceMenu`, `LogPane`, toasts for background results. Help text for each screen lives in `HelpContent`.
- **Sidebar** collapses to icons; **appearance** System / Light / Dark (Settings and sidebar footer).
- **HF token** in Keychain (`HFToken`), used by search, downloads and the server. **GPU limit** Apply/Reset via the macOS admin prompt (`GPULimit`, lasts until restart).

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
- **Speed estimates** use memory bandwidth x efficiency (0.8 dense, 0.45 MoE), now calibrated by the Benchmark button.
- **Quality score** is a size/quantization heuristic, not a benchmark. Replace with a refreshable benchmark table.
- **GPU wired limit**: Apply/Reset use an `osascript` admin prompt and last until restart. A launch daemon to persist it is not built.
- Model Advisor free-text uses keyword matching (`AdvisorTask.infer`), no AI.
- The proxy forces `Connection: close` per exchange and reads Content-Length or chunked request bodies.
  Thread per connection; fine for local use.
- Sandbox must stay **off** (the app spawns processes). Distribute as a notarized DMG; Sparkle for updates.
- `Brand.appIconImage` draws the icon at runtime; ship a real `AppIcon.icns` (generate from it in a build script).

## Commands

```
swift build                 # core + mcp (+ app on macOS)
swift test                  # 92 tests, includes proxy streaming against Tests/MLXPlayerCoreTests/Fixtures/fake_backend.py (needs python3)
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


## Loading, unloading and memory (hardened)

- `ServerSupervisor`: one server at a time. A stop or a newer start cancels a start still loading (`ServerError.cancelled`), so there are no races or orphan processes. Stop waits until the process and its children are gone.
- "Running" means the model answered a one-token request (warm-up), so out-of-memory shows at load time. OOM is detected from the log or SIGKILL; `AppModel.startServer` retries once with half the context and cache.
- Before loading: the previous model is unloaded first, the context is lowered if free memory is short, the backend port is picked from free ones.
- `server.pid` (pid + start time) lets the next launch kill a server left by a crash or force quit. Quitting also kills it synchronously.
- Memory is measured as physical footprint of the server tree (includes GPU-wired memory), not resident size.
- Idle unload never cuts a request off; pressure unload waits up to 60 s for idle. Three failed starts in 5 minutes stop automatic restarts.
- Tests: `SupervisorTests` (fake server script), plus kill -9 / rapid cycle checks on hardware.

## Updates from the repo branch

- `Updater` (app) + `UpdateChecker`/`UpdateSwap` (core). Settings > Updates, popover banner, daily quiet check (setting `autoCheckUpdates`).
- The build embeds its commit, repo and branch (`MLXCommit`, `MLXRepo`, `MLXBranch` in Info.plist, set by `scripts/bundle.sh`). The check asks GitHub to compare that commit with the branch head; only "ahead" offers an update.
- Install: clone or fetch into `~/Library/Application Support/MLX Player/source`, run `scripts/bundle.sh` into `staging`, verify (codesign, files present, `--self-test` prints the commit), then `swap.sh` replaces the app after quit. The new app writes `update-ok` after 4 s; without it within 40 s the old app is restored and a notice is shown.
- Needs git and the Xcode tools on the user's Mac, and a writable install location.
- Tested for real against a branch: 0ff9953 to 69a0cc2 in about 40 s. For scripted runs: `open -n --env MLX_UPDATE_NOW=1 "MLX Player.app"`. Test builds use `MLX_BRANCH=<branch> scripts/bundle.sh`.
- **Prebuilt releases**: the check first asks GitHub for the latest release with a `.dmg`; if its version is newer than the running one, the updater downloads it, verifies `SHA256SUMS`, unpacks, checks the signature and `--self-test`, then swaps with the same rollback script. No Xcode tools needed. With no release it falls back to the branch/source path above. The release path is covered by unit tests and a manual check of the mount/ditto/verify steps, but has **not** been run against a real published release.
- **Release tooling**: `scripts/make-dmg.sh VERSION`, `scripts/notarize.sh DMG` (needs a notarytool keychain profile), `.github/workflows/release.yml` (tag `vX.Y.Z` builds, tests, signs and notarizes if the secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` exist, then publishes the DMG and `SHA256SUMS`). `SIGN_IDENTITY="Developer ID Application: ..." scripts/bundle.sh` signs with the hardened runtime. Signing and notarization have not been run (no Developer ID here).
- **Benchmark**: Server and Library have a Benchmark button; it streams a fixed prompt, stores tokens/s per model in settings, and the Advisor uses measured speeds and a calibration factor (only from models with 3B+ active params; a 0.5B model measured 379 t/s on the M4 Max because small models are overhead bound, not bandwidth bound).
- **GPU limit persistence**: Memory screen "Keep after restart" installs `/Library/LaunchDaemons/com.mlxplayer.gpulimit.plist` through the admin prompt; Reset removes it. Plist and script are unit tested; the privileged install itself has not been run.

## Session notes (state sync, chat, Dock, updater)

- **Stale buttons fix**: supervisor state now flows through an ordered `AsyncStream` into `AppModel.handle(state:)`, and `startServer`/`stopServer`/the 1.5 s tick call `reconcileServerState()` (the supervisor is the source of truth). Before, `startServer` returned before `.running` reached the main actor, so the proxy's first on-demand request failed with `model_unavailable` and the UI lagged. `testStateCallbacksEndWhereTheSupervisorIs` pins the callback order.
- **Popover**: "This Mac" card (memory, GPU, VRAM vs GPU limit, pressure), loaded model marked in the switch list, usage refreshes every 3 s. Not in the original mockup; added on request. Render with `MLXPlayer --snapshot DIR popover [dark]`.
- **Chat** screen (sidebar): MacPaw `OpenAI` client streaming through the public port (loads the model on demand) and `swift-markdown-ui` for rendering. Chat history is in-memory only.
- **Dock icon**: the app is `LSUIElement`, but `DockPresence` switches to a regular app (Dock, Cmd-Tab) while the main window is open and back to menu-bar-only on close. Dock click reopens the window.
- **Updater**: log persists in `update.log`, download shows a real progress bar, and after the restart a toast says whether the update arrived or why not (`update-pending.json` records from/to). Note an installed build whose commit equals the branch head correctly reports "Up to date".
- **Menu bar popover is now `NSStatusItem` + `NSPopover`** (`AppController` in `MLXPlayerApp.swift`), not `MenuBarExtra`: on current macOS the `.window` style drew a detached panel with an empty strip and no arrow. The main window is an AppKit `NSWindow` hosting `MainWindow`; the App scene is only an empty `Settings`. `MLX_SHOW_POPOVER=1 open --env ... app` writes the popover and icon frames to `$TMPDIR/mlx-popover.txt`.
