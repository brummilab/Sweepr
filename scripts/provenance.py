#!/usr/bin/env python3
"""Measure how much of the current text still matches the original import commit.

Advisory only: not part of the gate. For every file it compares the text in
the working tree with the same file (or its rename source) in the original
import commit 37b61b6 and counts substantive lines:

  unchanged  line equal to an old line at the matching place
  modified   line in a changed block that is at least 60 % similar to an old line
  moved      new file only: line inside a run of 3 or more consecutive lines that
             also occurs as a run anywhere in the original import commit
  new        everything else

A substantive line is a trimmed line of at least 8 characters with a letter or
digit. Product and owner names are normalised before comparing, so a pure
rename still counts as unchanged. "share" is (unchanged + modified) / lines for
files from the import commit; for new files it is moved / lines once that
reaches the moved threshold (default 10 %), else 0. Line matching does not catch
paraphrase or a copied structure; the numbers are a lower bound.

Usage:
  python3 scripts/provenance.py [paths...] [--json] [--base REV]

Without paths every tracked file is measured. Paths may be files
or folders, tracked or not yet tracked. Needs the original import commit in the
local history (a full clone, not a shallow one). Python 3 standard library only.
"""

import argparse
import collections
import difflib
import json
import os
import re
import subprocess
import sys

BASE_DEFAULT = "37b61b6"
MIN_LENGTH = 8
SIMILARITY = 0.6
BLOCK_LINES = 3
MAX_COMPARE = 400

NORMALISE = [
    (re.compile(r"freemole|sweepr|mole", re.IGNORECASE), "NAME"),
    (re.compile(r"\b(fm|sw|mo)\b"), "CMD"),
    (re.compile(r"brummilab|tw93", re.IGNORECASE), "OWNER"),
]
HAS_WORD = re.compile(r"[A-Za-z0-9]")
SPACES = re.compile(r"\s+")


