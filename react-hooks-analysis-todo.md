# React Hooks Dependency Analysis TODO

## Research & Planning
- [x] Re-read Feature #3 section in PLAN to capture detection goals (useEffect/useMemo/useCallback, missing deps, stale closures, circular refs).
- [ ] Define shared metadata arrays (HOOK_RULE_IDS, summary, remediation, severity) similar to async/resource helpers.

## Implementation (JavaScript/TypeScript module)
- [ ] Add AST-based helper in `modules/ubs-js.sh` (e.g., `run_hooks_dependency_checks`).
- [ ] Detect:
  - [ ] Hooks that reference identifiers not listed in dependency array.
  - [ ] Dependency arrays containing values not referenced (potential stale closures or mistakes).
  - [ ] Inline functions without dependency array (e.g., `useEffect(() => {...})` missing second argument).
- [ ] Ensure helper emits warnings with sample locations (similar Python summaries used elsewhere).
- [ ] Wire helper at end of async/React-related category.

## Fixtures & Tests
- [ ] Add buggy React hooks fixture demonstrating missing deps etc. under `test-suite/js/buggy/react_hooks.js` (or similar).
- [ ] Add clean fixture with correct deps.
- [ ] Update `test-suite/manifest.json` with new cases (buggy + clean) referencing `--only=js`.
- [ ] Run targeted manifest cases for new fixtures.

## Verification & Follow-up
- [ ] Integrate helper invocation into README/docs if needed (mention capability).
- [ ] Update TODO as tasks complete and summarize in final report.
