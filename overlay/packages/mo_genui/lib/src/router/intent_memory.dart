import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mo_genui/src/router/intent_seeds.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One card of a plan: a catalog action with params and a board size.
class PlanCard {
  const PlanCard({required this.action, this.params = const <String, dynamic>{}, this.size = 'M'});
  final String action;
  final Map<String, dynamic> params;
  final String size;

  Map<String, dynamic> toJson() => <String, dynamic>{'action': action, 'params': params, 'size': size};
  static PlanCard fromJson(Map<String, dynamic> j) =>
      PlanCard(action: '${j['action']}', params: Map<String, dynamic>.from(j['params'] as Map? ?? const <String, dynamic>{}), size: j['size'] == 'S' ? 'S' : 'M');
}

/// What the app learned about one intent: how people phrase it and what to render.
class IntentEntry {
  IntentEntry({required this.intent, required this.examples, this.action = '', this.params = const <String, dynamic>{}, this.plan, this.title = '', this.summary = '', this.source = 'model', this.uses = 0});
  final String intent;
  final List<String> examples;
  final String action;
  final Map<String, dynamic> params;
  final List<PlanCard>? plan;
  final String title;
  final String summary;

  /// 'classic' (seeded from the classic app's flows) or 'model' (learned from a model answer).
  final String source;
  int uses;

  bool get isPlan => plan != null && plan!.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'intent': intent,
        'examples': examples,
        'action': action,
        'params': params,
        if (plan != null) 'plan': plan!.map((c) => c.toJson()).toList(),
        'title': title,
        'summary': summary,
        'source': source,
        'uses': uses,
      };

  static IntentEntry fromJson(Map<String, dynamic> j) => IntentEntry(
        intent: '${j['intent']}',
        examples: <String>[for (final e in j['examples'] as List? ?? const <dynamic>[]) '$e'],
        action: '${j['action'] ?? ''}',
        params: Map<String, dynamic>.from(j['params'] as Map? ?? const <String, dynamic>{}),
        plan: j['plan'] is List ? <PlanCard>[for (final c in j['plan'] as List) PlanCard.fromJson(Map<String, dynamic>.from(c as Map))] : null,
        title: '${j['title'] ?? ''}',
        summary: '${j['summary'] ?? ''}',
        source: '${j['source'] ?? 'model'}',
        uses: (j['uses'] as num?)?.toInt() ?? 0,
      );
}

/// On-device memory of intents: the classic flows are seeded on first launch, and every
/// model answer with an intent is remembered, so a later question with the same intent
/// renders instantly without a model call. Nothing leaves the device.
class IntentMemory {
  IntentMemory._();
  static const String _key = 'genui_intents_v1';
  static final ValueNotifier<List<IntentEntry>> entries = ValueNotifier<List<IntentEntry>>(<IntentEntry>[]);
  static bool _loaded = false;

