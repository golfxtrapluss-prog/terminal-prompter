/// Agent version, injected at build time with `-DTP_VERSION=<version>` (see
/// the Makefile). Development builds report `0.0.0-dev`.
const String tpVersion = String.fromEnvironment(
  'TP_VERSION',
  defaultValue: '0.0.0-dev',
);
