# Roadmap

Status as of v0.1.3. Items are ordered by value to users.

## Verify on real hardware / in release

- [ ] Switch models while a server is loaded under real load (code handles it: waits for running requests, restores the previous model on failure; only compile-checked in the UI so far)
- [ ] Developer ID signing and notarization (workflow is written, no certificate has run it; `scripts/verify-release.sh vX.Y.Z` checks the result)
- [ ] Server on the local network: works over this Mac's own LAN address (endpoint, streaming, CORS, backend not exposed). Still to check from a real second device, and with the macOS firewall turned on (it is off on the dev Mac)
- [ ] GPU wired limit "Keep after restart" launch daemon (the privileged install has not been run)

## Build next

- [ ] Updater: delete or shrink the `source` clone (about 570 MB) after a successful update
- [ ] Local training (LoRA fine-tuning) with mlx-lm on Apple Silicon, native Metal, no Docker, no CUDA:
  - Dataset: pick or drop `train.jsonl` / `valid.jsonl` (ChatML pairs); validate format before starting
  - Train: run `mlx_lm.lora` through uv (`uv run --with mlx-lm ...`) on a chosen base model (e.g. Qwen2.5-Coder-1.5B-Instruct or 7B) with iterations and batch size; show live loss and progress; about 4-5 GB RAM and 5-10 minutes for the 1.5B model
  - Output: LoRA adapter saved to a local folder (e.g. `adapters/<name>`)
  - Optional fuse: bake the adapter into a standalone model (`mlx_lm.fuse`) at a chosen path
  - Serve: load the adapter or fused model in the existing server/model switcher, so it is reachable on the OpenAI-compatible endpoint (e.g. `http://127.0.0.1:8080/v1`)
  - Guard memory: refuse or warn when training would not fit next to the loaded model
- [ ] Playground screen (side-by-side prompts across models)
- [ ] Quality ranking from a refreshable benchmark table (today a size/quantization heuristic)
- [ ] Advisor free text understood by a model instead of keyword matching
- [ ] Remove the unused `logs/` folder, rotate `swap.log`

## Not planned

- Live "trim prompt cache": mlx-lm has no API, so the app restarts with a smaller cache when idle.
