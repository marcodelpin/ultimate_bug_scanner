#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
let ts;
try {
  ts = require('typescript');
} catch (err) {
  ts = null;
}

const projectDir = path.resolve(process.argv[2] || process.cwd());
const SKIP_DIRS = new Set(['.git', '.hg', '.svn', 'node_modules', 'dist', 'build', '.next', '.nuxt', '.turbo', '.expo']);
const EXTENSIONS = new Set(['.ts', '.tsx']);

function collectFiles(dir) {
  const results = [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name.startsWith('.')) {
      if (!['.ts', '.tsx'].includes(path.extname(entry.name))) {
        if (!entry.isFile()) continue;
      }
    }
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      results.push(...collectFiles(fullPath));
    } else if (entry.isFile()) {
      const ext = path.extname(entry.name).toLowerCase();
      if (EXTENSIONS.has(ext)) {
        results.push(fullPath);
      }
    }
  }
  return results;
}

function formatLocation(file, position, sourceText) {
  const lineStarts = [];
  let line = 1;
  for (let i = 0; i < sourceText.length; i++) {
    if (sourceText[i] === '\n') {
      lineStarts.push(i);
      line++;
    }
  }
  const lc = getLineAndColumn(sourceText, position);
  return `${file}:${lc.line}:${lc.column}`;
}

