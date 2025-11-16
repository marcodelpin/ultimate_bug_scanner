# Async Error Path Coverage TODO

## Research & Planning
- [x] Re-read PLAN_FOR_NEXT_FEATURES and capture async error path requirements.
- [x] Identify desired shared helper shape (rule id metadata arrays + `run_async_error_checks`).
- [x] Confirm per-language async patterns + severity/remediation strings captured in TODO for quick review updates.

## Implementation Tracking
### JavaScript
- [x] Define ASYNC_ERROR_RULE_IDS/SUMMARY/REMEDIATION/SEVERITY.
- [x] Implement ast-grep rule pack (await outside try/catch, Promise.then w/out catch, Promise.all w/out try).
- [x] Wire `run_async_error_checks` and call near async category.

### Python
- [x] Define metadata arrays.
- [x] Add ast-grep rules (await outside try/except, asyncio.create_task not awaited/cancelled).
- [x] Wire helper + call near async coverage.

### Go
- [x] Define metadata arrays.
- [x] Add ast-grep rule for goroutine ignoring errors / lacking error channel send.
- [x] Wire helper + call after concurrency checks.

### C++
- [x] Define metadata arrays.
- [x] Add ast-grep rules (std::async outside try/catch, std::future never get/wait).
- [x] Wire helper + call.

### Rust
- [x] Define metadata arrays.
- [x] Add ast-grep rules (await without match/? handling, tokio::spawn handle dropped).
- [x] Wire helper + call.

### Java
- [x] Define metadata arrays.
- [x] Add ast-grep rules (CompletableFuture get/join without try/catch, then* without exceptionally/handle).
- [x] Wire helper + call.

### Ruby
- [x] Define metadata arrays.
- [x] Add ast-grep rules (Thread.new body lacking rescue).
- [x] Wire helper + call.

## Fixtures & Tests
- [x] Add failing/clean fixtures for JS.
- [x] Add failing/clean fixtures for Python.
- [x] Add failing/clean fixtures for Go.
- [x] Add failing/clean fixtures for C++.
- [x] Add failing/clean fixtures for Rust.
- [x] Add failing/clean fixtures for Java.
- [x] Add failing/clean fixtures for Ruby.
- [x] Update test-suite/manifest.json with new cases per language (covering fail + clean expectations, threshold counts).
- [ ] Run targeted UBS manifest(s) to validate new checks fire; capture summary in notes/issue.

## Documentation / Handoff
- [ ] Mention TODO status in final summary and update file as tasks complete.
- [ ] Close issue ultimate_bug_scanner-e3j once scanner + tests + manifest updates done and UBS run clean.
