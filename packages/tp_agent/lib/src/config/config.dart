import 'dart:io';

import 'package:toml/toml.dart';

/// Errors raised while loading configuration.
sealed class ConfigError implements Exception {
  const ConfigError(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'ConfigError: $message';
}

/// The file could not be read or is not valid TOML.
final class ConfigParseError extends ConfigError {
  const ConfigParseError(super.message);
}

/// A value is missing, has the wrong type or is out of range.
final class ConfigValueError extends ConfigError {
  ConfigValueError(this.key, String reason) : super('$key: $reason');

  /// Dotted key path, e.g. `sessions.max`.
  final String key;
}

/// How the agent is reached (docs/01).
enum AgentMode {
  /// Behind a reverse proxy on localhost (default).
  proxy,

  /// Terminates TLS itself using certificate files.
  standalone,

  /// Outbound connection to a relay (v2).
  relay,
}

/// Whether sessions are wrapped in a multiplexer.
enum ShellWrap {
  /// Plain shell.
  none,

  /// `tmux new-session -A -s tp-<id>` so sessions survive agent restarts.
  tmux,
}

/// `[tls]` section (standalone mode only).
final class TlsConfig {
  const TlsConfig({required this.certFile, required this.keyFile});

  final String certFile;
  final String keyFile;
}

/// `[auth]` section.
final class AuthConfig {
  const AuthConfig({
    required this.passwordHash,
    required this.totpSecret,
    required this.sessionTtl,
    required this.maxFailedLogins,
    required this.lockout,
    required this.idleTimeout,
    required this.stateFile,
  });

  /// argon2id PHC string; empty until `tp-agent init` has run.
  final String passwordHash;
  final String totpSecret;
  final Duration sessionTtl;
  final int maxFailedLogins;
  final Duration lockout;

  /// A login with no activity for this long expires (docs/05).
  final Duration idleTimeout;

  /// JSON file with passkeys, backup codes and TOTP replay state.
  final String stateFile;

  /// True once a password is set.
  bool get isConfigured => passwordHash.isNotEmpty;
}

/// `[shell]` section.
final class ShellConfig {
  const ShellConfig({
    required this.command,
    required this.args,
    required this.env,
    required this.workdir,
    required this.wrap,
  });

  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// Working directory; `~` expands to the agent user's home.
  final String workdir;
  final ShellWrap wrap;
}

/// `[sessions]` section.
final class SessionsConfig {
  const SessionsConfig({
    required this.max,
    required this.idleTimeout,
    required this.scrollbackBytes,
  });

  final int max;
  final Duration idleTimeout;
  final int scrollbackBytes;
}

/// `[transport]` section.
final class TransportConfig {
  const TransportConfig({
    required this.heartbeat,
    required this.outputCoalesce,
    required this.compression,
    required this.sseFallback,
  });

  final Duration heartbeat;
  final Duration outputCoalesce;
  final bool compression;
  final bool sseFallback;
}

/// `[files]` section.
final class FilesConfig {
  const FilesConfig({
    required this.enabled,
    required this.maxUpload,
    required this.chunkSize,
    required this.root,
  });

  final bool enabled;
  final int maxUpload;
  final int chunkSize;
  final String root;
}

/// `[update]` section.
final class UpdateConfig {
  const UpdateConfig({required this.url});

  /// Release base URL with `SHA256SUMS`, `SHA256SUMS.sig` and binaries.
  final String url;
}

/// `[audit]` section.
final class AuditConfig {
  const AuditConfig({
    required this.enabled,
    required this.logInput,
    required this.path,
  });

