#!/usr/bin/env python3
"""Fill the Rust crate section of THIRD-PARTY-NOTICES from `cargo metadata`.

Reads the metadata JSON on stdin (`cargo metadata --format-version 1
--filter-platform <target>`) and the notices template named on the command
line, and prints the template with its marker line replaced by one block per
license text. The crates are the bridge's normal dependency graph, so build-
and dev-only crates and other targets' crates never appear.

The section is generated because Dependabot moves these versions every
month, and a hand-kept copy fell behind on each bump.

Each crate must offer the MIT License, which we elect, and ship a
LICENSE-MIT file. Crates whose LICENSE-MIT carries no copyright line and
reads the same are grouped under one text, with the authors their
Cargo.toml lists, if any. A crate that is linked only through a procedural
macro is marked "compile-time only". A license expression that adds a text
with `AND` must name one of EXTRA_TEXTS. Any other shape stops the build, so
a new crate gets a human look instead of a wrong notice.
"""

import json
import os
import re
import sys

BRIDGE = "weir-rust-bridge"
MARKER = (
    "[The crates and their license texts are filled in from Cargo.lock when Weir"
    " is built; the copy inside Weir.app and on its disk image carries them.]"
)
RULE = "-" * 64
MIT_GRANT = "Permission is hereby granted, free of charge, to any person obtaining a copy"

# License identifier joined with AND -> (file in the crate, block title).
EXTRA_TEXTS = {
    "Unicode-3.0": ("LICENSE-UNICODE", "Unicode data in"),
}

GROUP_NOTE = (
    "The LICENSE-MIT file of the crates above carries no copyright line, so\n"
    "beside each crate we name the authors its Cargo.toml lists. Other\n"
    "contributors to a crate may also hold copyright in it.\n"
)


def fail(message):
    sys.exit(f"error: generate-crate-notices: {message}")


def walk(nodes, packages, start, enter_proc_macros):
    """Every package the normal edges reach from start."""
    seen, stack = set(), [start]
    while stack:
        current = stack.pop()
        if current in seen:
            continue
        # A procedural macro runs inside the compiler, so neither it nor what
        # only it reaches links into the bridge.
        if not enter_proc_macros and is_proc_macro(packages[current]):
            continue
        seen.add(current)
        for dep in nodes[current]["deps"]:
            if any(kind["kind"] is None for kind in dep["dep_kinds"]):
                stack.append(dep["pkg"])
    return seen


def is_proc_macro(package):
    return any("proc-macro" in target["kind"] for target in package["targets"])


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def authors(package):
    # Cargo.toml writes "Name <email>"; the notice names the person only.
    names = [re.sub(r"\s*<[^>]*>", "", author).strip() for author in package["authors"]]
    return ", ".join(name for name in names if name)


def crate_blocks(metadata):
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    roots = [pid for pid, package in packages.items() if package["name"] == BRIDGE and package["source"] is None]
    if len(roots) != 1:
        fail(f"found {len(roots)} workspace packages named {BRIDGE}")
    everything = walk(nodes, packages, roots[0], enter_proc_macros=True)
    linked = walk(nodes, packages, roots[0], enter_proc_macros=False)

    crates = []
    for pid in everything:
        package = packages[pid]
        if package["source"] is None:
            continue  # a workspace crate: ours
        name, version, license_expression = package["name"], package["version"], package["license"] or ""
        offered, extras = split_license(name, license_expression)
        if "MIT" not in offered:
            fail(f"{name} {version} does not offer the MIT License ({license_expression or 'no license field'})")
        directory = os.path.dirname(package["manifest_path"])
        mit_path = os.path.join(directory, "LICENSE-MIT")
        if not os.path.isfile(mit_path):
            fail(f"{name} {version} ships no LICENSE-MIT in {directory}")
        # A file of that name could hold another text; the grant proves MIT.
        if MIT_GRANT not in " ".join(read(mit_path).split()):
            fail(f"{name} {version}: its LICENSE-MIT lacks the MIT grant ({MIT_GRANT!r})")
        detail = license_expression
        if pid not in linked:
            detail += ", compile-time only"
        repository = package.get("repository") or f"https://crates.io/crates/{name}"
        crates.append({
            "name": name,
            "version": version,
            "header": f"Crate: {name} {version} ({detail}) {repository}",
            "text": read(mit_path),
            "authors": authors(package),
            "extras": [(identifier, os.path.join(directory, EXTRA_TEXTS[identifier][0])) for identifier in extras],
        })
    if not crates:
        fail(f"found no registry crates under {BRIDGE}")
    # The walk yields a set, whose order changes between runs. The version
    # settles two releases of one crate, so the build and the check that
    # regenerates the file always write the same bytes.
    crates.sort(key=lambda crate: (crate["name"], crate["version"]))
    return crates


def split_license(name, expression):
    """The identifiers offered as a choice, and those added with AND."""
    parts = [part.strip() for part in re.split(r"\s+AND\s+", expression) if part.strip()]
    if not parts:
        return set(), []
    choice = parts[0].strip("()")
    offered = {identifier.strip("() ") for identifier in re.split(r"\s+OR\s+|/", choice)}
    extras = []
    for part in parts[1:]:
        identifier = part.strip("() ")
        if identifier not in EXTRA_TEXTS:
            fail(f"{name}: no rule for the text its license adds with AND: {identifier}")
        extras.append(identifier)
    return offered, extras


def has_copyright(text):
    return re.search(r"^\s*copyright\b", text, re.IGNORECASE | re.MULTILINE) is not None


def render(crates):
    blocks = []
    grouped = {}
    for crate in crates:
        if has_copyright(crate["text"]):
            blocks.append(((crate["name"], crate["version"]), [crate]))
        else:
            grouped.setdefault(crate["text"], []).append(crate)
    for members in grouped.values():
        blocks.append(((members[0]["name"], members[0]["version"]), members))
    blocks.sort(key=lambda block: block[0])

    out = []
    for _, members in blocks:
        out.append(RULE + "\n")
        if len(members) == 1 and has_copyright(members[0]["text"]):
            out.append(members[0]["header"] + "\n")
            out.append(RULE + "\n\n")
        else:
            for crate in members:
                out.append(crate["header"] + "\n")
                # A Cargo.toml may list no authors; serde_json 1.0.154 lists
                # none. Say so rather than stop: the MIT text still ships.
                out.append(f"  Authors (Cargo.toml): {crate['authors'] or 'none listed'}\n")
            out.append(RULE + "\n\n")
            out.append(GROUP_NOTE + "\n")
        out.append(members[0]["text"].rstrip("\n") + "\n\n\n")
    for crate in crates:
        for identifier, path in crate["extras"]:
            if not os.path.isfile(path):
                fail(f"{crate['name']} {crate['version']} ships no {os.path.basename(path)}")
            title = EXTRA_TEXTS[identifier][1]
            out.append(RULE + "\n")
            out.append(f"{title} {crate['name']} {crate['version']} ({identifier})\n")
            out.append(RULE + "\n\n")
            out.append(read(path).rstrip("\n") + "\n\n\n")
    return "".join(out)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: cargo metadata ... | generate-crate-notices.py <THIRD-PARTY-NOTICES template>")
    template = read(sys.argv[1])
    if template.count(MARKER + "\n") != 1:
        fail(f"{sys.argv[1]} must hold the line {MARKER!r} exactly once")
    sys.stdout.write(template.replace(MARKER + "\n", render(crate_blocks(json.load(sys.stdin))), 1))


if __name__ == "__main__":
    main()
