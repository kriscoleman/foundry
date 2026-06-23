#!/usr/bin/env python3
"""Check that all relative markdown links in .md files resolve to existing files.

Skips:
  - Links inside fenced code blocks (``` ... ```)
  - Links inside inline code spans (` ... `)
  - Absolute URLs (http://, https://, etc.)
  - Anchor-only links (#section)
  - Plugin-root variables (${CLAUDE_PLUGIN_ROOT}/...)
  - Absolute paths (/foo/bar)
  - Template placeholders containing < or >
"""
import re
import sys
from pathlib import Path

LINK_PATTERN = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
CODE_FENCE = re.compile(r'^\s*```')
INLINE_CODE = re.compile(r'`[^`\n]+`')
SKIP_DIRS = {'.git', '.worktrees', 'node_modules', '__pycache__'}

# Parallel directory mappings: when skills/ and skill-refs/ both map to
# .claude/skills/ at cast time, links from skills/ to reference/ files
# that physically live in skill-refs/ should still resolve.
PARALLEL_DIRS = [('skills', 'skill-refs')]


def check_file(mdfile: Path) -> list:
    errors = []
    try:
        content = mdfile.read_text(encoding='utf-8', errors='replace')
    except OSError as e:
        return [f"{mdfile}: cannot read: {e}"]

    in_fence = False
    for lineno, line in enumerate(content.splitlines(), 1):
        # Track fenced code blocks
        if CODE_FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        # Strip inline code spans before scanning for links
        clean = INLINE_CODE.sub('', line)

        for match in LINK_PATTERN.finditer(clean):
            href = match.group(1).strip()

            # Skip: absolute URLs, anchors, variables, absolute paths
            if href.startswith(('http://', 'https://', 'ftp://', 'mailto:', '#', '${')):
                continue
            if href.startswith('/'):
                continue
            # Skip template placeholders
            if '<' in href or '>' in href:
                continue

            target = href.split('#')[0]
            if not target:
                continue

            resolved = (mdfile.parent / target).resolve()
            if not resolved.exists():
                # Try parallel directory fallback (e.g., skills/ ↔ skill-refs/)
                found = False
                for src, alt in PARALLEL_DIRS:
                    src_marker = f'/{src}/'
                    alt_marker = f'/{alt}/'
                    rstr = str(resolved)
                    if src_marker in rstr:
                        alt_path = Path(rstr.replace(src_marker, alt_marker, 1))
                        if alt_path.exists():
                            found = True
                            break
                    if alt_marker in rstr:
                        alt_path = Path(rstr.replace(alt_marker, src_marker, 1))
                        if alt_path.exists():
                            found = True
                            break
                if not found:
                    label = match.group(0)[:60]
                    errors.append(f"{mdfile}:{lineno}: broken link: {label}")

    return errors


def check_dir(root: Path) -> tuple:
    errors = []
    files_checked = 0

    for mdfile in sorted(root.rglob('*.md')):
        rel = mdfile.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        files_checked += 1
        errors.extend(check_file(mdfile))

    return errors, files_checked


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
    if not root.exists():
        print(f"error: directory not found: {root}", file=sys.stderr)
        sys.exit(1)

    errors, files_checked = check_dir(root)
    for e in errors:
        print(e)

    if errors:
        print(f"\n{len(errors)} broken link(s) found in {files_checked} files.")
        sys.exit(1)
    else:
        print(f"OK  check-md-links: {files_checked} files, no broken links.")


if __name__ == '__main__':
    main()
