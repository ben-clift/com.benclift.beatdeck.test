import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sidedeck/ui/milkdrop_photo_store.dart';
import 'package:sidedeck/ui/milkdrop_view.dart';
import 'package:sidedeck/ui/photo_archive_page.dart';

enum _When { any, week, month, year, custom }

/// Browse the phone's photos by album (Camera, Screenshots, WhatsApp, Download,
/// and so on) and by date, tick the ones you want and add them to the visuals.
class PhotoGalleryPage extends StatefulWidget {
  const PhotoGalleryPage({super.key});

  @override
  State<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}

class _PhotoGalleryPageState extends State<PhotoGalleryPage> {
  PermissionState? _perm;
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  _When _when = _When.any;
  DateTimeRange? _range;
  final List<AssetEntity> _assets = [];
  final Map<String, AssetEntity> _picked = {};
  int _page = 0;
  bool _more = true;
  bool _loading = false;
  bool _saving = false;
  bool _picking = false;
  int _count = 25;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _loadMore();
    });
    _init();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    PermissionState p;
    try {
      p = await PhotoManager.requestPermissionExtend();
    } catch (_) {
      p = PermissionState.denied;
    }
    if (!mounted) return;
    setState(() => _perm = p);
    if (p.hasAccess) await _loadAlbums();
  }

  FilterOptionGroup _filter() {
    final now = DateTime.now();
    DateTime? min;
    DateTime? max;
    switch (_when) {
      case _When.any:
        break;
      case _When.week:
        min = now.subtract(const Duration(days: 7));
      case _When.month:
        min = now.subtract(const Duration(days: 30));
      case _When.year:
        min = DateTime(now.year);
      case _When.custom:
        min = _range?.start;
        max = _range?.end.add(const Duration(days: 1));
    }
    if (min == null && max == null) return FilterOptionGroup();
    return FilterOptionGroup(
      createTimeCond: DateTimeCond(min: min ?? DateTime(1970), max: max ?? now.add(const Duration(days: 1))),
    );
  }

  Future<void> _loadAlbums() async {
    try {
      final list = await PhotoManager.getAssetPathList(type: RequestType.image, filterOption: _filter());
      if (!mounted) return;
      // Keep the album that was open, if it is still there.
      AssetPathEntity? keep;
      for (final a in list) {
        if (_album != null && a.id == _album!.id) keep = a;
      }
      setState(() {
        _albums = list;
        _album = keep ?? (list.isEmpty ? null : list.first);
      });
    } catch (_) {
      if (mounted) setState(() => _albums = []);
    }
    await _reset();
  }

  Future<void> _reset() async {
    setState(() {
      _assets.clear();
      _page = 0;
      _more = true;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_more || _album == null) return;
    _loading = true;
    try {
      final got = await _album!.getAssetListPaged(page: _page, size: 60);
      if (!mounted) return;
      setState(() {
        _assets.addAll(got);
        _page++;
        _more = got.length == 60;
      });
    } catch (_) {
      _more = false;
    }
    _loading = false;
    if (mounted) setState(() {});
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: _range,
    );
    if (r == null) return;
    _range = r;
    _when = _When.custom;
    await _loadAlbums();
  }

  Future<void> _setWhen(_When w) async {
    if (w == _When.custom) {
      await _pickDates();
      return;
    }
    _when = w;
    await _loadAlbums();
  }

  /// Ticks the first photos of the open album, as many as there is room for.
  Future<void> _selectAllAlbum(int room) async {
    final al = _album;
    if (al == null || _picking || room <= 0) return;
    setState(() => _picking = true);
    try {
      final list = await al.getAssetListRange(start: 0, end: room);
      if (!mounted) return;
      setState(() {
        _picked.clear();
        for (final a in list) {
          _picked[a.id] = a;
        }
      });
    } catch (_) {}
    if (mounted) setState(() => _picking = false);
  }

  /// Ticks a number of photos chosen at random from the whole open album.
  Future<void> _randomAlbum(int room) async {
    final al = _album;
    if (al == null || _picking || room <= 0) return;
    setState(() => _picking = true);
    try {
      final total = await al.assetCountAsync;
      final n = math.min(_count, math.min(room, total));
      final idx = List<int>.generate(total, (i) => i)..shuffle(math.Random());
      final chosen = <AssetEntity>[];
      for (final i in idx.take(n)) {
        final one = await al.getAssetListRange(start: i, end: i + 1);
        if (one.isNotEmpty) chosen.add(one.first);
      }
      if (!mounted) return;
      setState(() {
        _picked.clear();
        for (final a in chosen) {
          _picked[a.id] = a;
        }
      });
    } catch (_) {}
    if (mounted) setState(() => _picking = false);
  }

  String _albumName(AssetPathEntity a) => a.isAll ? 'Everything' : a.name;

  Future<void> _use() async {
    if (_picked.isEmpty || _saving) return;
    setState(() => _saving = true);
    final out = <Uint8List>[];
    for (final a in _picked.values) {
      try {
        final w = a.orientatedWidth, h = a.orientatedHeight;
        final s = 900 / math.max(1, math.max(w, h));
        final size = ThumbnailSize(math.max(1, (w * s).round()), math.max(1, (h * s).round()));
        final b = await a.thumbnailDataWithSize(size, quality: 72);
        if (b != null) out.add(b);
      } catch (_) {}
    }
    final n = await MilkdropPhotos.instance.addBytes(out);
    if (!mounted) return;
    Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    final room = MilkdropPhotos.maxPhotos - MilkdropPhotos.instance.files.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose photos'), toolbarHeight: 48),
      body: _body(room),
      bottomNavigationBar: _picked.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _use,
                    icon: const Icon(Icons.check),
                    label: Text(_saving ? 'Adding…' : 'Use ${_picked.length} photo${_picked.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _body(int room) {
    if (_perm == null) return const Center(child: CircularProgressIndicator());
    if (!_perm!.hasAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('BeatDeck needs permission to see your photos.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('It only reads them to show them over the visuals. Nothing is uploaded.',
                textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFB8B3AA))),
            const SizedBox(height: 16),
            FilledButton(onPressed: _init, child: const Text('Allow access')),
            TextButton(onPressed: PhotoManager.openSetting, child: const Text('Open phone settings')),
          ]),
        ),
      );
    }
    const whens = [
      (_When.any, 'Any time'),
      (_When.week, 'Last 7 days'),
      (_When.month, 'Last 30 days'),
      (_When.year, 'This year'),
      (_When.custom, 'Pick dates'),
    ];
    return Column(children: [
      if (_perm == PermissionState.limited)
        ListTile(
          dense: true,
          title: const Text('The phone is only showing the photos you allowed.'),
          trailing: TextButton(onPressed: PhotoManager.presentLimited, child: const Text('Allow more')),
        ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final a in _albums)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
              child: ChoiceChip(
                label: Text(_albumName(a)),
                selected: _album?.id == a.id,
                onSelected: (_) {
                  _album = a;
                  _reset();
                },
              ),
            ),
        ]),
      ),
      SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final w in whens)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
              child: ChoiceChip(
                avatar: w.$1 == _When.custom ? const Icon(Icons.date_range, size: 16) : null,
                label: Text(w.$1 == _When.custom && _when == _When.custom && _range != null
                    ? '${_d(_range!.start)} to ${_d(_range!.end)}'
                    : w.$2),
                selected: _when == w.$1,
                onSelected: (_) => _setWhen(w.$1),
              ),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(
            child: Text(
              '${_picked.length} ticked, room for $room more. Tap a photo to tick it.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A857C)),
            ),
          ),
          if (_picked.isNotEmpty) TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear ticks')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton(
            onPressed: _picking || _album == null ? null : () => _selectAllAlbum(room),
            child: Text('Select all (up to $room)'),
          ),
          FilledButton.tonalIcon(
            onPressed: _picking || _album == null ? null : () => _randomAlbum(room),
            icon: const Icon(Icons.shuffle),
            label: Text(_picking ? 'Picking…' : 'Random $_count'),
          ),
          for (final c in const [10, 25, 50, 100, 200])
            if (c <= math.max(room, 10))
              ChoiceChip(
                label: Text('$c'),
                selected: _count == c,
                onSelected: _picking ? null : (_) => setState(() => _count = c),
              ),
        ]),
      ),
      Expanded(
        child: _assets.isEmpty
            ? Center(child: Text(_loading ? 'Loading…' : 'No photos here for those choices.'))
            : GridView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, mainAxisSpacing: 2, crossAxisSpacing: 2),
                itemCount: _assets.length,
                itemBuilder: (_, i) {
                  final a = _assets[i];
                  final on = _picked.containsKey(a.id);
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (on) {
                          _picked.remove(a.id);
                        } else if (_picked.length < room) {
                          _picked[a.id] = a;
                        }
                      });
                    },
                    child: Stack(fit: StackFit.expand, children: [
                      _Thumb(asset: a),
                      if (on) Container(color: const Color(0x66000000)),
                      if (on)
                        const Positioned(right: 4, top: 4, child: Icon(Icons.check_circle, color: Color(0xFFFF5A2B), size: 22)),
                    ]),
                  );
                },
              ),
      ),
    ]);
  }

  static String _d(DateTime d) => '${d.day}/${d.month}/${d.year % 100}';
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.asset});
  final AssetEntity asset;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  late final Future<Uint8List?> _f = widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(220));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _f,
      builder: (_, s) => s.data == null
          ? const ColoredBox(color: Color(0xFF1B1512))
          : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

