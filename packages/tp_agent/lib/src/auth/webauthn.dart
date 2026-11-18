import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'cbor.dart';
import 'encoding.dart';

/// Why a WebAuthn ceremony was rejected.
final class WebAuthnException implements Exception {
  const WebAuthnException(this.message);

  final String message;

  @override
  String toString() => 'WebAuthnException: $message';
}

/// Relying-party settings for this agent.
final class RelyingParty {
  const RelyingParty({
    required this.id,
    required this.origin,
    this.name = 'Terminal Prompter',
  });

  /// RP ID: the host name without port (e.g. `tp.example.com`).
  final String id;

  /// Expected `clientDataJSON.origin`, e.g. `https://tp.example.com`.
  final String origin;
  final String name;
}

/// A registered passkey (public part only).
final class StoredCredential {
  StoredCredential({
    required this.id,
    required this.x,
    required this.y,
    required this.signCount,
    required this.name,
    required this.created,
    this.lastUsed,
  });

  /// Credential id (raw bytes).
  final Uint8List id;

  /// P-256 public key coordinates (32 bytes each).
  final Uint8List x;
  final Uint8List y;
  int signCount;
  String name;
  final DateTime created;
  DateTime? lastUsed;

  String get idB64 => b64Url(id);

  Map<String, Object?> toJson() => {
    'id': b64Url(id),
    'x': b64Url(x),
    'y': b64Url(y),
    'sign_count': signCount,
    'name': name,
    'created': created.toIso8601String(),
    if (lastUsed != null) 'last_used': lastUsed!.toIso8601String(),
  };

  static StoredCredential fromJson(Map<String, Object?> json) =>
      StoredCredential(
        id: b64UrlDecode(json['id']! as String),
        x: b64UrlDecode(json['x']! as String),
        y: b64UrlDecode(json['y']! as String),
        signCount: json['sign_count']! as int,
        name: json['name']! as String,
        created: DateTime.parse(json['created']! as String),
        lastUsed: json['last_used'] == null
            ? null
            : DateTime.parse(json['last_used']! as String),
      );
}

/// Parsed authenticator data (WebAuthn §6.1).
final class AuthenticatorData {
  AuthenticatorData._(
    this.raw,
    this.rpIdHash,
    this.flags,
    this.signCount,
    this.credentialId,
    this.publicKey,
  );

  static const int flagUserPresent = 0x01;
  static const int flagUserVerified = 0x04;
  static const int flagAttested = 0x40;
  static const int flagExtensions = 0x80;

  factory AuthenticatorData.parse(Uint8List raw) {
    if (raw.length < 37) {
      throw const WebAuthnException('authenticator data too short');
    }
    final rpIdHash = Uint8List.sublistView(raw, 0, 32);
    final flags = raw[32];
    final signCount = ByteData.sublistView(raw, 33, 37).getUint32(0);
    Uint8List? credId;
    Map<Object?, Object?>? key;
    var pos = 37;
    if (flags & flagAttested != 0) {
      if (raw.length < pos + 18) {
        throw const WebAuthnException('attested data too short');
      }
      pos += 16; // AAGUID
      final idLen = (raw[pos] << 8) | raw[pos + 1];
      pos += 2;
      if (idLen > 1023 || raw.length < pos + idLen) {
        throw const WebAuthnException('bad credential id length');
      }
      credId = Uint8List.fromList(raw.sublist(pos, pos + idLen));
      pos += idLen;
      final decoder = CborDecoder(Uint8List.sublistView(raw, pos));
      final decoded = decoder.decode();
      if (decoded is! Map<Object?, Object?>) {
        throw const WebAuthnException('public key is not a map');
      }
      key = decoded;
      pos += decoder.offset;
    }
    if (flags & flagExtensions != 0) {
      final decoder = CborDecoder(Uint8List.sublistView(raw, pos));
      decoder.decode();
      pos += decoder.offset;
    }
    if (pos != raw.length) {
      throw const WebAuthnException('trailing bytes in authenticator data');
    }
    return AuthenticatorData._(raw, rpIdHash, flags, signCount, credId, key);
  }

