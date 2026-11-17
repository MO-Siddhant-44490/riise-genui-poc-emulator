import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mosl_broadcaster/core/broadcast_helper.dart';
import 'package:mosl_broadcaster/models/request_models.dart';
import 'package:mosl_broadcaster/models/response_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One alert the user set from the AI view. Price and smart rules are evaluated on the device
/// against the live feed while the app is open; results and report subscriptions are checked
/// when their cards load. Nothing here reaches a server: the classic alert page is offered
/// alongside for server-side alerts, and email delivery needs a backend the POC does not have.
class AlertRule {
  AlertRule({
    required this.id,
    required this.kind,
    this.scrip,
    this.scrips = const <ScripRef>[],
    this.group = '',
    this.condition = '',
    this.price,
    this.pct,
    this.action = '',
    this.qty,
    this.email = false,
    DateTime? createdAt,
    this.triggeredAt,
    this.triggeredSymbol = '',
    this.lastPrice,
    this.note = '',
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;

  /// 'price' | 'smart' | 'results' | 'report'
  final String kind;
  final ScripRef? scrip;
  final List<ScripRef> scrips;
  final String group;

  /// price: 'above' | 'below'. smart: 'falls' | 'rises' (by [pct] in a day).
  final String condition;
  final double? price;
  final double? pct;

  /// 'buy' | 'sell' when a prepared order should open on trigger.
  final String action;
  final int? qty;
  final bool email;
  final DateTime createdAt;
  DateTime? triggeredAt;
  String triggeredSymbol;
  double? lastPrice;
  String note;

  bool get isTriggered => triggeredAt != null;
  bool get live => kind == 'price' || kind == 'smart';

  /// Every scrip this rule watches.
  List<ScripRef> get watched => <ScripRef>[if (scrip != null) scrip!, ...scrips];

  String get title => switch (kind) {
        'price' => '${scrip?.symbol ?? ''} ${condition == 'above' ? 'crosses' : 'falls below'} ₹${_n(price)}',
        'smart' => '${group.isNotEmpty ? group : '${scrips.length} stocks'}: any ${condition == 'rises' ? 'rises' : 'falls'} ${_n(pct)}% in a day',
        'results' => '${scrip?.symbol ?? ''} posts results${email ? ' (email)' : ''}',
        'report' => 'New research on ${watched.map((s) => s.symbol).join(', ')}${email ? ' (email)' : ''}',
        _ => kind,
      };

  static String _n(num? v) => v == null ? '—' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        if (scrip != null) 'scrip': scrip!.toJson(),
        'scrips': scrips.map((s) => s.toJson()).toList(),
        'group': group,
        'condition': condition,
        'price': price,
        'pct': pct,
        'action': action,
        'qty': qty,
        'email': email,
        'createdAt': createdAt.toIso8601String(),
        'triggeredAt': triggeredAt?.toIso8601String(),
        'triggeredSymbol': triggeredSymbol,
        'lastPrice': lastPrice,
        'note': note,
      };

  static ScripRef _ref(Map m) => ScripRef(scripCode: '${m['scripCode']}', exchange: '${m['exchange']}', exchangeCode: m['exchangeCode'] as int?, symbol: '${m['symbol']}', name: '${m['name']}');

  static AlertRule fromJson(Map<String, dynamic> j) => AlertRule(
        id: '${j['id']}',
        kind: '${j['kind']}',
        scrip: j['scrip'] is Map ? _ref(j['scrip'] as Map) : null,
        scrips: <ScripRef>[for (final s in j['scrips'] as List? ?? const <dynamic>[]) _ref(s as Map)],
        group: '${j['group'] ?? ''}',
        condition: '${j['condition'] ?? ''}',
        price: (j['price'] as num?)?.toDouble(),
        pct: (j['pct'] as num?)?.toDouble(),
        action: '${j['action'] ?? ''}',
        qty: (j['qty'] as num?)?.toInt(),
        email: j['email'] == true,
        createdAt: DateTime.tryParse('${j['createdAt']}'),
        triggeredAt: j['triggeredAt'] == null ? null : DateTime.tryParse('${j['triggeredAt']}'),
        triggeredSymbol: '${j['triggeredSymbol'] ?? ''}',
        lastPrice: (j['lastPrice'] as num?)?.toDouble(),
        note: '${j['note'] ?? ''}',
      );
}

/// The alert rules, kept on the device.
class AlertStore {
  AlertStore._();
  static const String _key = 'genui_alerts_v1';
  static final ValueNotifier<List<AlertRule>> rules = ValueNotifier<List<AlertRule>>(<AlertRule>[]);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null && raw.isNotEmpty) {
        rules.value = <AlertRule>[for (final j in jsonDecode(raw) as List) AlertRule.fromJson(Map<String, dynamic>.from(j as Map))];
      }
    } catch (e) {
      debugPrint('GenUI alerts load failed: $e');
    }
  }

  static Future<void> save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(rules.value.map((r) => r.toJson()).toList()));
    } catch (e) {
      debugPrint('GenUI alerts save failed: $e');
    }
  }

  /// Adds [rule] unless an equal one exists; returns the rule that is now in the store.
  static AlertRule upsert(AlertRule rule) {
    final same = rules.value.cast<AlertRule?>().firstWhere(
          (r) => r!.kind == rule.kind && r.condition == rule.condition && r.price == rule.price && r.pct == rule.pct && r.group == rule.group && r.watched.map((s) => s.scripCode).join(',') == rule.watched.map((s) => s.scripCode).join(','),
          orElse: () => null,
        );
    if (same != null) return same;
    rules.value = <AlertRule>[...rules.value, rule];
    save();
    AlertEngine.sync();
    return rule;
  }

  static void remove(String id) {
    rules.value = rules.value.where((r) => r.id != id).toList();
    save();
    AlertEngine.sync();
  }

  static void clear() {
    rules.value = <AlertRule>[];
    save();
    AlertEngine.sync();
  }

  static void touch() {
    rules.value = <AlertRule>[...rules.value];
    save();
  }

  static AlertRule? byId(String id) => rules.value.cast<AlertRule?>().firstWhere((r) => r!.id == id, orElse: () => null);
}