  final bool enabled;
  final bool logInput;
  final String path;
}

/// Agent configuration (docs/02). Loaded from TOML with `TP_*` environment
/// overrides: `TP_LISTEN`, `TP_MODE`, `TP_BASE_PATH`, `TP_PUBLIC_ORIGIN`,
/// and `TP_<SECTION>_<KEY>` for scalar section values, e.g.
/// `TP_SESSIONS_MAX=4` or `TP_SHELL_COMMAND=/bin/zsh`.
final class AgentConfig {
  const AgentConfig({
    required this.mode,
    required this.listenHost,
    required this.listenPort,
    required this.basePath,
    required this.publicOrigin,
    required this.tls,
    required this.auth,
    required this.shell,
    required this.sessions,
    required this.transport,
    required this.files,
    required this.audit,
    this.update = const UpdateConfig(url: ''),
  });

  final AgentMode mode;
  final String listenHost;
  final int listenPort;

  /// Always starts and ends with `/`.
  final String basePath;
  final Uri? publicOrigin;
  final TlsConfig? tls;
  final AuthConfig auth;
  final ShellConfig shell;
  final SessionsConfig sessions;
  final TransportConfig transport;
  final FilesConfig files;
  final AuditConfig audit;
  final UpdateConfig update;

  /// Reads and parses [path].
  static Future<AgentConfig> load(
    String path, {
    Map<String, String>? environment,
  }) async {
    final String text;
    try {
      text = await File(path).readAsString();
    } on FileSystemException catch (e) {
      throw ConfigParseError('cannot read $path: ${e.osError?.message ?? e}');
    }
    return parse(
      text,
      environment: environment ?? Platform.environment,
      baseDir: File(path).absolute.parent.path,
    );
  }

  /// Makes a relative [path] relative to the config file's directory.
  static String _resolve(String? baseDir, String path) {
    if (baseDir == null || path.isEmpty || path.startsWith('/')) return path;
    return '$baseDir/$path';
  }

  /// Parses TOML [text] and applies [environment] overrides.
  static AgentConfig parse(
    String text, {
    Map<String, String> environment = const {},
    String? baseDir,
  }) {
    final Map<String, Object?> root;
    try {
      root = TomlDocument.parse(text).toMap();
    } on TomlException catch (e) {
      throw ConfigParseError('invalid TOML: $e');
    }
    final top = _Section('', root, environment);
    final mode = _enum('mode', top.string('mode', 'proxy'), AgentMode.values);
    final (host, port) = _parseListen(top.string('listen', '127.0.0.1:7681'));
    final basePath = _normalizeBasePath(top.string('base_path', '/'));
    final originText = top.string('public_origin', '');
    final origin = originText.isEmpty ? null : Uri.tryParse(originText);
    if (originText.isNotEmpty && (origin == null || !origin.hasScheme)) {
      throw ConfigValueError('public_origin', 'must be an absolute URL');
    }

    final tlsSection = top.section('tls');
    final tls = tlsSection.isEmpty
        ? null
        : TlsConfig(
            certFile: _resolve(baseDir, tlsSection.string('cert_file', '')),
            keyFile: _resolve(baseDir, tlsSection.string('key_file', '')),
          );
    if (mode == AgentMode.standalone &&
        (tls == null || tls.certFile.isEmpty || tls.keyFile.isEmpty)) {
      throw ConfigValueError(
        'tls',
        'standalone mode needs cert_file and key_file',
      );
    }

    final auth = top.section('auth');
    final shell = top.section('shell');
    final sessions = top.section('sessions');
    final transport = top.section('transport');
    final files = top.section('files');
    final audit = top.section('audit');
    final update = top.section('update');

    final config = AgentConfig(
      mode: mode,
      listenHost: host,
      listenPort: port,
      basePath: basePath,
      publicOrigin: origin,
      tls: tls,
      auth: AuthConfig(
        passwordHash: auth.string('password_hash', ''),
        totpSecret: auth.string('totp_secret', ''),
        sessionTtl: auth.duration('session_ttl', const Duration(hours: 12)),
        maxFailedLogins: auth.int_('max_failed_logins', 5, min: 1),
        lockout: auth.duration('lockout', const Duration(minutes: 15)),
        idleTimeout: auth.duration('idle_timeout', const Duration(hours: 4)),
        stateFile: _resolve(
          baseDir,
          auth.string('state_file', '/var/lib/tp-agent/auth.json'),
        ),
      ),
      shell: ShellConfig(
        command: shell.string('command', '/bin/bash'),
        args: shell.stringList('args', const ['-l']),
        env: shell.stringMap('env', const {
          'TERM': 'xterm-256color',
          'LANG': 'C.UTF-8',
        }),
        workdir: shell.string('workdir', '~'),
        wrap: _enum(
          'shell.wrap',
          shell.string('wrap', 'none'),
          ShellWrap.values,
        ),
      ),
      sessions: SessionsConfig(
        max: sessions.int_('max', 8, min: 1, max: 256),
        idleTimeout: sessions.duration(
          'idle_timeout',
          const Duration(hours: 24),
        ),
        scrollbackBytes: sessions.bytes(
          'scrollback_bytes',
          1024 * 1024,
          min: 4096,
        ),
      ),
      transport: TransportConfig(
        heartbeat: transport.duration('heartbeat', const Duration(seconds: 15)),
        outputCoalesce: transport.duration(
          'output_coalesce',
          const Duration(milliseconds: 25),
        ),
        compression: transport.bool_('compression', true),
        sseFallback: transport.bool_('sse_fallback', true),
      ),
      files: FilesConfig(
        enabled: files.bool_('enabled', true),
        maxUpload: files.bytes('max_upload', 2 * 1024 * 1024 * 1024, min: 0),
        chunkSize: files.bytes('chunk_size', 256 * 1024, min: 4096),
        root: files.string('root', '~'),
      ),
      audit: AuditConfig(
        enabled: audit.bool_('enabled', true),
        logInput: audit.bool_('log_input', true),
        path: _resolve(
          baseDir,
          audit.string('path', '/var/lib/tp-agent/audit.jsonl'),
        ),
      ),
      update: UpdateConfig(url: update.string('url', '')),
    );
    config._validate();
    return config;
  }

