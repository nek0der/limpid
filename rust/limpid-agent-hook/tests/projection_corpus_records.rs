//! The projection corpus's generated records are what the hook runtime writes
//! today. Each case's scenario is replayed into a scratch directory and
//! compared, file by file, with what is committed, so a runtime change that
//! leaves the records behind fails here instead of feeding the projection
//! goldens records no hook writes any more. Unix only: the hook runtime itself
//! only runs there.
#![cfg(unix)]

#[path = "../examples/derive-projection-corpus.rs"]
mod derive;

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// Every file under `root`'s generated directories, by its path below
/// `root`, with its bytes. Lock sidecars are pruned by `derive`, and the
/// committed tree has none.
fn generated_files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for directory in derive::GENERATED {
        let Ok(entries) = fs::read_dir(root.join(directory)) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = format!("{directory}/{}", entry.file_name().to_string_lossy());
            files.insert(name, fs::read(entry.path()).expect("read a record"));
        }
    }
    files
}

#[test]
fn the_committed_records_are_what_the_runtime_writes_now() {
    let fixtures = derive::fixtures();
    let cases = derive::cases(&fixtures).expect("projection cases");
    assert!(!cases.is_empty(), "no scenario to replay");
    let mut stale = Vec::new();
    for case in &cases {
        let scratch = tempfile::tempdir().expect("scratch");
        derive::derive(case, &fixtures, scratch.path()).expect("the scenario replays");
        let written = generated_files(scratch.path());
        let committed = generated_files(case);
        let name = case.file_name().unwrap_or_default().to_string_lossy();
        for path in committed.keys().chain(written.keys()) {
            if committed.get(path) != written.get(path) {
                stale.push(format!("{name}/{path}"));
            }
        }
    }
    stale.dedup();
    assert!(
        stale.is_empty(),
        "stale corpus records; run scripts/derive-projection-corpus.sh and \
         review the diff:\n{}",
        stale.join("\n")
    );
}
