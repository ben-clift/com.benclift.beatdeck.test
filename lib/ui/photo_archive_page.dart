import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sidedeck/ui/milkdrop_photo_store.dart';

const _metBase = 'https://collectionapi.metmuseum.org/public/collection';

/// One theme in the archive: a name and the search that fills it.
class ArchiveTheme {
  const ArchiveTheme(this.label, this.params);
  final String label;
  final Map<String, String> params;
}

const archiveThemes = <ArchiveTheme>[
  ArchiveTheme('Highlights', {'isHighlight': 'true'}),
  ArchiveTheme('Landscapes', {'q': 'landscape'}),
  ArchiveTheme('Portraits', {'q': 'portrait'}),
  ArchiveTheme('Flowers', {'q': 'flowers'}),
  ArchiveTheme('Sea and ships', {'q': 'sea'}),
  ArchiveTheme('Cities and streets', {'q': 'city'}),
  ArchiveTheme('Night', {'q': 'night'}),
  ArchiveTheme('Animals', {'q': 'animals'}),
  ArchiveTheme('Japanese prints', {'q': 'woodblock'}),
  ArchiveTheme('Photographs', {'q': 'photograph'}),
  ArchiveTheme('Patterns', {'q': 'pattern'}),
  ArchiveTheme('Impressionism', {'q': 'impressionism'}),
];

class _Obj {
  _Obj(this.id, this.title, this.small, this.publicDomain);
  final int id;
  final String title;
  final String small;
  final bool publicDomain;
  bool get ok => publicDomain && small.isNotEmpty;
}

/// Browse The Met's open collection (public domain, no sign-up) by theme,
/// tick pictures or randomise a number of them, and add them to the visuals.
class PhotoArchivePage extends StatefulWidget {
  const PhotoArchivePage({super.key});

  @override
  State<PhotoArchivePage> createState() => _PhotoArchivePageState();
}

class _PhotoArchivePageState extends State<PhotoArchivePage> {
  int _theme = 0;
  List<int> _ids = [];
  int _total = 0;
  bool _loading = false;
  String _error = '';
  final Set<int> _picked = {};
  final Map<int, Future<_Obj?>> _recs = {};
  final Map<int, _Obj?> _known = {};
  int _count = 25;
  bool _busy = false;
  int _got = 0;

  int get _room => math.max(0, MilkdropPhotos.maxPhotos - MilkdropPhotos.instance.files.length);