  /// True when [listenHost] is a loopback address.
  bool get listensOnLoopback {
    if (listenHost == 'localhost') return true;
    final address = InternetAddress.tryParse(listenHost);
    return address != null && address.isLoopback;
  }

  void _validate() {
    if (!auth.isConfigured && !listensOnLoopback) {
      throw ConfigValueError(
        'listen',
        'refusing to listen on $listenHost without a password; '
            'run "tp-agent init" first',
      );
    }
    if (mode == AgentMode.relay) {
      throw ConfigValueError('mode', 'relay mode is not available in v1');
    }
    if (shell.command.isEmpty) {
      throw ConfigValueError('shell.command', 'must not be empty');
    }
  }

  static (String, int) _parseListen(String value) {
    final colon = value.lastIndexOf(':');
    if (colon <= 0 || colon == value.length - 1) {
      throw ConfigValueError('listen', 'expected host:port, got "$value"');
    }
    var host = value.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final port = int.tryParse(value.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) {
      throw ConfigValueError('listen', 'invalid port in "$value"');
    }
    return (host, port);
  }

  static String _normalizeBasePath(String value) {
    var path = value.trim();
    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    if (path.contains('//') || path.contains('..')) {
      throw ConfigValueError('base_path', 'invalid path "$value"');
    }
    return path;
  }

  static T _enum<T extends Enum>(String key, String value, List<T> values) {
    for (final v in values) {
      if (v.name == value) return v;
    }
    throw ConfigValueError(
      key,
      'must be one of ${values.map((v) => v.name).join(', ')}',
    );
  }
}

final _durationPattern = RegExp(r'^(\d+)\s*(ms|s|m|h|d)$');
final _bytesPattern = RegExp(r'^(\d+)\s*([KMG]i?B?|B)?$', caseSensitive: false);

/// Parses `15s`, `25ms`, `12h`, `3d`.
Duration parseDuration(String text) {
  final m = _durationPattern.firstMatch(text.trim());
  if (m == null) throw FormatException('invalid duration', text);
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)!) {
    'ms' => Duration(milliseconds: n),
    's' => Duration(seconds: n),
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}