/// Watches the live feed for price and smart rules while the AI view is open.
class AlertEngine {
  AlertEngine._();
  static final Map<String, StreamSubscription<BroadcastResponse2>> _subs = <String, StreamSubscription<BroadcastResponse2>>{};

  /// The rule that just fired; the screen shows it as a banner.
  static final ValueNotifier<AlertRule?> fired = ValueNotifier<AlertRule?>(null);
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    AlertStore.load().then((_) => sync());
  }

  static void stop() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    _started = false;
  }

  static String _k(AlertRule r, ScripRef s) => '${r.id}/${s.scripCode}';

  /// (Re)subscribes so exactly the live, untriggered rules are watched.
  static void sync() {
    if (!_started) return;
    final want = <String, (AlertRule, ScripRef)>{};
    for (final r in AlertStore.rules.value) {
      if (!r.live || r.isTriggered) continue;
      for (final s in r.watched) {
        if (s.scripId.scripCode != 0) want[_k(r, s)] = (r, s);
      }
    }
    for (final k in _subs.keys.toList()) {
      if (!want.containsKey(k)) {
        _subs.remove(k)!.cancel();
      }
    }
    final symbols = <BroadcastSymbol>[];
    want.forEach((k, v) {
      if (_subs.containsKey(k)) return;
      final sym = BroadcastSymbol.forScrip(scripCode: v.$2.scripId.scripCode, exchangeCode: v.$2.scripId.exchange.value);
      symbols.add(sym);
      _subs[k] = BroadCastHelper.instance.onTickReceived(sym).listen((t) => _evaluate(v.$1, v.$2, t));
    });
    if (symbols.isNotEmpty) subscribeLive(symbols);
  }

  static void _evaluate(AlertRule r, ScripRef s, BroadcastResponse2 t) {
    if (r.isTriggered || t.ltp == 0) return;
    r.lastPrice = t.ltp;
    var hit = false;
    if (r.kind == 'price' && r.price != null) {
      hit = r.condition == 'below' ? t.ltp <= r.price! : t.ltp >= r.price!;
    } else if (r.kind == 'smart' && r.pct != null) {
      hit = r.condition == 'rises' ? t.perChange >= r.pct! : t.perChange <= -r.pct!;
    }
    if (!hit) return;
    r.triggeredAt = DateTime.now();
    r.triggeredSymbol = s.symbol;
    r.note = r.kind == 'price' ? '${s.symbol} at ₹${t.ltp.toStringAsFixed(2)}' : '${s.symbol} ${t.perChange < 0 ? '' : '+'}${t.perChange.toStringAsFixed(2)}% today at ₹${t.ltp.toStringAsFixed(2)}';
    debugPrint('GenUI alert fired: ${r.title} → ${r.note}');
    AlertStore.touch();
    fired.value = r;
    sync();
  }

  /// Lets a card report a non-live trigger (results headline, new report).
  static void fire(AlertRule r, String note) {
    if (r.isTriggered) return;
    r.triggeredAt = DateTime.now();
    r.note = note;
    AlertStore.touch();
    fired.value = r;
  }
}
