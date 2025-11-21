#!/usr/bin/env python3
import sys, re, io
from pathlib import Path

# Robust I/O handling for varied environments
try:
    input_stream = io.TextIOWrapper(sys.stdin.buffer, encoding='utf-8', errors='replace')
    output_stream = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
except Exception:
    input_stream = sys.stdin
    output_stream = sys.stdout

ANSI_ESCAPE = re.compile(r'\x1B(?:[@-Z\-_]|[0-?]*[ -/]*[@-~])')
FINDING_PATTERN = re.compile(r'^\s*([^:\s]+):(\d+)(?::(\d+))?')
SUPPRESSION_MARKERS = ["ubs:ignore", "ubs: disable", "nolint", "noqa"]

def strip_ansi(text):
    return ANSI_ESCAPE.sub('', text)

def has_suppression(line_content):
    if not line_content: return False
    lower = line_content.lower()
    return any(m in lower for m in SUPPRESSION_MARKERS)

def main():
    try:
        # Read all lines first to ensure we consume the stream (prevents SIGPIPE upstream)
        lines = input_stream.readlines()
        
        file_cache = {}
        
        for line in lines:
            clean_line = strip_ansi(line)
            match = FINDING_PATTERN.match(clean_line)
            
            if not match:
                output_stream.write(line)
                continue
            
            file_path_str = match.group(1)
            try:
                line_no = int(match.group(2))
            except ValueError:
                output_stream.write(line)
                continue
            
            if file_path_str not in file_cache:
                try:
                    p = Path(file_path_str)
                    # Simple check; caching None if failure to avoid retry
                    if p.is_file():
                        file_cache[file_path_str] = p.read_text(encoding='utf-8', errors='replace').splitlines()
                    else:
                        file_cache[file_path_str] = None
                except:
                    file_cache[file_path_str] = None
            
            content = file_cache[file_path_str]
            suppressed = False
            if content:
                idx = line_no - 1
                if 0 <= idx < len(content) and has_suppression(content[idx]):
                    suppressed = True
                elif 0 <= idx-1 < len(content) and has_suppression(content[idx-1]):
                    suppressed = True
            
            if not suppressed:
                output_stream.write(line)
                
    except Exception as e:
        # If python fails, we MUST consume stdin and dump to stdout to avoid breaking the pipe
        # forcing upstream tools to exit with SIGPIPE
        sys.stderr.write(f"[ubs] warning: inline suppression failed ({e}); passthrough enabled\n")
        try:
            # Try to dump what we read plus the rest
            for l in lines: output_stream.write(l)
            output_stream.write(input_stream.read())
        except:
            pass

if __name__ == "__main__":
    main()