function getLineAndColumn(text, pos) {
  let line = 1;
  let column = 1;
  for (let i = 0; i < pos && i < text.length; i++) {
    if (text[i] === '\n') {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return { line, column };
}

function extractGuardedIdentifier(expr) {
  if (!ts) return null;
  if (ts.isBinaryExpression(expr)) {
    const op = expr.operatorToken.kind;
    if (
      op === ts.SyntaxKind.EqualsEqualsToken ||
      op === ts.SyntaxKind.EqualsEqualsEqualsToken
    ) {
      const left = ts.isIdentifier(expr.left) ? expr.left.text : null;
      const right = ts.isIdentifier(expr.right) ? expr.right.text : null;
      if (left && isNullish(expr.right)) {
        return left;
      }
      if (right && isNullish(expr.left)) {
        return right;
      }
      if (left && isUndefinedIdentifier(expr.right)) {
        return left;
      }
      if (right && isUndefinedIdentifier(expr.left)) {
        return right;
      }
      if (ts.isTypeOfExpression(expr.left) && ts.isStringLiteral(expr.right)) {
        const name = getIdentifierFromTypeOf(expr.left);
        if (name && expr.right.text === 'undefined') {
          return name;
        }
      }
      if (ts.isTypeOfExpression(expr.right) && ts.isStringLiteral(expr.left)) {
        const name = getIdentifierFromTypeOf(expr.right);
        if (name && expr.left.text === 'undefined') {
          return name;
        }
      }
    }
  }
  if (ts.isPrefixUnaryExpression(expr) && expr.operator === ts.SyntaxKind.ExclamationToken) {
    if (ts.isIdentifier(expr.operand)) {
      return expr.operand.text;
    }
  }
  return null;
}

function isNullish(node) {
  return (
    node.kind === ts.SyntaxKind.NullKeyword ||
    node.kind === ts.SyntaxKind.UndefinedKeyword
  );
}

function isUndefinedIdentifier(node) {
  return ts.isIdentifier(node) && node.text === 'undefined';
}

function getIdentifierFromTypeOf(typeOfExpr) {
  if (ts.isIdentifier(typeOfExpr.expression)) {
    return typeOfExpr.expression.text;
  }
  return null;
}

function blockHasExit(node) {
  if (!ts) return false;
  if (ts.isReturnStatement(node) || ts.isThrowStatement(node)) {
    return true;
  }
  if (ts.isBreakStatement(node) || ts.isContinueStatement(node)) {
    return true;
  }
  if (ts.isBlock(node)) {
    return node.statements.some((stmt) => blockHasExit(stmt));
  }
  if (ts.isIfStatement(node)) {
    if (!node.elseStatement) return false;
    return blockHasExit(node.thenStatement) && blockHasExit(node.elseStatement);
  }
  return false;
}

function statementRedefines(stmt, name) {
  if (!ts) return false;
  if (ts.isVariableStatement(stmt)) {
    return stmt.declarationList.declarations.some((decl) => ts.isIdentifier(decl.name) && decl.name.text === name);
  }
  if (ts.isExpressionStatement(stmt) && ts.isBinaryExpression(stmt.expression)) {
    const exp = stmt.expression;
    if (exp.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isIdentifier(exp.left)) {
      return exp.left.text === name;
    }
  }
  return false;
}

function findUsageInNode(node, name) {
  if (!ts) return null;
  let found = null;
  function walk(n) {
    if (found) return;
    if (ts.isPropertyAccessExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === name) {
      found = n.expression;
      return;
    }
    if (ts.isElementAccessExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === name) {
      found = n.expression;
      return;
    }
    if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && n.expression.text === name) {
      found = n.expression;
      return;
    }
    ts.forEachChild(n, walk);
  }
  walk(node);
  return found;
}

function findUsage(statements, name) {
  if (!ts) return null;
  for (const stmt of statements) {
    if (statementRedefines(stmt, name)) {
      return null;
    }
    const usage = findUsageInNode(stmt, name);
    if (usage) return usage;
  }
  return null;
}

function analyzeBlock(block, sourceFile, issues) {
  if (!ts) return;
  const statements = block.statements;
  for (let i = 0; i < statements.length; i++) {
    const stmt = statements[i];
    if (ts.isIfStatement(stmt)) {
      const guarded = extractGuardedIdentifier(stmt.expression);
      if (guarded && !stmt.elseStatement && !blockHasExit(stmt.thenStatement)) {
        const usage = findUsage(statements.slice(i + 1), guarded);
        if (usage) {
          const message = `Value '${guarded}' is checked for null/undefined but used later without exiting the guard`;
          issues.push({ pos: usage.getStart(sourceFile), message });
        }
      }
    }
  }
}

function analyzeWithTypescript(filePath) {
  const sourceText = fs.readFileSync(filePath, 'utf8');
  const scriptKind = filePath.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
  const sourceFile = ts.createSourceFile(filePath, sourceText, ts.ScriptTarget.Latest, true, scriptKind);
  const issues = [];
  function visit(node) {
    if (ts.isBlock(node)) {
      analyzeBlock(node, sourceFile, issues);
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return issues.map((issue) => {
    const lc = sourceFile.getLineAndCharacterOfPosition(issue.pos);
    return {
      file: filePath,
      line: lc.line + 1,
      column: lc.character + 1,
      message: issue.message,
    };
  });
}

function fallbackAnalyze(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const lines = text.split(/\r?\n/);
  const issues = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const guardMatch = line.match(/if\s*\(\s*!([A-Za-z_$][\w$]*)\s*\)/) || line.match(/if\s*\(\s*([A-Za-z_$][\w$]*)\s*===?\s*(?:null|undefined)\s*\)/);
    if (!guardMatch) continue;
    const name = guardMatch[1];
    let exits = false;
    for (let j = i + 1; j < Math.min(lines.length, i + 6); j++) {
      const inner = lines[j];
      if (/return\b|throw\b|continue\b|break\b/.test(inner)) {
        exits = true;
        break;
      }
      if (/\}/.test(inner)) break;
    }
    if (exits) continue;
    for (let j = i + 1; j < Math.min(lines.length, i + 25); j++) {
      if (new RegExp(`${name}\s*[.\[]`).test(lines[j])) {
        issues.push({
          file: filePath,
          line: j + 1,
          column: lines[j].indexOf(name) + 1,
          message: `Value '${name}' checked earlier but used without return (text heuristic)`
        });
        break;
      }
      if (new RegExp(`${name}\s*=`).test(lines[j])) break;
    }
  }
  return issues;
}

function main() {
  const files = collectFiles(projectDir);
  if (files.length === 0) {
    return;
  }
  const allIssues = [];
  for (const file of files) {
    let issues;
    if (ts) {
      issues = analyzeWithTypescript(file);
    } else {
      issues = fallbackAnalyze(file);
    }
    allIssues.push(...issues);
  }
  for (const issue of allIssues) {
    console.log(`${issue.file}:${issue.line}:${issue.column}\t${issue.message}`);
  }
  if (!ts && allIssues.length === 0) {
    console.error("[ubs-type-narrowing] typescript module not found; install it with 'npm install typescript' for stronger analysis.");
  }
}

main();
