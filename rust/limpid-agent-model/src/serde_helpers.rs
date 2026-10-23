//! These are the serde rules the run and turn records share for reading a
//! field a newer writer may have shaped differently.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// Reads a field without letting it veto the record: a value of a shape this
/// version cannot read becomes the field's default instead of failing the
/// whole decode.
///
/// For an enum that is its `Unknown`, the way a tag this version does not
/// know already reads through `#[serde(other)]`. For an `Option`, `null` and
/// an unreadable shape are both `None`, while a known shape whose enum tag
/// is new still reads as `Some(Unknown)`, so each type keeps its own answer
/// for what it cannot read. The field keeps its own `#[serde(default)]` for
/// when it is absent, since this only runs for a field that is present.
pub(crate) fn lenient<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned + Default,
{
    let value = Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::lenient;
    use serde::Deserialize;

    #[derive(Debug, Default, PartialEq, Deserialize)]
    #[serde(rename_all = "camelCase")]
    enum Kind {
        Known,
        #[default]
        #[serde(other)]
        Unknown,
    }

    #[derive(Debug, Deserialize)]
    struct Holder {
        #[serde(default, deserialize_with = "lenient")]
        kind: Kind,
        #[serde(default, deserialize_with = "lenient")]
        optional: Option<Kind>,
    }

    fn read(json: &str) -> Holder {
        serde_json::from_str(json).expect("the holder always decodes")
    }

    #[test]
    fn an_unreadable_shape_reads_as_each_types_default() {
        let holder = read(r#"{"kind":7,"optional":7}"#);
        assert_eq!(holder.kind, Kind::Unknown);
        assert_eq!(holder.optional, None);
    }

    #[test]
    fn a_new_tag_reads_as_unknown_and_null_as_none() {
        let holder = read(r#"{"kind":"later","optional":"later"}"#);
        assert_eq!(holder.kind, Kind::Unknown);
        assert_eq!(holder.optional, Some(Kind::Unknown));
        assert_eq!(read(r#"{"optional":null}"#).optional, None);
    }

    #[test]
    fn an_absent_field_takes_its_serde_default() {
        let holder = read("{}");
        assert_eq!(holder.kind, Kind::Unknown);
        assert_eq!(holder.optional, None);
        assert_eq!(read(r#"{"kind":"known"}"#).kind, Kind::Known);
    }
}
