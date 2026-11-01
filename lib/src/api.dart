import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

final _rng = Random.secure();

/// A random (v4) UUID.
String newUuid() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// HTTP to the public client endpoints: the site key as bearer, and an Idempotency-Key on every POST.
class Api {
  Api(this.baseUrl, this.siteKey, this.client, {required this.retryBase, this.maxRetries = 5});

  final String baseUrl;
  final String siteKey;
  final http.Client client;
  final Duration retryBase;
  final int maxRetries;

  Uri uri(String path, [Map<String, String?> query = const {}]) {
    // `/client/*` endpoints also take the public key as `company_id`.
    final q = <String, String>{if (path.startsWith('/client/')) 'company_id': siteKey};
    for (final MapEntry(:key, :value) in query.entries) {
      if (value != null && value.isNotEmpty) q[key] = value;
    }
    final u = Uri.parse('${baseUrl.replaceFirst(RegExp(r'/+$'), '')}$path');
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  Map<String, String> _headers([String? idempotencyKey]) => {
        'content-type': 'application/json',
        'authorization': 'Bearer $siteKey',
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
      };

  /// Null on a network error.
  Future<http.Response?> get(String path, [Map<String, String?> query = const {}]) async {
    try {
      return await client.get(uri(path, query), headers: _headers());
    } catch (_) {
      return null;
    }
  }

  /// One attempt. Null on a network error.
  Future<http.Response?> post(String path, Object body, {String? idempotencyKey}) async {
    try {
      return await client.post(uri(path), headers: _headers(idempotencyKey ?? newUuid()), body: jsonEncode(body));
    } catch (_) {
      return null;
    }
  }

  /// Retries 5xx, 429 and network errors with backoff, reusing one Idempotency-Key. True once the server took the
  /// body, or refused it for good (4xx will not improve on retry).
  Future<bool> send(String path, Object body) async {
    final key = newUuid();
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      final res = await post(path, body, idempotencyKey: key);
      if (res != null && res.statusCode < 500 && res.statusCode != 429) return true;
      if (attempt < maxRetries - 1) {
        final jitter = Duration(milliseconds: _rng.nextInt(retryBase.inMilliseconds + 1));
        await Future<void>.delayed(retryBase * (1 << attempt) + jitter);
      }
    }
    return false;
  }
}

/// The JSON body of [res] when it is a 2xx object, else null.
Map<String, Object?>? jsonBody(http.Response? res) {
  if (res == null || res.statusCode < 200 || res.statusCode >= 300) return null;
  try {
    final v = jsonDecode(utf8.decode(res.bodyBytes));
    return v is Map<String, Object?> ? v : null;
  } catch (_) {
    return null;
  }
}
