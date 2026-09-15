# libghostty Fork Maintenance

Limpid renders terminals with `libghostty`, the library the ghostty project
builds from its own source, consumed through its C ABI. `vendor/ghostty` is a
submodule of our fork of that project (`nek0der/ghostty`, branch `limpid`),
and that branch carries the patches we need on top of upstream. Upstream is
`ghostty-org/ghostty`, tracked in the submodule as a separate `upstream`
remote. This document states why the fork exists, what a patch has to carry,
and how we retire one.

## Why we carry a fork

Limpid needs a small number of things the embedding API does not offer. Each
one leaves two options: work around it on our side, or patch the fork.
Upstream states that `libghostty` is not a stable API yet and describes the
terminal core moving into a library of its own.

A patch is therefore temporary by default. The fork holds only what we can
neither wait for nor work around. What each gap actually is belongs to its
row in the inventory, which changes as patches come and go — not here.

## Patch inventory

Every patch on the `limpid` branch appears here. Identify a patch by its
commit subject rather than its hash — rebasing rewrites the hash on every
upstream bump.

| Patch | Class | Why it is not upstream | Retirement condition |
|---|---|---|---|
| `Add scrollback save/restore C API` | temporary | Not proposed upstream yet. | The embedding API can save a surface's scrollback and replay it into a new surface. |

### Classes

- **temporary** — we intend the change to reach upstream, or upstream is
  expected to provide an equivalent. The retirement condition names what we
  are waiting for.
- **environment** — the change only makes sense for the way Limpid embeds the
  library and cannot be generalized. It stays until the embedding changes.
- **incompatible** — the change conflicts with an upstream decision. It stays
  until either side moves, and the entry records what the conflict is.

## Adding a patch

1. **Give the commit message a class and a retirement condition.** A rebase
   happens inside the submodule, where this document is not in view, so the
   commit has to carry them. If nobody can evaluate the retirement condition,
   the patch stays after the reason for it is gone.
2. **State the retirement condition as a capability, not as a symbol.** Write
   what the upstream API would have to be able to do, not the name of a
   function or a header that would carry it. Upstream is pre-stable and moving
   the terminal core into a library of its own, so names change while the
   capability we are waiting for does not. A condition written against a name
   looks unmet once that name changes.
3. **Keep it additive.** Additive means a consumer that does not use the new
   behavior sees no change. Moving code to create a hook counts as additive;
   altering what an existing path does for everyone does not. Whitespace,
   comment-only, and formatting changes are excluded outright. Every touched
   line can conflict on the next rebase, so touch as few as the change allows.
4. **Prefer a shape upstream could accept** over one that only serves Limpid.
   A general extension point is easier to retire than a special case, because
   upstream can land the same shape. Name what the patch adds the way upstream
   would name it — a local prefix would have to be undone before the change
   could be proposed, and it does not reduce the cost of moving off the patch
   later.
5. **Keep the branch a stack of independent commits on top of upstream.** Do
   not merge upstream into it.
6. **Add the row to the inventory above** in the same change that bumps the
   submodule.

## Rebasing onto upstream

Rebase the `limpid` branch onto upstream, then bump the submodule in its own
Limpid commit. Two checks belong to every rebase, and neither is mechanical:

- **Check each retirement condition.** Upstream may have landed the
  equivalent since the last bump. A patch that still applies cleanly is not
  evidence that it is still needed.
- **Check the assumptions, not just the conflicts.** Upstream can change a
  representation a patch depends on without touching the lines the patch
  edits. The build still succeeds while the behavior changes. Exercise the
  patched path after a rebase instead of trusting a clean apply.

Before rewriting the branch, tag the commit Limpid currently pins so its
objects stay reachable, and push the tag:

```bash
git -C vendor/ghostty tag "pin/$(date +%F)" <pinned-sha>
git -C vendor/ghostty push origin "pin/$(date +%F)"
```

A gitlink in Limpid records a hash; it is not a ref in the fork and keeps
nothing alive. Without the tag, the objects an older Limpid commit points at
become unreachable the moment the branch moves, and a forge is free to collect
them — an older release then cannot be checked out or rebuilt. Push the
rewritten branch with `--force-with-lease`, never a bare `--force`.

## Health

Two numbers track the fork. Neither has a target value.

```bash
# A fresh clone has only the fork as `origin`; add upstream once.
git -C vendor/ghostty remote add upstream https://github.com/ghostty-org/ghostty
git -C vendor/ghostty fetch upstream main

base=$(git -C vendor/ghostty merge-base HEAD upstream/main)
git -C vendor/ghostty rev-list --count HEAD --not "$base"      # patches we carry
git -C vendor/ghostty rev-list --count "$base"..upstream/main  # commits behind
git -C vendor/ghostty log --oneline HEAD --not "$base"         # which patches
```

Distance is expected to grow between bumps and reset when we rebase; it says
how stale the pinned state is, not whether anything is wrong. A rising patch
count is the one to act on: check whether the embedding needs to change
before reaching for the library.

## Retiring a patch

When a retirement condition is met, drop the commit from the `limpid` branch,
move Limpid to the upstream equivalent in the same change, and remove the row
from the inventory. Record the retirement in the submodule bump's commit
message so the reason is recoverable from history rather than only from this
file.

Keep the Limpid-side calls that reach a fork-only entry point behind a single
wrapper. That keeps the call sites to one file when the patch retires; the
submodule bump and the inventory row are separate, small edits.