  final Uint8List raw;
  final Uint8List rpIdHash;
  final int flags;
  final int signCount;
  final Uint8List? credentialId;
  final Map<Object?, Object?>? publicKey;

  bool get userPresent => flags & flagUserPresent != 0;
  bool get userVerified => flags & flagUserVerified != 0;
}

/// Server-side WebAuthn verification: ES256 passkeys, user verification
/// required, attestation statements ignored (ADR-017).
final class WebAuthnVerifier {
  const WebAuthnVerifier(this.rp);

  final RelyingParty rp;

  /// Verifies a registration (`navigator.credentials.create`). Returns the
  /// credential to store.
  StoredCredential verifyRegistration({
    required Uint8List clientDataJson,
    required Uint8List attestationObject,
    required Uint8List expectedChallenge,
    required String name,
    DateTime? now,
  }) {
    _checkClientData(clientDataJson, 'webauthn.create', expectedChallenge);
    final Object? att;
    try {
      att = CborDecoder.decodeAll(attestationObject);
    } on CborException catch (e) {
      throw WebAuthnException('attestation object: ${e.message}');
    }
    if (att is! Map<Object?, Object?>) {
      throw const WebAuthnException('attestation object is not a map');
    }
    final authDataRaw = att['authData'];
    if (att['fmt'] is! String || authDataRaw is! Uint8List) {
      throw const WebAuthnException('attestation object lacks fmt/authData');
    }
    final authData = _parseAuthData(authDataRaw);
    _checkFlags(authData);
    final credId = authData.credentialId;
    final key = authData.publicKey;
    if (credId == null || key == null) {
      throw const WebAuthnException('no attested credential');
    }
    final (x, y) = _es256Key(key);
    return StoredCredential(
      id: credId,
      x: x,
      y: y,
      signCount: authData.signCount,
      name: name,
      created: (now ?? DateTime.now()).toUtc(),
    );
  }

  /// Verifies an assertion (`navigator.credentials.get`) against [credential]
  /// and updates its sign counter.
  void verifyAssertion({
    required StoredCredential credential,
    required Uint8List clientDataJson,
    required Uint8List authenticatorData,
    required Uint8List signature,
    required Uint8List expectedChallenge,
    DateTime? now,
  }) {
    _checkClientData(clientDataJson, 'webauthn.get', expectedChallenge);
    final authData = _parseAuthData(authenticatorData);
    _checkFlags(authData);
    final signed = Uint8List.fromList([
      ...authenticatorData,
      ...sha256.convert(clientDataJson).bytes,
    ]);
    if (!verifyEs256(credential.x, credential.y, signed, signature)) {
      throw const WebAuthnException('signature does not verify');
    }
    final count = authData.signCount;
    if ((count != 0 || credential.signCount != 0) &&
        count <= credential.signCount) {
      throw const WebAuthnException(
        'signature counter did not increase (cloned authenticator?)',
      );
    }
    credential
      ..signCount = count
      ..lastUsed = (now ?? DateTime.now()).toUtc();
  }

  AuthenticatorData _parseAuthData(Uint8List raw) {
    final AuthenticatorData data;
    try {
      data = AuthenticatorData.parse(raw);
    } on CborException catch (e) {
      throw WebAuthnException('authenticator data: ${e.message}');
    }
    final expected = sha256.convert(utf8.encode(rp.id)).bytes;
    if (!constantTimeEquals(data.rpIdHash, expected)) {
      throw const WebAuthnException('rpId hash mismatch');
    }
    return data;
  }

  void _checkFlags(AuthenticatorData data) {
    if (!data.userPresent) throw const WebAuthnException('user not present');
    if (!data.userVerified) throw const WebAuthnException('user not verified');
  }