  @override
  void initState() {
    super.initState();
    MilkdropPhotos.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = '';
      _ids = [];
      _total = 0;
      _picked.clear();
    });
    final ids = <int>[];
    var total = 0;
    try {
      // Up to four pages of 500, so a theme can hold a couple of thousand.
      for (var page = 0; page < 4; page++) {
        final uri = Uri.parse('$_metBase/v1.1/search').replace(queryParameters: {
          ...archiveThemes[_theme].params,
          'hasImages': 'true',
          'offset': '${page * 500}',
          'limit': '500',
        });
        final r = await http.get(uri).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) throw Exception('status ${r.statusCode}');
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        total = (j['total'] as num?)?.toInt() ?? 0;
        final got = ((j['objectIDs'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
        ids.addAll(got);
        if (got.length < 500 || ids.length >= total) break;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not reach The Met archive. Check your connection and try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _ids = ids;
      _total = total;
      _loading = false;
    });
  }

  Future<_Obj?> _rec(int id) {
    return _recs.putIfAbsent(id, () async {
      try {
        final r = await http.get(Uri.parse('$_metBase/v1/objects/$id')).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) return null;
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final o = _Obj(
          id,
          (j['title'] as String?) ?? '',
          (j['primaryImageSmall'] as String?) ?? '',
          j['isPublicDomain'] == true,
        );
        _known[id] = o;
        return o;
      } catch (_) {
        return null;
      }
    });
  }

  void _selectAll() {
    final n = math.min(_room, _ids.length);
    setState(() {
      _picked
        ..clear()
        ..addAll(_ids.take(n));
    });
  }

  void _randomize() {
    final pool = List<int>.of(_ids)..shuffle(math.Random());
    final n = math.min(_count, math.min(_room, pool.length));
    setState(() {
      _picked
        ..clear()
        ..addAll(pool.take(n));
    });
  }

  /// Downloads the ticked pictures (and a few spares, in case some turn out
  /// not to be usable) and adds them to the visuals.
  Future<void> _use() async {
    if (_busy || _picked.isEmpty) return;
    setState(() {
      _busy = true;
      _got = 0;
    });
    final want = _picked.length;
    final spare = (List<int>.of(_ids)..removeWhere(_picked.contains)..shuffle(math.Random())).take(want);
    final queue = [..._picked, ...spare];
    final out = <Uint8List>[];
    var next = 0;
    Future<void> worker() async {
      while (out.length < want && next < queue.length) {
        final id = queue[next++];
        try {
          final o = await _rec(id);
          if (o == null || !o.ok) continue;
          final r = await http.get(Uri.parse(o.small)).timeout(const Duration(seconds: 25));
          if (r.statusCode == 200 && r.bodyBytes.isNotEmpty && out.length < want) out.add(r.bodyBytes);
        } catch (_) {}
        if (mounted) setState(() => _got = out.length);
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    final n = await MilkdropPhotos.instance.addBytes(out);
    if (!mounted) return;
    Navigator.of(context).pop(n);
  }

  Widget _tile(int id) {
    final sel = _picked.contains(id);
    return GestureDetector(
      onTap: () {
        if (_known[id]?.ok != true) return;
        setState(() {
          if (sel) {
            _picked.remove(id);
          } else if (_picked.length < _room) {
            _picked.add(id);
          }
        });
      },
      child: FutureBuilder<_Obj?>(
        future: _rec(id),
        builder: (context, snap) {
          final o = snap.data;
          return Stack(fit: StackFit.expand, children: [
            if (o != null && o.ok)
              Image.network(o.small,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF222222)))
            else
              const ColoredBox(color: Color(0xFF1A1A1A)),
            if (sel)
              Container(
                color: Colors.black54,
                child: const Icon(Icons.check_circle, color: Colors.white, size: 30),
              ),
          ]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final counts = [for (final c in const [10, 25, 50, 100, 200]) if (c <= math.max(room, 10)) c];
    if (!counts.contains(_count)) _count = counts.last;
    return Scaffold(
      appBar: AppBar(title: const Text('Photo archive'), toolbarHeight: 48),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (var i = 0; i < archiveThemes.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
                child: ChoiceChip(
                  label: Text(archiveThemes[i].label),
                  selected: _theme == i,
                  onSelected: _busy
                      ? null
                      : (_) {
                          _theme = i;
                          _search();
                        },
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _loading
                  ? 'Searching…'
                  : (_error.isNotEmpty ? _error : '$_total pictures in this theme. ${_picked.length} ticked, room for $room more.'),
              style: const TextStyle(color: Color(0xFF8A857C), fontSize: 13),
            ),
          ),
        ),
        if (_error.isNotEmpty)
          TextButton(onPressed: _search, child: const Text('Try again')),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Wrap(spacing: 8, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton(
              onPressed: _ids.isEmpty || _busy ? null : _selectAll,
              child: Text('Select all (up to $room)'),
            ),
            FilledButton.tonalIcon(
              onPressed: _ids.isEmpty || _busy ? null : _randomize,
              icon: const Icon(Icons.shuffle),
              label: Text('Random $_count'),
            ),
            if (_picked.isNotEmpty)
              TextButton(onPressed: _busy ? null : () => setState(_picked.clear), child: const Text('Clear')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(children: [
            const Text('How many: ', style: TextStyle(fontWeight: FontWeight.w700)),
            Expanded(
              child: Wrap(spacing: 6, children: [
                for (final c in counts)
                  ChoiceChip(
                    label: Text('$c'),
                    selected: _count == c,
                    onSelected: _busy ? null : (_) => setState(() => _count = c),
                  ),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, mainAxisSpacing: 3, crossAxisSpacing: 3),
                  itemCount: _ids.length,
                  itemBuilder: (_, i) => _tile(_ids[i]),
                ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Pictures: The Metropolitan Museum of Art, Open Access (public domain, CC0).',
              style: TextStyle(color: Color(0xFF8A857C), fontSize: 11)),
        ),
      ]),
      bottomNavigationBar: _picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _use,
                    icon: const Icon(Icons.check),
                    label: Text(_busy ? 'Adding $_got of ${_picked.length}…' : 'Use ${_picked.length} picture${_picked.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ),
    );
  }
}