def git(root, *args, check=True):
    result = subprocess.run(["git", "-C", root, *args], capture_output=True, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result


def normalise(line):
    text = line.strip()
    for pattern, replacement in NORMALISE:
        text = pattern.sub(replacement, text)
    return SPACES.sub(" ", text)


def substantive_lines(data):
    """Normalised substantive lines of a text, or None for binary content."""
    if b"\0" in data:
        return None
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None
    lines = (normalise(line) for line in text.splitlines())
    return [line for line in lines if len(line) >= MIN_LENGTH and HAS_WORD.search(line)]


def best_similarity(line, candidates):
    best = 0.0
    for old in candidates:
        matcher = difflib.SequenceMatcher(None, old, line)
        if matcher.real_quick_ratio() < SIMILARITY or matcher.quick_ratio() < SIMILARITY:
            continue
        best = max(best, matcher.ratio())
        if best >= SIMILARITY:
            break
    return best


def compare(old, cur):
    """Count unchanged, modified and new lines of cur against old."""
    counts = collections.Counter()
    matcher = difflib.SequenceMatcher(None, old, cur, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            counts["unchanged"] += j2 - j1
        elif tag == "insert":
            counts["new"] += j2 - j1
        elif tag == "replace":
            candidates = old[i1:i2][:MAX_COMPARE]
            for line in cur[j1:j2]:
                if best_similarity(line, candidates) >= SIMILARITY:
                    counts["modified"] += 1
                else:
                    counts["new"] += 1
    return counts


def moved_lines(cur, base_runs):
    hit = [False] * len(cur)
    for i in range(len(cur) - BLOCK_LINES + 1):
        if tuple(cur[i:i + BLOCK_LINES]) in base_runs:
            for k in range(i, i + BLOCK_LINES):
                hit[k] = True
    return sum(hit)


class Base:
    def __init__(self, root, rev):
        self.root = root
        self.rev = rev
        self.files = set(git(root, "ls-tree", "-r", "--name-only", rev).stdout.decode("utf-8", "replace").splitlines())
        self.renames = {}
        diff = git(root, "diff", "-M30", "--name-status", rev).stdout.decode("utf-8", "replace")
        for row in diff.splitlines():
            parts = row.split("\t")
            if parts[0].startswith("R") and len(parts) == 3:
                self.renames[parts[2]] = parts[1]
        self._lines = {}
        self._runs = None

    def source_of(self, path):
        if path in self.renames:
            return self.renames[path]
        return path if path in self.files else None

    def lines(self, path):
        if path not in self._lines:
            self._lines[path] = substantive_lines(git(self.root, "show", f"{self.rev}:{path}").stdout)
        return self._lines[path]

    def runs(self):
        if self._runs is None:
            self._runs = set()
            for path in self.files:
                lines = self.lines(path)
                if not lines:
                    continue
                for i in range(len(lines) - BLOCK_LINES + 1):
                    self._runs.add(tuple(lines[i:i + BLOCK_LINES]))
        return self._runs


def measure(root, path, base, threshold):
    with open(os.path.join(root, path), "rb") as handle:
        cur = substantive_lines(handle.read())
    if cur is None:
        return None
    row = {"path": path, "source": base.source_of(path), "lines": len(cur),
           "unchanged": 0, "modified": 0, "moved": 0, "new": 0}
    old = base.lines(row["source"]) if row["source"] else None
    if old is not None:
        row.update(compare(old, cur))
        counted = row["unchanged"] + row["modified"]
    else:
        row["source"] = None
        row["moved"] = moved_lines(cur, base.runs())
        row["new"] = len(cur) - row["moved"]
        counted = row["moved"] if cur and 100 * row["moved"] / len(cur) >= threshold else 0
    row["share"] = round(100 * counted / len(cur), 1) if cur else 0.0
    row["counted"] = counted
    return row


def list_files(root, paths):
    if paths:
        args = ["ls-files", "--cached", "--others", "--exclude-standard", "--", *paths]
    else:
        args = ["ls-files"]
    names = git(root, *args).stdout.decode("utf-8", "replace").splitlines()
    return sorted(name for name in set(names) if os.path.isfile(os.path.join(root, name)))


def print_table(rows, totals):
    width = max([len("file")] + [len(row["path"]) for row in rows])
    header = f"{'file':<{width}}  {'lines':>6} {'unchanged':>9} {'modified':>8} {'moved':>6} {'new':>6} {'share':>6}  origin"
    print(header)
    print("-" * len(header))
    for row in rows:
        origin = "new file" if row["source"] is None else ("same path" if row["source"] == row["path"] else row["source"])
        print(f"{row['path']:<{width}}  {row['lines']:>6} {row['unchanged']:>9} {row['modified']:>8} "
              f"{row['moved']:>6} {row['new']:>6} {row['share']:>5.1f}%  {origin}")
    print("-" * len(header))
    print(f"{'total (' + str(totals['files']) + ' files)':<{width}}  {totals['lines']:>6} {totals['unchanged']:>9} "
          f"{totals['modified']:>8} {totals['moved']:>6} {totals['new']:>6} {totals['share']:>5.1f}%")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Measure how much text still matches the original import commit (advisory).")
    parser.add_argument("paths", nargs="*", help="files or folders; default: every tracked file")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    parser.add_argument("--base", default=BASE_DEFAULT, help=f"commit to compare against (default {BASE_DEFAULT})")
    parser.add_argument("--moved-threshold", type=float, default=10.0,
                        help="percent of moved lines from which a new file counts them (default 10)")
    args = parser.parse_args(argv)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root = git(script_dir, "rev-parse", "--show-toplevel").stdout.decode().strip()
    if git(root, "cat-file", "-e", f"{args.base}^{{commit}}", check=False).returncode != 0:
        print(f"provenance: commit {args.base} is not in the local history (shallow clone?)", file=sys.stderr)
        return 2

    base = Base(root, args.base)
    paths = []
    for given in args.paths:
        full = os.path.realpath(os.path.abspath(given))
        if not os.path.exists(full):
            print(f"provenance: path not found: {given}", file=sys.stderr)
            return 2
        if os.path.commonpath([full, os.path.realpath(root)]) != os.path.realpath(root):
            print(f"provenance: path is outside the repository: {given}", file=sys.stderr)
            return 2
        paths.append(os.path.relpath(full, os.path.realpath(root)))
    rows, skipped = [], []
    for path in list_files(root, paths):
        row = measure(root, path, base, args.moved_threshold)
        if row is None:
            skipped.append(path)
        else:
            rows.append(row)

    totals = {"files": len(rows)}
    for key in ("lines", "unchanged", "modified", "moved", "new", "counted"):
        totals[key] = sum(row[key] for row in rows)
    totals["share"] = round(100 * totals["counted"] / totals["lines"], 1) if totals["lines"] else 0.0

    if args.json:
        json.dump({"base": args.base, "files": rows, "skipped": skipped, "totals": totals}, sys.stdout, indent=1)
        print()
    else:
        print_table(rows, totals)
        if skipped:
            print(f"skipped (binary): {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
