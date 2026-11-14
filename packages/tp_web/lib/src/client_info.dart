import 'package:tp_protocol/tp_protocol.dart';

/// Client build version, injected with `-DTP_VERSION` by `make web`.
const String clientVersion = String.fromEnvironment(
  'TP_VERSION',
  defaultValue: '0.0.0-dev',
);

/// Identifier sent in the `hello.client` field so the agent can log which
/// client build it is talking to.
String clientIdentifier() =>
    'tp_web/$clientVersion (protocol v$protocolVersion)';
