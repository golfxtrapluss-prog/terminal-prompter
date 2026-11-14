/// Current wire-protocol version, sent in the `hello` message (docs/04).
const int protocolVersion = 1;

/// Oldest protocol version an agent still accepts from a client.
///
/// The agent supports the current and the previous version.
const int minSupportedProtocolVersion = 1;
