import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Uploads tracks to the signed-in person's own Google Drive, into
/// <root>/<genre> folders it creates. Only touches files and folders this app
/// made (the narrow "drive.file" permission), never the rest of the Drive.
class DriveUploader {
  DriveUploader(this.root);
  final String root;

  static final GoogleSignIn _gs = GoogleSignIn(scopes: const ['https://www.googleapis.com/auth/drive.file']);
  static const _doneKey = 'drive_uploaded_v1';
  final Map<String, String> _folders = {};
  Set<String> _done = {};
  bool cancelled = false;

  String? get account => _gs.currentUser?.email;

  Future<GoogleSignInAccount> _user() async {
    final u = _gs.currentUser ?? await _gs.signInSilently() ?? await _gs.signIn();
    if (u == null) throw 'Google sign-in was cancelled.';
    return u;
  }

  Future<Map<String, String>> _headers({bool refresh = false}) async {
    final u = await _user();
    if (refresh) await u.clearAuthCache();
    return u.authHeaders;
  }

  Future<http.Response> _send(Future<http.Response> Function(Map<String, String> h) call) async {
    var r = await call(await _headers());
    if (r.statusCode == 401) r = await call(await _headers(refresh: true));
    return r;
  }

  Future<String> _folder(String name, String? parent) async {
    final key = '${parent ?? ''}/$name';
    final hit = _folders[key];
    if (hit != null) return hit;
    final safe = name.replaceAll("'", "\\'");
    final q = "name='$safe' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        "${parent != null ? " and '$parent' in parents" : " and 'root' in parents"}";
    final found = await _send((h) => http.get(
        Uri.https('www.googleapis.com', '/drive/v3/files', {'q': q, 'fields': 'files(id)', 'spaces': 'drive'}),
        headers: h));
    if (found.statusCode == 200) {
      final files = (jsonDecode(found.body)['files'] as List);
      if (files.isNotEmpty) return _folders[key] = files.first['id'] as String;
    }
    final made = await _send((h) => http.post(Uri.https('www.googleapis.com', '/drive/v3/files', {'fields': 'id'}),
        headers: {...h, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'mimeType': 'application/vnd.google-apps.folder',
          if (parent != null) 'parents': [parent],
        })));
    if (made.statusCode != 200) throw 'Could not create the Drive folder "$name" (${made.statusCode}).';
    return _folders[key] = jsonDecode(made.body)['id'] as String;
  }

  Future<void> _upload(File f, String parent) async {
    final name = f.uri.pathSegments.last;
    final len = await f.length();
    final start = await _send((h) => http.post(
        Uri.https('www.googleapis.com', '/upload/drive/v3/files', {'uploadType': 'resumable', 'fields': 'id'}),
        headers: {...h, 'Content-Type': 'application/json; charset=UTF-8', 'X-Upload-Content-Length': '$len'},
        body: jsonEncode({'name': name, 'parents': [parent]})));
    final loc = start.headers['location'];
    if (start.statusCode != 200 || loc == null) throw 'Drive refused the upload (${start.statusCode}).';
    final req = http.StreamedRequest('PUT', Uri.parse(loc))..contentLength = len;
    f.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError);
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 200 && res.statusCode != 201) throw 'Upload failed (${res.statusCode}).';
  }

  /// Uploads [items] (path, genre) one by one. [onProgress] gets (done, total, name).
  /// Returns (uploaded, skipped, failed).
  Future<({int uploaded, int skipped, int failed, String? lastError})> run(
    List<({String path, String genre})> items,
    void Function(int done, int total, String name) onProgress,
  ) async {
    await _user();
    final prefs = await SharedPreferences.getInstance();
    _done = (prefs.getStringList(_doneKey) ?? const []).toSet();
    final rootId = await _folder(root, null);
    var up = 0, skip = 0, fail = 0, n = 0;
    String? err;
    for (final it in items) {
      if (cancelled) break;
      final f = File(it.path);
      final name = f.uri.pathSegments.last;
      onProgress(n, items.length, name);
      n++;
      final sig = '${it.path}|${it.genre}';
      if (_done.contains(sig)) {
        skip++;
        continue;
      }
      try {
        final g = it.genre.replaceAll(RegExp(r'[\\/]'), '-').trim();
        final folder = await _folder(g.isEmpty ? 'Unsorted' : g, rootId);
        await _upload(f, folder);
        _done.add(sig);
        up++;
        if (up % 5 == 0) await prefs.setStringList(_doneKey, _done.toList());
      } catch (e) {
        fail++;
        err = '$e';
      }
    }
    await prefs.setStringList(_doneKey, _done.toList());
    onProgress(n, items.length, '');
    return (uploaded: up, skipped: skip, failed: fail, lastError: err);
  }
}
