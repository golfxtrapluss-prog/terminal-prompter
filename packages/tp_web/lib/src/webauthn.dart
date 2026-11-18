import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Browser side of passkeys: turns the agent's JSON options into WebAuthn
/// calls and the results back into base64url JSON (docs/05, docs/16).
abstract final class Passkeys {
  /// True when the browser supports WebAuthn (secure context required).
  static bool get supported =>
      web.window.has('PublicKeyCredential') && web.window.isSecureContext;

  static Uint8List _b64(String s) =>
      base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));

  static String _enc(JSArrayBuffer? b) => b == null
      ? ''
      : base64Url.encode(b.toDart.asUint8List()).replaceAll('=', '');

  static JSObject _creds(Object? list) {
    final out = <JSObject>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map && item['id'] is String) {
          final o = JSObject()
            ..['type'] = 'public-key'.toJS
            ..['id'] = _b64(item['id']! as String).buffer.toJS;
          out.add(o);
        }
      }
    }
    return out.toJS;
  }

  /// `navigator.credentials.create` for registration.
  static Future<Map<String, Object?>> create(
    Map<String, Object?> options,
  ) async {
    final rp = options['rp']! as Map<String, Object?>;
    final user = options['user']! as Map<String, Object?>;
    final selection =
        options['authenticatorSelection']! as Map<String, Object?>;
    final publicKey = JSObject()
      ..['challenge'] = _b64(options['challenge']! as String).buffer.toJS
      ..['rp'] = (JSObject()
        ..['id'] = (rp['id']! as String).toJS
        ..['name'] = (rp['name']! as String).toJS)
      ..['user'] = (JSObject()
        ..['id'] = _b64(user['id']! as String).buffer.toJS
        ..['name'] = (user['name']! as String).toJS
        ..['displayName'] = (user['displayName']! as String).toJS)
      ..['pubKeyCredParams'] = [
        JSObject()
          ..['type'] = 'public-key'.toJS
          ..['alg'] = (-7).toJS,
      ].toJS
      ..['timeout'] = (options['timeout']! as int).toJS
      ..['attestation'] = 'none'.toJS
      ..['authenticatorSelection'] = (JSObject()
        ..['residentKey'] = (selection['residentKey']! as String).toJS
        ..['userVerification'] = 'required'.toJS)
      ..['excludeCredentials'] = _creds(options['excludeCredentials']);
    final cred =
        await web.window.navigator.credentials
                .create(
                  web.CredentialCreationOptions(
                    publicKey:
                        publicKey as web.PublicKeyCredentialCreationOptions,
                  ),
                )
                .toDart
            as web.PublicKeyCredential?;
    if (cred == null) throw StateError('cancelled');
    final response = cred.response as web.AuthenticatorAttestationResponse;
    return {
      'challengeId': options['challengeId'],
      'clientDataJSON': _enc(response.clientDataJSON),
      'attestationObject': _enc(response.attestationObject),
    };
  }

  /// `navigator.credentials.get` for login.
  static Future<Map<String, Object?>> get(Map<String, Object?> options) async {
    final publicKey = JSObject()
      ..['challenge'] = _b64(options['challenge']! as String).buffer.toJS
      ..['rpId'] = (options['rpId']! as String).toJS
      ..['timeout'] = (options['timeout']! as int).toJS
      ..['userVerification'] = 'required'.toJS
      ..['allowCredentials'] = _creds(options['allowCredentials']);
    final cred =
        await web.window.navigator.credentials
                .get(
                  web.CredentialRequestOptions(
                    publicKey:
                        publicKey as web.PublicKeyCredentialRequestOptions,
                  ),
                )
                .toDart
            as web.PublicKeyCredential?;
    if (cred == null) throw StateError('cancelled');
    final response = cred.response as web.AuthenticatorAssertionResponse;
    return {
      'challengeId': options['challengeId'],
      'id': _enc(cred.rawId),
      'clientDataJSON': _enc(response.clientDataJSON),
      'authenticatorData': _enc(response.authenticatorData),
      'signature': _enc(response.signature),
    };
  }
}
