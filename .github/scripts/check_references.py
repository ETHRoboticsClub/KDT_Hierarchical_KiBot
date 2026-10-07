#!/usr/bin/env python3
"""Check reference designators across the whole schematic hierarchy.

KiCad's command-line ERC (what KiBot runs in CI) does not run the annotation
checks that the ERC dialog in Eeschema runs, so two feature branches that both
used "Annotate entire schematic" and both produced R1 pass CI. This script
fills that gap:

  * duplicate references (same reference and unit placed twice)
  * unannotated references (R?, U?A ...)

It walks the hierarchy from the root sheet (<project>.kicad_sch), so only
symbol instances that really exist in this project are counted; stale
instance data from other projects in a sheet file is ignored. Power symbols
and flags (#PWR, #FLG) are skipped.

Usage:  python3 .github/scripts/check_references.py [root.kicad_sch]
Env:    REF_CHECK_LEVEL  error | warning   (annotation level, default error)
Exit:   1 if problems were found, else 0.
"""
import glob
import os
import sys

LEVEL = os.environ.get("REF_CHECK_LEVEL", "error")
ON_CI = os.environ.get("GITHUB_ACTIONS") == "true"


def parse(text):
    """Minimal s-expression parser: returns nested lists of strings."""
    stack, cur, i, n = [], [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "(":
            stack.append(cur)
            cur = []
            i += 1
        elif c == ")":
            done, cur = cur, stack.pop()
            cur.append(done)
            i += 1
        elif c == '"':
            j, buf = i + 1, []
            while text[j] != '"':
                if text[j] == "\\":
                    j += 1
                buf.append(text[j])
                j += 1
            cur.append("".join(buf))
            i = j + 1
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and text[j] not in '()" \t\r\n':
                j += 1
            cur.append(text[i:j])
            i = j
    return cur[0]


def children(node, name):
    return [c for c in node[1:] if isinstance(c, list) and c and c[0] == name]


def first(node, name):
    found = children(node, name)
    return found[0] if found else None


def prop(node, key):
    for p in children(node, "property"):
        if len(p) > 2 and p[1] == key:
            return p[2]
    return None


def note(path, msg):
    if ON_CI:
        print(f"::{LEVEL} file={path},title=References::{msg}")
    print(f"  {msg}  [{path}]")


def main():
    if len(sys.argv) > 1:
        root = sys.argv[1]
    else:
        pros = glob.glob("*.kicad_pro")
        if len(pros) != 1:
            print(f"Expected exactly one *.kicad_pro in the repo root, found {pros}")
            return 1
        root = pros[0][: -len(".kicad_pro")] + ".kicad_sch"

    trees = {}

    def load(path):
        if path not in trees:
            with open(path, encoding="utf-8") as fh:
                trees[path] = parse(fh.read())
        return trees[path]

    # file -> set of hierarchical paths at which that file is instantiated
    paths = {}

    def walk(path, sheet_path, depth=0):
        if depth > 32:
            raise RuntimeError("sheet recursion")
        tree = load(path)
        paths.setdefault(path, set()).add(sheet_path)
        base = os.path.dirname(path)
        for sheet in children(tree, "sheet"):
            uuid = first(sheet, "uuid")[1]
            sub = prop(sheet, "Sheetfile") or prop(sheet, "Sheet file")
            if not sub:
                continue
            walk(os.path.normpath(os.path.join(base, sub)), f"{sheet_path}/{uuid}", depth + 1)

    root_tree = load(root)
    walk(root, "/" + first(root_tree, "uuid")[1])

    seen = {}  # (ref, unit) -> [(file, path)]
    unannotated = []
    for path, sheet_paths in paths.items():
        for sym in children(trees[path], "symbol"):
            inst = first(sym, "instances")
            if inst is None:
                continue
            for project in children(inst, "project"):
                for p in children(project, "path"):
                    if p[1] not in sheet_paths:
                        continue  # stale instance data (other project / old hierarchy)
                    ref = first(p, "reference")[1]
                    unit_node = first(p, "unit")
                    unit = unit_node[1] if unit_node else "1"
                    if ref.startswith("#"):
                        continue
                    if ref.endswith("?") or "?" in ref:
                        unannotated.append((ref, path))
                    else:
                        seen.setdefault((ref, unit), []).append((path, p[1]))

    dups = {k: v for k, v in seen.items() if len(v) > 1}
    total = sum(len(v) for v in seen.values()) + len(unannotated)
    print(f"Checked {total} symbol instance(s) in {len(paths)} sheet file(s), root {root}")
    for (ref, unit), where in sorted(dups.items()):
        files = sorted({w[0] for w in where})
        for f in files:
            others = ", ".join(x for x in files if x != f) or "the same sheet"
            note(f, f"Duplicate reference {ref} (unit {unit}): also used in {others}. "
                    "Annotate with 'Current sheet only' and sheet-number x 100 numbering.")
    for ref, f in unannotated:
        note(f, f"Unannotated symbol {ref}. Annotate the sheet before committing.")
    if dups or unannotated:
        print(f"Result: {len(dups)} duplicate(s), {len(unannotated)} unannotated")
        return 1
    print("Result: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
