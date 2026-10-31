#!/usr/bin/env bash
# Weir — self-test for `generate-crate-notices.py`.
#
# The generator writes the Rust crate section of the THIRD-PARTY-NOTICES that
# ships, with no human reading it on each Dependabot bump. This feeds it
# made-up `cargo metadata` and crate folders, and asserts both what it writes
# and every shape it must refuse, so a change to it cannot quietly ship a
# crate without its license text.
#
# Run from the repo root:
#   scripts/test-generate-crate-notices.sh
#
# Exits 0 on success, 1 on any failing case.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 -I - "${REPO_ROOT}/scripts/generate-crate-notices.py" <<'PYTHON'
import io
import json
import os
import subprocess
import sys
import tempfile

GENERATOR = sys.argv[1]
MIT = (
    "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "of this software, to deal in the Software without restriction.\n"
)
failures = 0
root = tempfile.mkdtemp()


def crate(name, version, license, files, authors=("Ann <ann@example.com>",), proc_macro=False):
    directory = os.path.join(root, f"{name}-{version}")
    os.makedirs(directory, exist_ok=True)
    for file_name, text in files.items():
        with open(os.path.join(directory, file_name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return {
        "id": f"{name} {version}",
        "name": name,
        "version": version,
        "license": license,
        "repository": f"https://example.com/{name}",
        "authors": list(authors),
        "source": "registry+https://github.com/rust-lang/crates.io-index",
        "manifest_path": os.path.join(directory, "Cargo.toml"),
        "targets": [{"kind": ["proc-macro" if proc_macro else "lib"]}],
    }


def metadata(packages, edges):
    bridge = {
        "id": "bridge", "name": "weir-rust-bridge", "version": "0.1.0", "license": None,
        "repository": None, "authors": [], "source": None,
        "manifest_path": "/dev/null", "targets": [{"kind": ["staticlib"]}],
    }
    every = [bridge] + packages
    deps = {package["id"]: [] for package in every}
    for parent, child, kind in edges:
        deps[parent].append({"pkg": child, "dep_kinds": [{"kind": kind}]})
    return {
        "packages": every,
        "resolve": {"nodes": [{"id": pid, "deps": items} for pid, items in deps.items()]},
    }


MARKER = (
    "[The crates and their license texts are filled in from Cargo.lock when Weir"
    " is built; the copy inside Weir.app and on its disk image carries them.]"
)


def run(data, template=f"before\n{MARKER}\nafter\n"):
    path = os.path.join(root, "template")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(template)
    result = subprocess.run(
        [sys.executable, "-I", GENERATOR, path], input=json.dumps(data),
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout, result.stderr


def expect(name, condition, detail=""):
    global failures
    if condition:
        print(f"✓ {name}")
    else:
        print(f"✗ {name}{': ' + detail if detail else ''}")
        failures += 1


def refuses(name, data, reason, **kwargs):
    code, _, err = run(data, **kwargs)
    expect(name, code != 0 and reason in err, f"exit {code}, stderr {err.strip()!r}")


# What it writes.
alpha = crate("alpha", "1.0.0", "MIT OR Apache-2.0", {"LICENSE-MIT": "Copyright (c) 2020 Alpha\n\n" + MIT})
beta = crate("beta", "2.0.0", "MIT", {"LICENSE-MIT": MIT}, authors=("Bea <b@example.com>", "Ben"))
gamma = crate("gamma", "3.0.0", "MIT OR Apache-2.0", {"LICENSE-MIT": MIT}, authors=())
macro = crate("macro", "0.1.0", "MIT", {"LICENSE-MIT": MIT}, proc_macro=True)
uni = crate("uni", "1.0.0", "(MIT OR Apache-2.0) AND Unicode-3.0",
            {"LICENSE-MIT": MIT, "LICENSE-UNICODE": "UNICODE LICENSE V3\n"})
dev = crate("dev-only", "1.0.0", "GPL-3.0", {})
good = metadata(
    [alpha, beta, gamma, macro, uni, dev],
    [("bridge", alpha["id"], None), ("bridge", beta["id"], None), ("bridge", gamma["id"], None),
     ("bridge", macro["id"], None), (macro["id"], uni["id"], None), ("bridge", dev["id"], "dev")],
)
code, out, err = run(good)
expect("a valid graph is written", code == 0, err.strip())
expect("the template around the marker is kept", out.startswith("before\n") and out.endswith("after\n"))
expect("the marker is replaced", MARKER not in out)
expect("a crate with its own copyright gets its own block",
       "Crate: alpha 1.0.0 (MIT OR Apache-2.0) https://example.com/alpha\n" + "-" * 64 + "\n\nCopyright (c) 2020 Alpha" in out)
expect("crates without a copyright line share one text, with their authors",
       "Crate: beta 2.0.0 (MIT) https://example.com/beta\n  Authors (Cargo.toml): Bea, Ben\n" in out
       # alpha's own block, and one for the four without a copyright line.
       and out.count(MIT) == 2)
expect("a crate whose Cargo.toml lists no authors says so",
       "Crate: gamma 3.0.0 (MIT OR Apache-2.0) https://example.com/gamma\n  Authors (Cargo.toml): none listed\n" in out)
expect("a procedural macro and what only it reaches are compile-time only",
       "Crate: macro 0.1.0 (MIT, compile-time only)" in out
       and "Crate: uni 1.0.0 ((MIT OR Apache-2.0) AND Unicode-3.0, compile-time only)" in out)
expect("a text added with AND follows the MIT texts",
       out.index("Unicode data in uni 1.0.0 (Unicode-3.0)") > out.rindex(MIT) and "UNICODE LICENSE V3" in out)
expect("a dev-only crate is left out", "dev-only" not in out)

# Each run hashes strings with a new seed, so a set's order changes between
# runs; two releases of one crate must still come out in one order.
old = crate("twice", "1.0.0", "MIT", {"LICENSE-MIT": "Copyright (c) 2019 Old\n\n" + MIT})
new = crate("twice", "2.0.0", "MIT", {"LICENSE-MIT": "Copyright (c) 2024 New\n\n" + MIT})
two = metadata([old, new], [("bridge", old["id"], None), ("bridge", new["id"], None)])
outputs = {run(two)[1] for _ in range(8)}
expect("two releases of one crate come out in one order", len(outputs) == 1
       and next(iter(outputs)).index("twice 1.0.0") < next(iter(outputs)).index("twice 2.0.0"))

# What it refuses.
no_mit = crate("nomit", "1.0.0", "Apache-2.0", {"LICENSE-MIT": MIT})
refuses("a crate that does not offer MIT", metadata([no_mit], [("bridge", no_mit["id"], None)]), "does not offer the MIT License")
no_file = crate("nofile", "1.0.0", "MIT", {})
refuses("a crate without LICENSE-MIT", metadata([no_file], [("bridge", no_file["id"], None)]), "ships no LICENSE-MIT")
no_grant = crate("nogrant", "1.0.0", "MIT", {"LICENSE-MIT": "All rights reserved.\n"})
refuses("a LICENSE-MIT without the MIT grant", metadata([no_grant], [("bridge", no_grant["id"], None)]), "lacks the MIT grant")
other_and = crate("otherand", "1.0.0", "MIT AND BSD-3-Clause", {"LICENSE-MIT": MIT})
refuses("a text added with AND that has no rule", metadata([other_and], [("bridge", other_and["id"], None)]), "no rule for the text")
no_extra = crate("noextra", "1.0.0", "MIT AND Unicode-3.0", {"LICENSE-MIT": MIT})
refuses("a text added with AND whose file is missing", metadata([no_extra], [("bridge", no_extra["id"], None)]), "ships no LICENSE-UNICODE")
refuses("a template without the marker", good, "exactly once", template="no marker here\n")
refuses("a graph with no registry crates", metadata([], []), "found no registry crates")

sys.exit(1 if failures else 0)
PYTHON