  void _checkClientData(Uint8List raw, String type, Uint8List challenge) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      throw const WebAuthnException('clientDataJSON is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const WebAuthnException('clientDataJSON is not an object');
    }
    if (json['type'] != type) {
      throw WebAuthnException('clientData type is not $type');
    }
    final c = json['challenge'];
    if (c is! String) throw const WebAuthnException('missing challenge');
    final Uint8List got;
    try {
      got = b64UrlDecode(c);
    } on FormatException {
      throw const WebAuthnException('bad challenge encoding');
    }
    if (!constantTimeEquals(got, challenge)) {
      throw const WebAuthnException('challenge mismatch');
    }
    if (json['origin'] != rp.origin) {
      throw WebAuthnException('origin mismatch: ${json['origin']}');
    }
    if (json['crossOrigin'] == true) {
      throw const WebAuthnException('cross-origin ceremony');
    }
  }

  static (Uint8List, Uint8List) _es256Key(Map<Object?, Object?> cose) {
    if (cose[1] != 2 || cose[3] != -7 || cose[-1] != 1) {
      throw const WebAuthnException(
        'only ES256 (EC2, P-256) keys are supported',
      );
    }
    final x = cose[-2];
    final y = cose[-3];
    if (x is! Uint8List ||
        y is! Uint8List ||
        x.length != 32 ||
        y.length != 32) {
      throw const WebAuthnException('bad EC2 coordinates');
    }
    if (!isOnP256(_bigInt(x), _bigInt(y))) {
      throw const WebAuthnException('public key is not on the curve');
    }
    return (Uint8List.fromList(x), Uint8List.fromList(y));
  }
}

/// ECDSA P-256 / SHA-256 verification of a DER signature.
bool verifyEs256(
  Uint8List x,
  Uint8List y,
  Uint8List message,
  Uint8List derSignature,
) {
  final (BigInt, BigInt) rs;
  try {
    rs = parseDerSignature(derSignature);
  } on FormatException {
    return false;
  }
  final (r, s) = rs;
  final px = _bigInt(x);
  final py = _bigInt(y);
  if (!isOnP256(px, py)) return false;
  final domain = ECCurve_secp256r1();
  final q = domain.curve.createPoint(px, py);
  if (r <= BigInt.zero || s <= BigInt.zero || r >= domain.n || s >= domain.n) {
    return false;
  }
  final signer = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter(ECPublicKey(q, domain)));
  return signer.verifySignature(message, ECSignature(r, s));
}

/// Parses `SEQUENCE { INTEGER r, INTEGER s }`.
(BigInt, BigInt) parseDerSignature(Uint8List der) {
  var pos = 0;
  int byte() {
    if (pos >= der.length) throw const FormatException('DER: unexpected end');
    return der[pos++];
  }

  int length() {
    final first = byte();
    if (first < 0x80) return first;
    if (first == 0x81) {
      final l = byte();
      if (l < 0x80) throw const FormatException('DER: non-minimal length');
      return l;
    }
    throw const FormatException('DER: length form not supported');
  }

  BigInt integer() {
    if (byte() != 0x02) throw const FormatException('DER: expected INTEGER');
    final len = length();
    if (len == 0 || len > 33 || pos + len > der.length) {
      throw const FormatException('DER: bad INTEGER length');
    }
    final bytes = der.sublist(pos, pos + len);
    pos += len;
    if (bytes[0] & 0x80 != 0) {
      throw const FormatException('DER: negative INTEGER');
    }
    return _bigInt(bytes);
  }

  if (byte() != 0x30) throw const FormatException('DER: expected SEQUENCE');
  final seqLen = length();
  if (pos + seqLen != der.length) {
    throw const FormatException('DER: SEQUENCE length mismatch');
  }
  final r = integer();
  final s = integer();
  if (pos != der.length) throw const FormatException('DER: trailing bytes');
  return (r, s);
}

final BigInt _p256P = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _p256B = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);

/// True when (x, y) is a point on P-256 (y² = x³ − 3x + b mod p), which
/// rules out invalid-curve inputs before any arithmetic with them.
bool isOnP256(BigInt x, BigInt y) {
  if (x < BigInt.zero || y < BigInt.zero || x >= _p256P || y >= _p256P) {
    return false;
  }
  final left = (y * y) % _p256P;
  final right = (x * x * x - BigInt.from(3) * x + _p256B) % _p256P;
  return left == right;
}

BigInt _bigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}
