# Roadmap

Status as of v0.1.0. Items are ordered by value to users.

## Verify on real hardware / in release

- [ ] Switch models while a server is loaded under real load (code handles it: waits for running requests, restores the previous model on failure; only compile-checked in the UI so far)
- [ ] Update from a real published release (v0.1.0 is the first, so test 0.1.0 to 0.1.1)
- [ ] Developer ID signing and notarization (workflow is written, no certificate has run it)
- [ ] GPU wired limit "Keep after restart" launch daemon (the privileged install has not been run)
- [ ] Memory pressure responses under real pressure

## Build next

- [ ] Updater: delete or shrink the `source` clone (about 570 MB) after a successful update
- [ ] Playground screen (side-by-side prompts across models)
- [ ] Quality ranking from a refreshable benchmark table (today a size/quantization heuristic)
- [ ] Advisor free text understood by a model instead of keyword matching
- [ ] Remove the unused `logs/` folder, rotate `swap.log`

## Done recently

- [x] Usage log pruned on disk (30 days)
- [x] Chat survives leaving the screen and is saved (last 100 turns, Clear deletes it)
- [x] Global model switcher, styled dropdowns, live speed tile
- [x] Apache 2.0, README, GitHub Pages, v0.1.0 release

## Not planned

- Live "trim prompt cache": mlx-lm has no API, so the app restarts with a smaller cache when idle.
