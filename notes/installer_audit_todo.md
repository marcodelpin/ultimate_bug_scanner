# Installer Audit TODO

- [x] Fix `detect_coding_agents()` so it never exits non-zero under `set -e` and always returns success (guard each heuristic, add explicit `return 0`, ensure `.replit` detection uses both repo and `$HOME` paths).
- [x] Ensure `--no-path-modify` also skips `create_alias()` (log that alias creation is skipped instead of writing to rc files).
- [x] Synchronize the installer `VERSION` constant with the root `VERSION` file (target 4.6.0 everywhere).
- [x] Add installer regression tests under `test-suite/install/` that spin up a disposable HOME, run `install.sh` with non-interactive flags, and assert the run reaches post-install verification without touching rc files when `--no-path-modify` is set.
- [x] Document the new behavior in README/INSTALL notes (alias skipping, how to run installer tests, updated version badge/info).