/// "Your photos" section of the Visuals settings: pick photos, how strongly
/// they show, and how long each stays.
class MilkdropPhotoControls extends StatefulWidget {
  const MilkdropPhotoControls({super.key});

  @override
  State<MilkdropPhotoControls> createState() => _MilkdropPhotoControlsState();
}

class _MilkdropPhotoControlsState extends State<MilkdropPhotoControls> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    MilkdropPhotos.instance.load();
  }

  void _afterAdd(int n) {
    final m = MilkdropSettings.instance;
    if (n > 0 && m.photoStrength == 0) m.set(photoV: 0.5);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n > 0 ? 'Added $n photo${n == 1 ? '' : 's'}.' : 'No photos added.')));
    }
  }

  Future<void> _gallery() async {
    final n = await Navigator.of(context).push<int>(MaterialPageRoute<int>(builder: (_) => const PhotoGalleryPage()));
    if (n != null) _afterAdd(n);
  }

  Future<void> _archive() async {
    final n = await Navigator.of(context).push<int>(MaterialPageRoute<int>(builder: (_) => const PhotoArchivePage()));
    if (n != null) _afterAdd(n);
  }

  /// The phone's own picker. On many phones it shows Google Photos, with its
  /// people, places and albums.
  Future<void> _system() async {
    if (_busy) return;
    setState(() => _busy = true);
    var n = 0;
    try {
      final picks = await ImagePicker().pickMultiImage(maxWidth: 900, maxHeight: 900, imageQuality: 72);
      final out = <Uint8List>[];
      for (final x in picks) {
        out.add(await x.readAsBytes());
      }
      n = await MilkdropPhotos.instance.addBytes(out);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    _afterAdd(n);
  }

  @override
  Widget build(BuildContext context) {
    final m = MilkdropSettings.instance;
    final ph = MilkdropPhotos.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([m, ph]),
      builder: (context, _) {
        final n = ph.files.length;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Your photos', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          Text(n == 0 ? 'None yet. They melt slowly into the picture.' : '$n photo${n == 1 ? '' : 's'} (up to ${MilkdropPhotos.maxPhotos})',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A857C))),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: n >= MilkdropPhotos.maxPhotos ? null : _gallery,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose from my gallery'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: n >= MilkdropPhotos.maxPhotos || _busy ? null : _system,
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('Phone photo picker (people, places)'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: n >= MilkdropPhotos.maxPhotos || _busy ? null : _archive,
            icon: const Icon(Icons.public),
            label: const Text('Online archive: thousands of famous pictures'),
          ),
          if (n > 0) ...[
            const SizedBox(height: 8),
            Text('Photo strength: ${m.photoStrength <= 0 ? 'off' : '${(m.photoStrength * 100).round()}%'}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Slider(value: m.photoStrength, onChanged: (v) => m.set(photoV: v)),
            const Text('Each photo stays for', style: TextStyle(fontWeight: FontWeight.w700)),
            Wrap(spacing: 8, children: [
              for (final s in const [10, 20, 30, 60, 120])
                ChoiceChip(
                  label: Text(s < 60 ? '${s}s' : '${s ~/ 60}m'),
                  selected: m.photoSecs == s,
                  onSelected: (_) => m.set(photoSecsV: s),
                ),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: ph.clear, icon: const Icon(Icons.delete_outline), label: const Text('Remove all photos')),
            ),
          ],
          const Divider(height: 28),
        ]);
      },
    );
  }
}
