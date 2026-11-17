import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mo_genui/src/catalog/catalog.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget sizes on the board: S = half width (two side by side), M and L = full width
/// (L also lets the card use its full height on tablets; on a phone both are full width).
const List<String> kBoardSizes = <String>['S', 'M', 'L'];

/// One pinned answer, saved locally (the plan keeps pins on the device, never on a server).
class BoardItem {
  BoardItem({required this.id, required this.title, required this.component, required this.data, required this.question, this.size = 'M'});
  final String id;
  final String title;
  final String component;
  final Map<String, dynamic> data;
  final String question;
  String size;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'component': component,
        'question': question,
        'size': size,
        'data': <String, dynamic>{
          for (final e in data.entries)
            if (e.value is ScripRef)
              e.key: <String, dynamic>{'__scrip': (e.value as ScripRef).toJson()}
            else if (e.value is FundRef)
              e.key: <String, dynamic>{
                '__fund': <String, dynamic>{'isin': (e.value as FundRef).isin, 'name': (e.value as FundRef).name}
              }
            else if (e.value is List && (e.value as List).isNotEmpty && (e.value as List).every((x) => x is ScripRef))
              e.key: <String, dynamic>{
                '__scrips': [for (final r in e.value as List) (r as ScripRef).toJson()]
              }
            else if (e.value is List && (e.value as List).every((x) => x is FundRef))
              e.key: <String, dynamic>{
                '__funds': [
                  for (final f in e.value as List<FundRef>) <String, dynamic>{'isin': f.isin, 'name': f.name}
                ]
              }
            else if (e.value == null || e.value is num || e.value is String || e.value is bool || e.value is List<String>)
              e.key: e.value,
        },
      };

  static BoardItem fromJson(Map<String, dynamic> j) {
    final data = <String, dynamic>{};
    for (final e in (j['data'] as Map<String, dynamic>? ?? <String, dynamic>{}).entries) {
      final v = e.value;
      if (v is Map && v['__scrip'] is Map) {
        final s = Map<String, dynamic>.from(v['__scrip'] as Map);
        data[e.key] = ScripRef(scripCode: '${s['scripCode']}', exchange: '${s['exchange']}', exchangeCode: s['exchangeCode'] as int?, symbol: '${s['symbol']}', name: '${s['name']}');
      } else if (v is Map && v['__fund'] is Map) {
        final f = v['__fund'] as Map;
        data[e.key] = FundRef(isin: '${f['isin']}', name: '${f['name']}');
      } else if (v is Map && v['__scrips'] is List) {
        data[e.key] = <ScripRef>[
          for (final x in v['__scrips'] as List)
            ScripRef(scripCode: '${x['scripCode']}', exchange: '${x['exchange']}', exchangeCode: x['exchangeCode'] as int?, symbol: '${x['symbol']}', name: '${x['name']}')
        ];
      } else if (v is Map && v['__funds'] is List) {
        data[e.key] = <FundRef>[for (final f in v['__funds'] as List) FundRef(isin: '${f['isin']}', name: '${f['name']}')];
      } else {
        data[e.key] = v;
      }
    }
    return BoardItem(
        id: '${j['id']}', title: '${j['title']}', component: '${j['component']}', data: data, question: '${j['question'] ?? ''}', size: kBoardSizes.contains(j['size']) ? '${j['size']}' : 'M');
  }
}

/// Up to [kMaxBoards] boards, one per product or purpose ("Trading", "My funds", "F&O"),
/// each with its own pinned answers, sizes and order.
const int kMaxBoards = 5;

class Board {
  Board({required this.id, required this.name, List<BoardItem>? items}) : items = items ?? <BoardItem>[];
  final String id;
  String name;
  List<BoardItem> items;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'items': [for (final i in items) i.toJson()]
      };

  static Board fromJson(Map<String, dynamic> j) => Board(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Board'}',
        items: [for (final x in j['items'] as List? ?? const <dynamic>[]) BoardItem.fromJson(Map<String, dynamic>.from(x as Map))],
      );
}

/// The user's boards: pinned answers, their order and sizes, grouped into named boards.
/// Cards pin themselves through [CardScope]; the screen listens to [items] (the active
/// board's pins) for the pinned strip and the Board tab, and to [boards] for the board bar.
class GenUiBoard {
  GenUiBoard._();
  static const String _key = 'genui_boards_v1';
  static const String _legacyKey = 'genui_board_v1';

  /// Every board, in the user's order.
  static final ValueNotifier<List<Board>> boards = ValueNotifier<List<Board>>(<Board>[Board(id: 'b1', name: 'My board')]);

  /// Id of the board shown on the Board tab and used by "pin this".
  static final ValueNotifier<String> activeId = ValueNotifier<String>('b1');

  /// The active board's pins (derived; kept so cards and the screen need not know about boards).
  static final ValueNotifier<List<BoardItem>> items = ValueNotifier<List<BoardItem>>(<BoardItem>[]);
  static bool _loaded = false;

