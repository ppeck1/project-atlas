import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

/// Small persistent store for integration credentials protected by the current
/// Windows user's DPAPI key. The file holds ciphertext only.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class WindowsSecretStore implements SecretStore {
  static const _fileName = 'atlas_secure_secrets.json';
  static const _description = 'Project Atlas integration secret';

  const WindowsSecretStore();

  @override
  Future<String?> read(String key) async {
    final values = await _readValues();
    final encoded = values[key];
    if (encoded is! String || encoded.isEmpty) return null;
    try {
      return _unprotect(base64Decode(encoded));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final values = await _readValues();
    values[key] = base64Encode(_protect(utf8.encode(value)));
    await _writeValues(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _readValues();
    if (values.remove(key) != null) await _writeValues(values);
  }

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, _fileName));
  }

  Future<Map<String, Object?>> _readValues() async {
    final file = await _file();
    if (!await file.exists()) return <String, Object?>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  Future<void> _writeValues(Map<String, Object?> values) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(values), flush: true);
  }

  List<int> _protect(List<int> value) => _crypt(value, protect: true);
  String _unprotect(List<int> value) => utf8.decode(_crypt(value));

  List<int> _crypt(List<int> value, {bool protect = false}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows DPAPI is required for secret storage.');
    }
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final inputBytes = calloc<Uint8>(value.length);
    final description = protect ? _description.toNativeUtf16() : nullptr;
    final outputDescription = calloc<Pointer<Utf16>>();
    try {
      input.ref
        ..cbData = value.length
        ..pbData = inputBytes;
      inputBytes.asTypedList(value.length).setAll(0, value);
      final ok = protect
          ? CryptProtectData(
              input,
              description.cast<Utf16>(),
              nullptr.cast<CRYPT_INTEGER_BLOB>(),
              nullptr,
              nullptr.cast<CRYPTPROTECT_PROMPTSTRUCT>(),
              1,
              output,
            )
          : CryptUnprotectData(
              input,
              outputDescription,
              nullptr.cast<CRYPT_INTEGER_BLOB>(),
              nullptr,
              nullptr.cast<CRYPTPROTECT_PROMPTSTRUCT>(),
              1,
              output,
            );
      if (ok == 0) throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      return List<int>.from(output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      if (output.ref.pbData != nullptr) LocalFree(output.ref.pbData);
      if (outputDescription.value != nullptr)
        LocalFree(outputDescription.value);
      calloc.free(description);
      calloc.free(outputDescription);
      calloc.free(inputBytes);
      calloc.free(output);
      calloc.free(input);
    }
  }
}

/// Test-only implementation that keeps protected values out of the filesystem.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
