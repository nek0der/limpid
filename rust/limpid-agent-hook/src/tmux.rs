//! tmux endpoint discovery from the environment tmux gives its children.

use limpid_agent_model::TmuxEndpoint;

/// Parses `TMUX` (`socket,server-pid,session-index`) and `TMUX_PANE` (`%N`).
/// The session index is deliberately ignored: pane membership is mutable and
/// belongs to the host's topology probe.
#[must_use]
pub fn endpoint(tmux: &str, pane: &str) -> Option<TmuxEndpoint> {
    if !tmux.starts_with('/') || !pane.starts_with('%') || pane.len() < 2 {
        return None;
    }
    if !pane[1..].bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    // Fields are removed from the right so a comma in a custom socket path
    // survives.
    let prefix = tmux.rsplit_once(',')?.0;
    let (socket, server_pid) = prefix.rsplit_once(',')?;
    let server_pid: u32 = server_pid.parse().ok()?;
    if socket.is_empty() {
        return None;
    }
    Some(TmuxEndpoint {
        socket_path: socket.to_owned(),
        pane: pane.to_owned(),
        server_pid,
        server_started_at: crate::process::start_epoch(server_pid),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_documented_shape_and_keeps_commas_in_the_socket() {
        let endpoint = endpoint("/tmp/tmux-501/lim,pid,default,4242,0", "%3").expect("endpoint");
        assert_eq!(endpoint.socket_path, "/tmp/tmux-501/lim,pid,default");
        assert_eq!(endpoint.server_pid, 4242);
        assert_eq!(endpoint.pane, "%3");
    }

    #[test]
    fn rejects_malformed_values() {
        assert!(endpoint("relative,1,0", "%1").is_none());
        assert!(endpoint("/s,x,0", "%1").is_none());
        assert!(endpoint("/s,1,0", "3").is_none());
        assert!(endpoint("/s,1,0", "%").is_none());
        assert!(endpoint("/s,1", "%1").is_none());
    }
}
