#!/usr/bin/env python3
"""AST-based detector for Python resource lifecycle issues."""
from __future__ import annotations

import ast
import sys
from pathlib import Path
from typing import Iterable, Optional

TARGET_SIGS: dict[tuple[Optional[str], str], str] = {
    (None, "open"): "file_handle",
    ("builtins", "open"): "file_handle",
    ("io", "open"): "file_handle",
    ("pathlib", "open"): "file_handle",
    ("pathlib.Path", "open"): "file_handle",
    ("tempfile", "NamedTemporaryFile"): "file_handle",
    ("tempfile", "TemporaryFile"): "file_handle",
    ("tempfile", "SpooledTemporaryFile"): "file_handle",
    ("socket", "socket"): "socket_handle",
    ("socket", "create_connection"): "socket_handle",
    ("socket", "socketpair"): "socket_handle",
    ("subprocess", "Popen"): "popen_handle",
    ("asyncio", "create_task"): "asyncio_task",
}

RELEASE_METHODS = {
    "file_handle": {"close"},
    "socket_handle": {"close", "shutdown"},
    "popen_handle": {"wait", "communicate", "terminate", "kill"},
    "asyncio_task": {"cancel"},
}

TASK_RELEASE_SIGS = {
    ("asyncio", "gather"),
    ("asyncio", "wait"),
    ("asyncio", "wait_for"),
}

MESSAGE_TEMPLATES = {
    "file_handle": "File handle {name} opened without context manager or close()",
    "socket_handle": "Socket {name} opened without close()",
    "popen_handle": "subprocess handle {name} never waited/terminated",
    "asyncio_task": "asyncio task {name} neither awaited nor cancelled",
}

IGNORED_PARTS = {
    ".git",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "node_modules",
    "dist",
    "build",
    ".venv",
    "venv",
    "env",
    "envs",
    "site-packages",
    "target",
}


class ResourceRecord:
    __slots__ = ("name", "kind", "lineno", "released")

    def __init__(self, name: Optional[str], kind: str, lineno: int) -> None:
        self.name = name
        self.kind = kind
        self.lineno = lineno
        self.released = False


class Scope:
    def __init__(self) -> None:
        self.aliases: dict[str, tuple[Optional[str], Optional[str]]] = {}
        self.by_name: dict[str, list[ResourceRecord]] = {}