/// Parses `1048576`, `256KB`, `2GB`, `64MiB` (binary multiples).
int parseBytes(String text) {
  final m = _bytesPattern.firstMatch(text.trim());
  if (m == null) throw FormatException('invalid size', text);
  final n = int.parse(m.group(1)!);
  final unit = (m.group(2) ?? 'B').toUpperCase();
  return switch (unit[0]) {
    'K' => n * 1024,
    'M' => n * 1024 * 1024,
    'G' => n * 1024 * 1024 * 1024,
    _ => n,
  };
}

/// Typed access to one TOML table with environment overrides.
final class _Section {
  _Section(this.prefix, this.map, this.env);

  final String prefix;
  final Map<String, Object?> map;
  final Map<String, String> env;

  bool get isEmpty => map.isEmpty;

  String _key(String key) => prefix.isEmpty ? key : '$prefix.$key';

  String? _override(String key) =>
      env['TP_${_key(key).toUpperCase().replaceAll('.', '_')}'];

  _Section section(String name) {
    final v = map[name];
    if (v == null) return _Section(name, const {}, env);
    if (v is! Map<String, Object?>) {
      throw ConfigValueError(name, 'must be a table');
    }
    return _Section(name, v, env);
  }

  String string(String key, String fallback) {
    final o = _override(key);
    if (o != null) return o;
    final v = map[key];
    if (v == null) return fallback;
    if (v is! String) throw ConfigValueError(_key(key), 'must be a string');
    return v;
  }

  int int_(String key, int fallback, {int min = 0, int? max}) {
    final o = _override(key);
    final int? v;
    if (o != null) {
      v = int.tryParse(o);
      if (v == null) throw ConfigValueError(_key(key), 'must be an integer');
    } else {
      final raw = map[key];
      if (raw == null) return fallback;
      if (raw is! int) throw ConfigValueError(_key(key), 'must be an integer');
      v = raw;
    }
    if (v < min || (max != null && v > max)) {
      throw ConfigValueError(_key(key), 'out of range');
    }
    return v;
  }

  bool bool_(String key, bool fallback) {
    final o = _override(key);
    if (o != null) {
      return switch (o.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        'false' || '0' || 'no' => false,
        _ => throw ConfigValueError(_key(key), 'must be true or false'),
      };
    }
    final v = map[key];
    if (v == null) return fallback;
    if (v is! bool) throw ConfigValueError(_key(key), 'must be true or false');
    return v;
  }

  Duration duration(String key, Duration fallback) {
    final raw = _override(key) ?? map[key];
    if (raw == null) return fallback;
    if (raw is! String) throw ConfigValueError(_key(key), 'must be a string');
    try {
      return parseDuration(raw);
    } on FormatException {
      throw ConfigValueError(_key(key), 'invalid duration "$raw"');
    }
  }

  int bytes(String key, int fallback, {required int min}) {
    final raw = _override(key) ?? map[key];
    if (raw == null) return fallback;
    final int value;
    if (raw is int) {
      value = raw;
    } else if (raw is String) {
      try {
        value = parseBytes(raw);
      } on FormatException {
        throw ConfigValueError(_key(key), 'invalid size "$raw"');
      }
    } else {
      throw ConfigValueError(_key(key), 'must be a size');
    }
    if (value < min) throw ConfigValueError(_key(key), 'must be >= $min');
    return value;
  }

  List<String> stringList(String key, List<String> fallback) {
    final v = map[key];
    if (v == null) return fallback;
    if (v is! List || v.any((e) => e is! String)) {
      throw ConfigValueError(_key(key), 'must be a list of strings');
    }
    return v.cast<String>();
  }

  Map<String, String> stringMap(String key, Map<String, String> fallback) {
    final v = map[key];
    if (v == null) return fallback;
    if (v is! Map<String, Object?> || v.values.any((e) => e is! String)) {
      throw ConfigValueError(_key(key), 'must be a table of strings');
    }
    return v.cast<String, String>();
  }
}
