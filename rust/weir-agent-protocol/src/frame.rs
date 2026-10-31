use serde::Serialize;
use serde::de::DeserializeOwned;
use std::fmt;
use std::io::{self, Read, Write};

#[derive(Debug)]
pub enum FrameError {
    Io(io::Error),
    Truncated,
    Empty,
    TooLarge { length: usize, maximum: usize },
    InvalidJson(serde_json::Error),
}

impl fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "I/O error: {error}"),
            Self::Truncated => formatter.write_str("the frame ended before its declared length"),
            Self::Empty => formatter.write_str("zero-length frames are not valid"),
            Self::TooLarge { length, maximum } => {
                write!(
                    formatter,
                    "frame length {length} exceeds the {maximum}-byte limit"
                )
            }
            Self::InvalidJson(error) => write!(formatter, "invalid JSON frame: {error}"),
        }
    }
}

impl std::error::Error for FrameError {}

/// Reads one four-byte big-endian length-prefixed JSON message.
///
/// `Ok(None)` means the stream closed cleanly between frames. EOF after any
/// header or payload byte is a truncated frame.
///
/// # Errors
///
/// Returns an I/O, size, truncation, or JSON decoding error.
pub fn read_frame<R: Read, T: DeserializeOwned>(
    reader: &mut R,
    maximum_bytes: usize,
) -> Result<Option<T>, FrameError> {
    let mut header = [0_u8; 4];
    match read_one(reader, &mut header[..1]) {
        Ok(false) => return Ok(None),
        Ok(true) => {}
        Err(error) => return Err(FrameError::Io(error)),
    }
    read_exact_or_truncated(reader, &mut header[1..])?;
    let length = usize::try_from(u32::from_be_bytes(header)).map_err(|_| FrameError::TooLarge {
        length: usize::MAX,
        maximum: maximum_bytes,
    })?;
    if length == 0 {
        return Err(FrameError::Empty);
    }
    if length > maximum_bytes {
        return Err(FrameError::TooLarge {
            length,
            maximum: maximum_bytes,
        });
    }
    let mut payload = vec![0_u8; length];
    read_exact_or_truncated(reader, &mut payload)?;
    serde_json::from_slice(&payload)
        .map(Some)
        .map_err(FrameError::InvalidJson)
}

/// Writes one four-byte big-endian length-prefixed JSON message.
///
/// # Errors
///
/// Returns an I/O, size, or JSON encoding error.
pub fn write_frame<W: Write, T: Serialize>(
    writer: &mut W,
    value: &T,
    maximum_bytes: usize,
) -> Result<(), FrameError> {
    let payload = serde_json::to_vec(value).map_err(FrameError::InvalidJson)?;
    if payload.is_empty() {
        return Err(FrameError::Empty);
    }
    if payload.len() > maximum_bytes || payload.len() > u32::MAX as usize {
        return Err(FrameError::TooLarge {
            length: payload.len(),
            maximum: maximum_bytes.min(u32::MAX as usize),
        });
    }
    let length = u32::try_from(payload.len()).map_err(|_| FrameError::TooLarge {
        length: payload.len(),
        maximum: u32::MAX as usize,
    })?;
    writer
        .write_all(&length.to_be_bytes())
        .map_err(FrameError::Io)?;
    writer.write_all(&payload).map_err(FrameError::Io)?;
    writer.flush().map_err(FrameError::Io)
}

fn read_one<R: Read>(reader: &mut R, byte: &mut [u8]) -> io::Result<bool> {
    loop {
        match reader.read(byte) {
            Ok(0) => return Ok(false),
            Ok(_) => return Ok(true),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

fn read_exact_or_truncated<R: Read>(reader: &mut R, buffer: &mut [u8]) -> Result<(), FrameError> {
    reader.read_exact(buffer).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            FrameError::Truncated
        } else {
            FrameError::Io(error)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};
    use std::io::Cursor;

    #[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
    struct Example {
        value: String,
    }

    struct OneByteReader<R> {
        inner: R,
    }

    impl<R: Read> Read for OneByteReader<R> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let length = buffer.len().min(1);
            self.inner.read(&mut buffer[..length])
        }
    }

    #[test]
    fn reads_partial_stream_and_multiple_frames() {
        let mut bytes = Vec::new();
        write_frame(
            &mut bytes,
            &Example {
                value: "one".into(),
            },
            1024,
        )
        .unwrap();
        write_frame(
            &mut bytes,
            &Example {
                value: "two".into(),
            },
            1024,
        )
        .unwrap();
        let mut reader = OneByteReader {
            inner: Cursor::new(bytes),
        };

        assert_eq!(
            read_frame::<_, Example>(&mut reader, 1024).unwrap(),
            Some(Example {
                value: "one".into()
            })
        );
        assert_eq!(
            read_frame::<_, Example>(&mut reader, 1024).unwrap(),
            Some(Example {
                value: "two".into()
            })
        );
        assert_eq!(read_frame::<_, Example>(&mut reader, 1024).unwrap(), None);
    }

    #[test]
    fn rejects_oversized_and_truncated_frames_before_json_decode() {
        let mut oversized = Cursor::new(9_u32.to_be_bytes());
        assert!(matches!(
            read_frame::<_, Example>(&mut oversized, 8),
            Err(FrameError::TooLarge { .. })
        ));

        let mut truncated = Cursor::new([0, 0, 0, 4, b'{']);
        assert!(matches!(
            read_frame::<_, Example>(&mut truncated, 8),
            Err(FrameError::Truncated)
        ));
    }
}
