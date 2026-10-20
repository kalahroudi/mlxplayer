<p align="center">
  <img src="docs/images/logo.png" width="128" alt="MLX Player logo">
</p>

<h1 align="center">MLX Player</h1>

<p align="center">
  A native macOS menu bar app that installs and runs <code>mlx-lm</code>, finds models that fit your Mac,<br>
  and serves them on a local OpenAI-compatible endpoint.
</p>

<p align="center">
  <img src="docs/images/overview-dark.png" alt="MLX Player overview: memory, GPU, VRAM and CPU gauges" width="860">
</p>

<p align="center">
  <a href="https://kalahroudi.github.io/mlxplayer/">Website</a> ·
  <a href="https://github.com/kalahroudi/mlxplayer/releases/latest">Download</a> ·
  <a href="#install-with-your-ai-agent">Install with your agent</a>
</p>

## What it does

- **One-click setup.** Installs `uv`, a private Python 3.12 and `mlx-lm` under `~/Library/Application Support/MLX Player/`. No admin rights, nothing global.
- **Discover and download** MLX models from Hugging Face, with filters (size, quantization, capability, family, Standard / Uncensored / Abliterated) and a fit badge for your Mac.
- **Advisor.** Tells you what will actually run: fit (comfortable, tight, won't fit), a safe context size, estimated and measured tokens/s.
- **Local server** at `http://127.0.0.1:8080/v1`. A lazy proxy loads the model on the first request, unloads it when idle, enforces the context limit, streams SSE and meters usage.
- **Memory aware.** Live memory, GPU, VRAM and CPU view, GPU wired limit control, automatic responses to memory pressure.
- **Library, Usage, Logs, Chat** screens, plus a Hugging Face token kept in the Keychain.
- **Agent access** through an MCP server, so tools like Claude Code can manage models for you (see below).

## Install with your AI agent

Paste this into your agent (Claude Code, Cursor, Codex, etc.). If you are an agent, follow it. It installs MLX Player and connects it over MCP.

````text
Install MLX Player (https://github.com/kalahroudi/mlxplayer) on this Mac and connect it to me.

1. Check prerequisites: `uname -m` must print `arm64` and `sw_vers -productVersion` must be 14 or newer.
2. Install the latest release (no Xcode needed):
   cd "$(mktemp -d)" && gh release download --repo kalahroudi/mlxplayer --pattern 'MLX-Player-*.dmg' --pattern SHA256SUMS
   (or curl the DMG and SHA256SUMS from https://github.com/kalahroudi/mlxplayer/releases/latest)
   Verify with `shasum -a 256 -c SHA256SUMS`, then `hdiutil attach` the DMG and copy "MLX Player.app" to /Applications.
   If there is no release or the download fails, build from source instead: `xcode-select -p` must succeed
   (otherwise tell me to run `xcode-select --install` and wait), then
   git clone https://github.com/kalahroudi/mlxplayer.git ~/mlxplayer && cd ~/mlxplayer && scripts/bundle.sh
   and copy dist/"MLX Player.app" to /Applications.
3. Launch it with `open "/Applications/MLX Player.app"`. Tell me to right-click > Open if macOS blocks it.
4. First run: the app's Setup screen installs uv, Python and mlx-lm. Ask me to click through it,
   or tell me it is already done if Settings shows mlx-lm installed.
5. Register the MCP server for yourself:
   claude mcp add -s user mlxplayer -- "/Applications/MLX Player.app/Contents/MacOS/mlxplayer-mcp"
   (For other agents, add a stdio MCP server named `mlxplayer` with that command.)
   Then restart or reload so the tools appear.
6. Verify by calling `get_hardware` and `get_status`. Report the chip, memory and server state.
7. Do not download or load a model, or change settings, until I approve. Use `recommend_models` and show me the options first.
````

## Requirements

- Apple Silicon Mac, macOS 14 or newer
- Xcode command line tools (`xcode-select --install`) to build from source
- Git

## Install manually

Download the DMG from [Releases](https://github.com/kalahroudi/mlxplayer/releases/latest), or build from source:

```sh
git clone https://github.com/kalahroudi/mlxplayer.git
cd mlxplayer
scripts/bundle.sh            # builds dist/MLX Player.app
open "dist/MLX Player.app"
```

Optional: copy it to `/Applications`. The build is ad-hoc signed, so on first launch right-click the app and choose Open once.
The app can update itself from this repo (Settings > Updates).

To build a disk image: `scripts/make-dmg.sh VERSION`. Tagging `vX.Y.Z` runs `.github/workflows/release.yml`, which builds, tests and publishes the DMG.

## Use the endpoint

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Hello"}]}'
```

Point any OpenAI-compatible client at `http://127.0.0.1:8080/v1` (any API key value works). The model loads on the first request.

To reach it from another computer, set Server > Network > Host to "Local network" (the app copies this Mac's LAN URL) or "Tailscale" (only your tailnet devices can connect; the app publishes HTTPS with `tailscale serve` and copies your `https://*.ts.net` URL). Nothing to configure by hand.

## Switch models

Only one model is loaded at a time. You can switch from the sidebar, the menu bar popover or the Library screen.

- A switch waits for running requests to finish (up to 60 s) so no reply is cut off.
- If the new model fails to load, the previous one is brought back, so the endpoint is not left empty.
- Clients can switch too: with **Switch by request** on (Memory > Loading), the `model` field of a request loads that installed model. Turn it off and every request uses the loaded model.

## Agent access (MCP)

Once installed (see above), agents drive MLX Player over MCP.

### MCP tools

The MCP server is `mlxplayer-mcp` (stdio), bundled at `MLX Player.app/Contents/MacOS/mlxplayer-mcp`. The app must be running for the control tools.

| Tool | What it does | Asks you first |
|---|---|---|
| `get_hardware` | Chip, memory, GPU memory limit, bandwidth, usable memory for a model | No |
| `search_models` | Search MLX models on Hugging Face | No |
| `analyze_model` | Fit, context size, speed estimate and memory breakdown for a model | No |
| `recommend_models` | Best overall, highest quality and fastest model for a job | No |
| `get_status` | Server state, loaded model, endpoint, memory and speed | No |
| `download_model` | Download a model into the Hugging Face cache | Yes |
| `start_server` | Load a model and start the server (optional `context_length`, `thinking`) | Yes |
| `update_settings` | Change saved settings for a model | Yes |
| `stop_server` | Stop the server and free memory | Yes |
| `delete_model` | Delete a downloaded model | Always |

The app detects Claude Code, Claude Desktop, Cursor, Windsurf, Gemini CLI and Codex CLI and connects or disconnects each with one click: Settings > Agents (MCP). It uses the agent's own CLI where it has one and otherwise edits its config file (keeping a one-time backup). Control calls go through a loopback API protected by a bearer token (`control.json`, mode 0600), and actions that change state show an approval dialog.

## Development

```sh
swift build        # core, MCP server and the macOS app
swift test         # 94 tests (the proxy streaming tests need python3)
swift run mlxplayer-mcp
MLXPlayer --snapshot DIR [dark] [collapsed] [screen]   # render screens to PNG (used for the images above)
```

Layout:

| Path | Contents |
|---|---|
| `Sources/MLXPlayerCore` | UI-free logic: hardware, advisor, installer, server supervisor, lazy proxy, usage, memory policy, Hugging Face client, MCP, agent integrations |
| `Sources/MLXPlayer` | The macOS app (SwiftUI + AppKit) |
| `Sources/mlxplayer-mcp` | Stdio MCP server |
| `scripts/` | Bundle, DMG and notarization scripts |
| `design/` | Approved mockups (open the `*.dc.html` files in a browser) |

Notes: the sandbox must stay off because the app spawns processes. `mlx_lm.server` has no `--max-kv-size` in 0.32.2, so the proxy enforces context limits by estimating tokens.

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
