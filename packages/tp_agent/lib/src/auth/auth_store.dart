import 'dart:convert';
import 'dart:io';

import '../log_util.dart';
import 'backup_codes.dart';
import 'encoding.dart';
import 'webauthn.dart';

/// Persistent authentication state that is not configuration: passkeys,
/// hashed backup codes and the last accepted TOTP step (replay guard).
/// Stored as JSON with mode 0600; writes are atomic (temp file + rename).
final class AuthState {
  AuthState({
    List<StoredCredential>? passkeys,
    this.backupCodes,
    this.totpLastStep,
    String? userHandle,
  }) : passkeys = passkeys ?? [],
       userHandle = userHandle ?? b64Url(randomBytes(16));

  final List<StoredCredential> passkeys;
  BackupCodeSet? backupCodes;
  int? totpLastStep;

  /// Stable WebAuthn user handle for the single agent account.
  final String userHandle;

  Map<String, Object?> toJson() => {
    'version': 1,
    'user_handle': userHandle,
    'passkeys': [for (final p in passkeys) p.toJson()],
    if (backupCodes != null) 'backup_codes': backupCodes!.toJson(),
    if (totpLastStep != null) 'totp_last_step': totpLastStep,
  };

  static AuthState fromJson(Map<String, Object?> json) {
    final passkeys = json['passkeys'];
    final codes = json['backup_codes'];
    return AuthState(
      userHandle: json['user_handle'] as String?,
      passkeys: [
        if (passkeys is List)
          for (final p in passkeys)
            StoredCredential.fromJson(p as Map<String, Object?>),
      ],
      backupCodes: codes is Map<String, Object?>
          ? BackupCodeSet.fromJson(codes)
          : null,
      totpLastStep: json['totp_last_step'] as int?,
    );
  }
}

/// Loads and saves [AuthState].
final class AuthStore {
  AuthStore(this.path);

  final String path;

  /// Reads the state; a missing file yields an empty state. A corrupt file
  /// is an error (never silently drop someone's passkeys).
  AuthState load() {
    final file = File(path);
    if (!file.existsSync()) return AuthState();
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw StateError('auth state $path is corrupt: ${e.message}');
    }
    if (json is! Map<String, Object?>) {
      throw StateError('auth state $path is not an object');
    }
    try {
      return AuthState.fromJson(json);
    } on Object catch (e) {
      throw StateError('auth state $path is invalid: $e');
    }
  }

  /// Writes atomically with owner-only permissions.
  void save(AuthState state) {
    writePrivateFile(
      path,
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
  }
}