  static const Set<String> _stop = <String>{'the', 'a', 'an', 'me', 'please', 'pls', 'plz', 'can', 'could', 'you', 'i', 'want', 'to', 'of', 'kindly', 'show', 'open', 'display', 'see', 'give', 'get', 'dikhao', 'batao', 'mujhe', 'mera', 'meri', 'mere'};

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null && raw.isNotEmpty) {
        entries.value = <IntentEntry>[for (final j in jsonDecode(raw) as List) IntentEntry.fromJson(Map<String, dynamic>.from(j as Map))];
      }
    } catch (e) {
      debugPrint('GenUI intents load failed: $e');
    }
    if (entries.value.isEmpty) {
      seedClassic();
    }
  }

  /// (Re)loads the classic flows, keeping anything the model taught us.
  static void seedClassic() {
    final learned = entries.value.where((e) => e.source != 'classic').toList();
    final seeds = <IntentEntry>[
      for (final s in kIntentSeeds)
        IntentEntry(
          intent: '${s['intent']}',
          examples: <String>[for (final e in s['examples'] as List) '$e'],
          action: '${s['action'] ?? ''}',
          params: Map<String, dynamic>.from(s['params'] as Map? ?? const <String, dynamic>{}),
          plan: s['plan'] is List ? <PlanCard>[for (final c in s['plan'] as List) PlanCard.fromJson(Map<String, dynamic>.from(c as Map))] : null,
          title: '${s['title'] ?? ''}',
          summary: '${s['summary'] ?? ''}',
          source: 'classic',
        ),
    ];
    entries.value = <IntentEntry>[...seeds, ...learned];
    _save();
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(entries.value.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('GenUI intents save failed: $e');
    }
  }

  static List<String> normalize(String q) {
    final words = q.toLowerCase().replaceAll(RegExp(r"[^a-z0-9&ऀ-ॿ ]"), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty && !_stop.contains(w)).toList();
    return words;
  }

  static IntentEntry? byIntent(String intent) => entries.value.cast<IntentEntry?>().firstWhere((e) => e!.intent == intent, orElse: () => null);

  static List<String> get intents => entries.value.map((e) => e.intent).toList();

  /// The entry whose example phrasing matches the question: an exact normalized match, or a
  /// near-identical one (token overlap of 0.8 or more, same numbers). Anything looser goes to
  /// the model, so "bank nifty option chain" never hits "nifty option chain".
  static IntentEntry? match(String q) {
    final words = normalize(q);
    if (words.isEmpty) return null;
    final set = words.toSet();
    final joined = words.join(' ');
    IntentEntry? best;
    var bestScore = 0.0;
    for (final e in entries.value) {
      for (final ex in e.examples) {
        final ew = normalize(ex);
        if (ew.isEmpty) continue;
        if (ew.join(' ') == joined) return e;
        final es = ew.toSet();
        if (!setEquals(_numbers(set), _numbers(es))) continue;
        final score = set.intersection(es).length / set.union(es).length;
        if (score > bestScore) {
          bestScore = score;
          best = e;
        }
      }
    }
    return bestScore >= 0.8 ? best : null;
  }

  static Set<String> _numbers(Set<String> w) => w.where((x) => RegExp(r'^\d').hasMatch(x)).toSet();

  /// Remember how the user phrased [question] for [entry] (new or existing).
  static Future<void> remember(String question, IntentEntry entry) async {
    final q = question.trim();
    final list = <IntentEntry>[...entries.value];
    final i = list.indexWhere((e) => e.intent == entry.intent);
    if (i >= 0) {
      final ex = list[i].examples;
      if (!ex.any((e) => e.toLowerCase() == q.toLowerCase())) {
        ex.add(q);
        if (ex.length > 10) ex.removeAt(0);
      }
      list[i].uses++;
    } else {
      if (!entry.examples.any((e) => e.toLowerCase() == q.toLowerCase())) entry.examples.add(q);
      entry.uses = 1;
      list.add(entry);
    }
    entries.value = list;
    await _save();
  }

  static Future<void> touch(IntentEntry e) async {
    e.uses++;
    entries.value = <IntentEntry>[...entries.value];
    await _save();
  }

  /// Learned entries as JSON, for moving the memory between devices (no server in the POC).
  static String exportLearned() => jsonEncode(entries.value.where((e) => e.source != 'classic').map((e) => e.toJson()).toList());

  /// Merges exported entries: new intents are added, known ones gain the phrasings. Returns how many were taken.
  static Future<int> importLearned(String raw) async {
    final list = <IntentEntry>[...entries.value];
    var taken = 0;
    for (final j in jsonDecode(raw) as List) {
      final e = IntentEntry.fromJson(Map<String, dynamic>.from(j as Map));
      if (e.intent.isEmpty || (e.action.isEmpty && !e.isPlan)) continue;
      final i = list.indexWhere((x) => x.intent == e.intent);
      if (i < 0) {
        list.add(e);
        taken++;
      } else {
        for (final ex in e.examples) {
          if (!list[i].examples.any((x) => x.toLowerCase() == ex.toLowerCase())) {
            list[i].examples.add(ex);
            taken++;
          }
        }
      }
    }
    entries.value = list;
    await _save();
    return taken;
  }

  static Future<void> forgetLearned() async {
    entries.value = entries.value.where((e) => e.source == 'classic').toList();
    await _save();
  }

  static Future<void> forget(String intent) async {
    entries.value = entries.value.where((e) => e.intent != intent).toList();
    await _save();
  }
}
