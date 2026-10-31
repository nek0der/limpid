#!/usr/bin/env bash
# stamp-source-times.sh
# Weir — give each source file a modification time derived from its content.
#
# A fresh checkout dates every file at the moment of the checkout, so Xcode
# treats a restored DerivedData as out of date and compiles everything. With
# these times a file keeps its time until its content changes, on any runner
# and with no Git history to compare against.
#
# `rust/` stays out, apart from the generated header. Cargo rebuilds a crate
# only when a source is newer than the last build, and a time derived from
# content can be older, which would link a stale crate. Keeping the checkout's
# time makes Cargo rebuild the local crates instead, which is slower and right.
#
# Usage: scripts/stamp-source-times.sh [root]

set -euo pipefail

cd "${1:-.}"

perl -MDigest::SHA -MFile::Find -e '
    # Every time falls in the past: 1.5e9 is 2017, and the 28 bits added reach
    # the start of 2026.
    my $base = 1_500_000_000;
    find({ no_chdir => 1, wanted => sub {
        my $file = $File::Find::name;
        (my $path = $file) =~ s{^\./}{};
        return if -l $file;
        if (-d $file) {
            if ($path =~ m{^(\.git|build|target)$}) {
                $File::Find::prune = 1;
            } elsif ($path !~ m{^rust(/|$)}) {
                utime($base, $base, $file);
            }
            return;
        }
        return if $path =~ m{^rust/} && $path !~ m{^rust/weir-rust-bridge/include/};
        my $time = $base;
        # The submodule is large and changes only with its pinned commit, which
        # the cache keys already name.
        if ($path !~ m{^vendor/}) {
            $time += hex(substr(Digest::SHA->new(256)->addfile($file, "b")->hexdigest, 0, 7));
        }
        utime($time, $time, $file);
    } }, ".");
'