class Analyzer(ast.NodeVisitor):
    def __init__(self, tree: ast.AST) -> None:
        self.tree = tree
        self.records: list[ResourceRecord] = []
        self.safe_calls: set[int] = set()
        self.assigned_calls: set[int] = set()
        self.scope_stack: list[Scope] = [Scope()]

    @property
    def current_scope(self) -> Scope:
        return self.scope_stack[-1]

    def _lookup_alias(self, name: str) -> tuple[Optional[str], Optional[str]]:
        for scope in reversed(self.scope_stack):
            if name in scope.aliases:
                return scope.aliases[name]
        return (None, None)

    # Scopes -------------------------------------------------------------
    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.scope_stack.append(Scope())
        self.generic_visit(node)
        self.scope_stack.pop()

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self.scope_stack.append(Scope())
        self.generic_visit(node)
        self.scope_stack.pop()

    # Imports -------------------------------------------------------------
    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            asname = alias.asname or alias.name
            self.current_scope.aliases[asname] = (alias.name, None)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        module = node.module or ""
        for alias in node.names:
            if alias.name == "*":
                continue
            asname = alias.asname or alias.name
            self.current_scope.aliases[asname] = (module, alias.name)

    # Return/Yield -------------------------------------------------------
    def visit_Return(self, node: ast.Return) -> None:
        if node.value:
            self._handle_return_yield(node.value)
        self.generic_visit(node)

    def visit_Yield(self, node: ast.Yield) -> None:
        if node.value:
            self._handle_return_yield(node.value)
        self.generic_visit(node)

    def visit_YieldFrom(self, node: ast.YieldFrom) -> None:
        if node.value:
            self._handle_return_yield(node.value)
        self.generic_visit(node)

    def _handle_return_yield(self, value: ast.AST) -> None:
        # Returning/yielding a resource is an *escape*, not a cleanup. UBS should still
        # report resources that were acquired but never explicitly closed/cancelled.
        #
        # This intentionally errs on the side of catching leaks: callers frequently
        # forget to close handles returned from helpers, and our scanning target is
        # "likely bugs" rather than enforcing ownership conventions.
        _ = value

    # With/async with -----------------------------------------------------
    def visit_With(self, node: ast.With) -> None:
        self._mark_context_safe(node.items)
        self.generic_visit(node)

    def visit_AsyncWith(self, node: ast.AsyncWith) -> None:
        self._mark_context_safe(node.items)
        self.generic_visit(node)

    def _mark_context_safe(self, items: list[ast.withitem]) -> None:
        for item in items:
            self._mark_safe_calls(item.context_expr)

    def _mark_safe_calls(self, expr: ast.AST) -> None:
        if isinstance(expr, ast.Call):
            sig = self._call_signature(expr)
            if sig and sig in TARGET_SIGS:
                self.safe_calls.add(id(expr))
            for arg in expr.args:
                self._mark_safe_calls(arg)
            for kw in expr.keywords:
                if kw.value is not None:
                    self._mark_safe_calls(kw.value)
        elif isinstance(expr, ast.Attribute) and expr.value is not None:
            self._mark_safe_calls(expr.value)

    # Assignments --------------------------------------------------------
    def visit_Assign(self, node: ast.Assign) -> None:
        self._handle_assignment(node.targets, node.value)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            self._handle_assignment([node.target], node.value)
        self.generic_visit(node)

    def _handle_assignment(self, targets: list[ast.expr], value: ast.AST) -> None:
        sig = self._call_signature_from_expr(value)
        if not sig:
            return
        kind = TARGET_SIGS.get(sig)
        if not kind:
            return
        self.assigned_calls.add(id(value))
        names = [name for target in targets for name in self._collect_names(target)]
        if not names:
            self._add_record(None, kind, value.lineno)
            return
        for name in names:
            self._add_record(name, kind, value.lineno)

    def _collect_names(self, node: ast.AST) -> list[str]:
        if isinstance(node, (ast.Tuple, ast.List)):
            names: list[str] = []
            for elt in node.elts:
                names.extend(self._collect_names(elt))
            return names
        if isinstance(node, ast.Name):
            return [node.id]
        if isinstance(node, ast.Attribute):
            dotted = self._dotted_name(node)
            return [dotted] if dotted else []
        return []

    # Calls/releases -----------------------------------------------------
    def visit_Call(self, node: ast.Call) -> None:
        if id(node) not in self.assigned_calls:
            sig = self._call_signature(node)
            if sig and sig in TARGET_SIGS and id(node) not in self.safe_calls:
                self._add_record(None, TARGET_SIGS[sig], node.lineno)
        self._handle_release(node)
        self.generic_visit(node)

    def visit_Await(self, node: ast.Await) -> None:
        if isinstance(node.value, ast.Name):
            self._mark_released(node.value.id, "asyncio_task")
        self.generic_visit(node)

    def _handle_release(self, node: ast.Call) -> None:
        func = node.func
        if isinstance(func, ast.Attribute):
            name = self._dotted_name(func.value)
            method = func.attr
            for kind, methods in RELEASE_METHODS.items():
                if method in methods:
                    self._mark_released(name, kind)
                    break

        sig = self._call_signature(node)
        if sig in TASK_RELEASE_SIGS:
            for arg_name in self._iter_task_args(node.args):
                self._mark_released(arg_name, "asyncio_task")
            for kw in node.keywords:
                if kw.value is not None:
                    for arg_name in self._iter_task_args([kw.value]):
                        self._mark_released(arg_name, "asyncio_task")

    def _iter_task_args(self, args: Iterable[ast.AST]) -> Iterable[str]:
        for arg in args:
            if isinstance(arg, ast.Name):
                yield arg.id
            elif isinstance(arg, (ast.Tuple, ast.List, ast.Set)):
                for elt in arg.elts:
                    yield from self._iter_task_args([elt])

    # Helpers ------------------------------------------------------------
    def _mark_released(self, name: Optional[str], kind: Optional[str], check_all_scopes: bool = False) -> None:
        if not name:
            return
        
        scopes_to_check = reversed(self.scope_stack) if check_all_scopes else [self.current_scope]
        
        for scope in scopes_to_check:
            entries = scope.by_name.get(name)
            if not entries:
                continue
            for rec in entries:
                if not rec.released and (kind is None or rec.kind == kind):
                    rec.released = True
                    # If we released one, we assume we released the most relevant one.
                    # Should we keep searching other scopes? 
                    # If I return f, I release the local f. If f captured outer f, it releases that too?
                    # Python variables are refs. If I return f, the object is passed.
                    # The lifecycle responsibility transfers. So yes, mark it released.
                    return

    def _add_record(self, name: Optional[str], kind: str, lineno: int) -> None:
        rec = ResourceRecord(name, kind, lineno)
        self.records.append(rec)
        if name:
            self.current_scope.by_name.setdefault(name, []).append(rec)

    def _call_signature_from_expr(self, expr: ast.AST) -> Optional[tuple[Optional[str], str]]:
        if isinstance(expr, ast.Call):
            return self._call_signature(expr)
        return None

    def _call_signature(self, call: ast.Call) -> Optional[tuple[Optional[str], str]]:
        func = call.func
        if isinstance(func, ast.Name):
            module, obj = self._lookup_alias(func.id)
            if obj:
                return (module, obj)
            return (module, func.id)
        if isinstance(func, ast.Attribute):
            base = func.value
            attr = func.attr
            if isinstance(base, ast.Name):
                module, obj = self._lookup_alias(base.id)
                # If base.id is not aliased, it might be a module name or object
                if obj:
                    module = module or obj
                else:
                    # e.g. os.path.join -> base.id="os"
                    # _lookup_alias("os") -> (None, None) usually if just imported
                    # Wait: for "import os", alias == "os" -> ("os", None)
                    pass
                
                # If we didn't find an alias, check if it matches a known structure
                if not module and not obj:
                     # Check if we have an alias that matches base.id
                     # (handled by _lookup_alias returning (None,None))
                     pass

                return (module or base.id, attr)
            if isinstance(base, ast.Attribute):
                dotted = self._dotted_name(base)
                if dotted:
                    return (dotted, attr)
            if isinstance(base, ast.Call):
                inner = self._call_signature(base)
                if inner:
                    module, obj = inner
                    module_name = module or ""
                    if obj:
                        module_name = f"{module}.{obj}" if module else obj
                    return (module_name or obj, attr)
        return None

    def _dotted_name(self, expr: ast.expr) -> Optional[str]:
        if isinstance(expr, ast.Name):
            return expr.id
        if isinstance(expr, ast.Attribute):
            base = self._dotted_name(expr.value)
            if base:
                return f"{base}.{expr.attr}"
        return None

    def report(self, path: Path) -> list[str]:
        issues: list[str] = []
        for rec in sorted(self.records, key=lambda r: (r.lineno, r.kind, r.name or "")):
            if rec.released:
                continue
            template = MESSAGE_TEMPLATES.get(rec.kind, "Resource not released")
            subject = rec.name or rec.kind
            message = template.format(name=subject)
            issues.append(f"{path}:{rec.lineno}\t{rec.kind}\t{message}")
        return issues


def collect_files(root: Path) -> list[Path]:
    files: list[Path] = []
    if root.is_file() and root.suffix == ".py":
        return [root]
    for path in root.rglob("*.py"):
        if any(part in IGNORED_PARTS for part in path.parts):
            continue
        files.append(path)
    return files


def analyze(path: Path, root: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"WARN: Could not read {path}: {e}", file=sys.stderr)
        return []
    try:
        tree = ast.parse(text)
    except SyntaxError as e:
        print(f"WARN: Syntax error in {path}: {e}", file=sys.stderr)
        return []
    analyzer = Analyzer(tree)
    analyzer.visit(tree)
    display: Path
    try:
        display = path.relative_to(root)
    except ValueError:
        display = path
    return analyzer.report(display)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: resource_lifecycle_py.py <project_dir>", file=sys.stderr)
        sys.exit(2)
    root = Path(sys.argv[1])
    issues: list[str] = []
    for path in sorted(collect_files(root), key=lambda p: str(p)):
        issues.extend(analyze(path, root))
    if issues:
        print("\n".join(issues))


if __name__ == "__main__":
    main()