  static Board get active => byBoardId(activeId.value) ?? boards.value.first;
  static Board? byBoardId(String id) => boards.value.cast<Board?>().firstWhere((b) => b!.id == id, orElse: () => null);

  /// "fno", "my trading board": the board whose name matches best, or null.
  static Board? findBoard(String phrase) {
    final p = phrase.toLowerCase().replaceAll(RegExp(r'\b(the|my|board|dashboard|to|on|called|named)\b'), ' ').replaceAll(RegExp(r'[^a-z0-9& ]'), ' ').trim();
    if (p.isEmpty) return null;
    for (final b in boards.value) {
      if (b.name.toLowerCase() == p) return b;
    }
    for (final b in boards.value) {
      final n = b.name.toLowerCase();
      if (n.contains(p) || p.contains(n)) return b;
    }
    final words = p.split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
    Board? best;
    var score = 0;
    for (final b in boards.value) {
      final n = b.name.toLowerCase();
      final k = words.where((w) => n.contains(w)).length;
      if (k > score) {
        best = b;
        score = k;
      }
    }
    return best;
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      debugPrint('GenUI board load: raw ${raw?.length ?? 0} chars');
      if (raw != null && raw.isNotEmpty) {
        final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final list = [for (final b in j['boards'] as List? ?? const <dynamic>[]) Board.fromJson(Map<String, dynamic>.from(b as Map))];
        if (list.isNotEmpty) boards.value = list;
        final a = '${j['active'] ?? ''}';
        activeId.value = byBoardId(a) != null ? a : boards.value.first.id;
      } else {
        // First run after the upgrade: the single old board becomes "My board".
        final old = prefs.getString(_legacyKey);
        if (old != null && old.isNotEmpty) {
          boards.value = <Board>[
            Board(id: 'b1', name: 'My board', items: [for (final x in jsonDecode(old) as List) BoardItem.fromJson(Map<String, dynamic>.from(x as Map))])
          ];
          activeId.value = 'b1';
          await _save();
        }
      }
      _sync();
      _log('loaded');
    } catch (e) {
      debugPrint('GenUI board load failed: $e');
    }
  }

  static void _log(String why, {bool trace = false}) => debugPrint(
      'GenUI board $why → ${active.name}: [${items.value.map((i) => '${i.title}/${i.id}/${i.size}').join(', ')}] (${boards.value.length} boards)${trace ? '\n${StackTrace.current.toString().split('\n').take(7).join('\n')}' : ''}');

  /// Publishes the active board's pins and persists everything.
  static void _sync({bool save = true}) {
    items.value = List<BoardItem>.unmodifiable(active.items);
    boards.value = <Board>[...boards.value];
    if (save) _save();
  }

  static Future<void> _save() async {
    try {
      final ok = await (await SharedPreferences.getInstance()).setString(
          _key,
          jsonEncode(<String, dynamic>{
            'active': activeId.value,
            'boards': [for (final b in boards.value) b.toJson()]
          }));
      _log('saved ok=$ok');
    } catch (e) {
      debugPrint('GenUI board save failed: $e');
    }
  }

  // ---- boards ----

  static bool get canCreate => boards.value.length < kMaxBoards;

  /// Creates and activates a board; null when the limit is reached.
  static Board? create(String name) {
    if (!canCreate) return null;
    final n = _cleanName(name);
    var id = 'b${DateTime.now().millisecondsSinceEpoch}';
    while (byBoardId(id) != null) {
      id = '${id}x';
    }
    final b = Board(id: id, name: n.isEmpty ? 'Board ${boards.value.length + 1}' : n);
    boards.value = <Board>[...boards.value, b];
    activeId.value = b.id;
    _sync();
    return b;
  }

  static String _cleanName(String name) {
    var n = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (n.length > 24) n = n.substring(0, 24).trim();
    // Only the first letter is forced upper case; the rest stays as typed so "F&O" or "US stocks" survive.
    if (n.isNotEmpty) n = n[0].toUpperCase() + n.substring(1);
    return n;
  }

  static void rename(String id, String name) {
    final b = byBoardId(id);
    final n = _cleanName(name);
    if (b == null || n.isEmpty) return;
    b.name = n;
    _sync();
  }

  /// Deletes a board; the last board is emptied instead so there is always one.
  static void delete(String id) {
    final b = byBoardId(id);
    if (b == null) return;
    if (boards.value.length == 1) {
      b.items = <BoardItem>[];
    } else {
      boards.value = boards.value.where((x) => x.id != id).toList();
      if (activeId.value == id) activeId.value = boards.value.first.id;
    }
    _log('delete board $id', trace: true);
    _sync();
  }

  static void select(String id) {
    if (byBoardId(id) == null || activeId.value == id) return;
    activeId.value = id;
    _sync();
  }

  // ---- pins ----

  /// Whether [component] can take half the width on a phone.
  static bool halfOk(String component) => GenUiCatalog.halfOk(component);

  /// The boards that hold the surface [id].
  static List<Board> boardsOf(String id) => boards.value.where((b) => b.items.any((i) => i.id == id)).toList();

  /// True when the surface is on any board (the chat pin icon), or on [boardId] when given.
  static bool isPinned(String id, {String? boardId}) => boardId == null ? boardsOf(id).isNotEmpty : (byBoardId(boardId)?.items.any((i) => i.id == id) ?? false);

  static BoardItem? byId(String id, {String? boardId}) => (byBoardId(boardId ?? activeId.value) ?? active).items.cast<BoardItem?>().firstWhere((i) => i!.id == id, orElse: () => null);

  static void pin(BoardItem item, {String? boardId}) {
    final b = byBoardId(boardId ?? activeId.value) ?? active;
    if (b.items.any((i) => i.id == item.id)) return;
    b.items = <BoardItem>[...b.items, item];
    _sync();
  }

  static void unpin(String id, {String? boardId}) {
    final b = byBoardId(boardId ?? activeId.value) ?? active;
    b.items = b.items.where((i) => i.id != id).toList();
    _log('unpin $id', trace: true);
    _sync();
  }

  /// Pin on the active board, or unpin from every board that has it.
  static void toggle(BoardItem item) => isPinned(item.id) ? unpinEverywhere(item.id) : pin(item);

  static void unpinEverywhere(String id) {
    for (final b in boards.value) {
      b.items = b.items.where((i) => i.id != id).toList();
    }
    _log('unpin everywhere $id', trace: true);
    _sync();
  }

  /// Moves a pinned card from one board to another, keeping its size.
  static void moveTo(String id, String toBoardId, {String? fromBoardId}) {
    final from = byBoardId(fromBoardId ?? activeId.value) ?? active;
    final to = byBoardId(toBoardId);
    final it = from.items.cast<BoardItem?>().firstWhere((i) => i!.id == id, orElse: () => null);
    if (to == null || it == null || from.id == to.id) return;
    from.items = from.items.where((i) => i.id != id).toList();
    if (!to.items.any((i) => i.id == id)) to.items = <BoardItem>[...to.items, it];
    _sync();
  }

  static void setSize(String id, String size) {
    if (!kBoardSizes.contains(size)) return;
    final b = active;
    for (final i in b.items) {
      if (i.id == id) i.size = size;
    }
    b.items = <BoardItem>[...b.items];
    _sync();
  }

  static void move(String id, int delta) {
    final b = active;
    final list = <BoardItem>[...b.items];
    final from = list.indexWhere((i) => i.id == id);
    if (from < 0) return;
    final to = (from + delta).clamp(0, list.length - 1);
    final it = list.removeAt(from);
    list.insert(to, it);
    b.items = list;
    _sync();
  }

  /// Empties the active board.
  static void clear() {
    active.items = <BoardItem>[];
    _log('clear', trace: true);
    _sync();
  }

  /// "my portfolio", "the news": the active board's item whose title or question matches best.
  static BoardItem? find(String phrase) {
    const stop = <String>{
      'make',
      'show',
      'the',
      'my',
      'and',
      'with',
      'move',
      'bigger',
      'smaller',
      'full',
      'width',
      'half',
      'wide',
      'small',
      'large',
      'medium',
      'card',
      'widget',
      'to',
      'top',
      'first',
      'left',
      'right',
      'up',
      'down',
      'bottom',
      'last',
      'put',
      'set',
      'resize',
      'narrow',
      'wider',
      'larger',
      'please'
    };
    final words = phrase.toLowerCase().replaceAll(RegExp(r'[^a-z0-9& ]'), ' ').split(RegExp(r'\s+')).where((w) => w.length > 2 && !stop.contains(w)).toList();
    BoardItem? best;
    var score = 0;
    for (final it in items.value) {
      final hay = '${it.title} ${it.component} ${it.question}'.toLowerCase();
      final n = words.where((w) => hay.contains(w.replaceFirst(RegExp(r's$'), ''))).length;
      if (n > score) {
        best = it;
        score = n;
      }
    }
    return best;
  }
}

/// Tells a card which surface it is drawing so its frame can offer pin / size / move.
class CardScope extends InheritedWidget {
  const CardScope({super.key, required this.surfaceId, required this.component, required this.data, required this.question, this.onBoard = false, required super.child});
  final String surfaceId;
  final String component;
  final Map<String, dynamic> data;
  final String question;

  /// True when the card is drawn on the Board (then the frame shows size and move controls).
  final bool onBoard;

  static CardScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CardScope>();

  BoardItem item(String title) => BoardItem(id: surfaceId, title: title, component: component, data: data, question: question);

  @override
  bool updateShouldNotify(CardScope old) => surfaceId != old.surfaceId || onBoard != old.onBoard;
}
