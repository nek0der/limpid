//! Hunks read from git's unified diffs, taken back out of a file.

use super::*;

fn text(lines: &str) -> Text {
    Text::from_bytes(lines.as_bytes())
}

fn bytes(text: Text) -> String {
    String::from_utf8(text.into_bytes()).unwrap_or_default()
}

/// Two hunks of one file, as `git diff -U1` writes them.
const TWO: &str = "\
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,3 +1,3 @@
 a
-b
+B
 c
@@ -7,3 +7,4 @@ fn g
 g
 h
+i2
 i
";

const BEFORE: &str = "a\nb\nc\nd\ne\nf\ng\nh\ni\n";
const AFTER: &str = "a\nB\nc\nd\ne\nf\ng\nh\ni2\ni\n";

#[test]
fn a_patch_reads_as_its_hunks_with_their_headers() {
    let hunks = parse(TWO.as_bytes()).unwrap_or_default();
    assert_eq!(hunks.len(), 2);
    assert_eq!(hunks[0].header, "@@ -1,3 +1,3 @@");
    assert_eq!(
        hunks[1].header, "@@ -7,3 +7,4 @@",
        "the function name is not the hunk's name"
    );
    assert_eq!(ranges("@@ -7,3 +7,4 @@ fn g"), "@@ -7,3 +7,4 @@");
}

#[test]
fn every_hunk_taken_back_gives_the_old_file() {
    let hunks = parse(TWO.as_bytes()).unwrap_or_default();
    let (result, outcomes) = reverse(text(AFTER), &hunks, &[0, 1]);
    assert_eq!(bytes(result), BEFORE);
    assert_eq!(outcomes, vec![Ok(()), Ok(())]);
}

/// A later hunk is found where the earlier ones, left in the file or taken
/// back before, moved it.
#[test]
fn one_hunk_is_taken_back_wherever_the_others_left_it() {
    let hunks = parse(TWO.as_bytes()).unwrap_or_default();
    let (second_only, _) = reverse(text(AFTER), &hunks, &[1]);
    assert_eq!(bytes(second_only.clone()), "a\nB\nc\nd\ne\nf\ng\nh\ni\n");
    let (both, outcomes) = reverse(second_only, &hunks, &[0]);
    assert_eq!(bytes(both), BEFORE);
    assert_eq!(outcomes, vec![Ok(())]);
    // Lines added above shift the hunk; it is still found.
    let (shifted, outcomes) = reverse(text(&format!("new\n{AFTER}")), &hunks, &[1]);
    assert_eq!(outcomes, vec![Ok(())]);
    assert_eq!(
        bytes(shifted),
        format!("new\n{}", "a\nB\nc\nd\ne\nf\ng\nh\ni\n")
    );
}

#[test]
fn a_hunk_whose_lines_changed_since_is_left_alone() {
    let hunks = parse(TWO.as_bytes()).unwrap_or_default();
    let edited = AFTER.replace("i2", "i3");
    let (result, outcomes) = reverse(text(&edited), &hunks, &[0, 1]);
    assert_eq!(outcomes, vec![Ok(()), Err(Mismatch::NotFound)]);
    assert_eq!(bytes(result), edited.replace('B', "b"));
}

#[test]
fn the_newline_at_the_end_is_put_back_as_it_was() {
    let patch = "\
@@ -1,2 +1,2 @@
 a
-b
\\ No newline at end of file
+b
";
    let hunks = parse(patch.as_bytes()).unwrap_or_default();
    let (result, outcomes) = reverse(text("a\nb\n"), &hunks, &[0]);
    assert_eq!(outcomes, vec![Ok(())]);
    assert_eq!(bytes(result), "a\nb");
    // A file that ends otherwise than the hunk says is not the hunk's.
    let (_, outcomes) = reverse(text("a\nb"), &hunks, &[0]);
    assert_eq!(outcomes, vec![Err(Mismatch::NotFound)]);
}

#[test]
fn a_file_the_range_added_or_deleted_reverses_to_nothing_or_back() {
    let added = "@@ -0,0 +1,2 @@\n+a\n+b\n";
    let hunks = parse(added.as_bytes()).unwrap_or_default();
    let (result, outcomes) = reverse(text("a\nb\n"), &hunks, &[0]);
    assert_eq!(outcomes, vec![Ok(())]);
    assert!(result.is_empty());

    let deleted = "@@ -1,2 +0,0 @@\n-a\n-b\n";
    let hunks = parse(deleted.as_bytes()).unwrap_or_default();
    let (result, outcomes) = reverse(text(""), &hunks, &[0]);
    assert_eq!(outcomes, vec![Ok(())]);
    assert_eq!(bytes(result), "a\nb\n");
}

/// A hunk the range emptied the file with matches only an empty file: one
/// made again by hand is not the hunk's.
#[test]
fn a_hunk_with_no_new_lines_matches_only_an_empty_file() {
    let deleted = parse(b"@@ -1,2 +0,0 @@\n-a\n-b\n").unwrap_or_default();
    let (result, outcomes) = reverse(text("z\n"), &deleted, &[0]);
    assert_eq!(outcomes, vec![Err(Mismatch::NotFound)]);
    assert_eq!(bytes(result), "z\n");
}

/// Away from where the diff put it, a hunk found in two places is not
/// taken back from either.
#[test]
fn a_moved_hunk_found_twice_is_left_alone() {
    let hunks = parse(b"@@ -2,1 +2,1 @@\n-x\n+y\n").unwrap_or_default();
    let (_, outcomes) = reverse(text("a\nb\ny\nc\ny\n"), &hunks, &[0]);
    assert_eq!(outcomes, vec![Err(Mismatch::NotFound)]);
    let (result, outcomes) = reverse(text("a\ny\nc\ny\n"), &hunks, &[0]);
    assert_eq!(
        outcomes,
        vec![Ok(())],
        "where the diff put it, it is that one"
    );
    assert_eq!(bytes(result), "a\nx\nc\ny\n");
}

/// The function name after the ranges is the file's own bytes.
#[test]
fn a_header_whose_function_name_is_not_text_still_reads() {
    let hunks = parse(b"@@ -1 +1 @@ fn \xff\n-a\n+b\n").unwrap_or_default();
    assert_eq!(hunks.len(), 1);
    assert_eq!(hunks[0].header, "@@ -1 +1 @@");
}

#[test]
fn a_patch_git_would_not_write_is_refused() {
    assert_eq!(parse(b"@@ -1,2 +1,2 @@\n a\n"), None, "short of its counts");
    assert_eq!(parse(b"@@ nonsense @@\n"), None);
    assert_eq!(parse(b""), Some(Vec::new()));
}

#[test]
fn bytes_that_are_not_text_are_kept_as_they_are() {
    let patch = b"@@ -1 +1 @@\n-\xff\r\n+x\r\n";
    let hunks = parse(patch).unwrap_or_default();
    let (result, outcomes) = reverse(Text::from_bytes(b"x\r\n"), &hunks, &[0]);
    assert_eq!(outcomes, vec![Ok(())]);
    assert_eq!(result.into_bytes(), b"\xff\r\n".to_vec());
}
