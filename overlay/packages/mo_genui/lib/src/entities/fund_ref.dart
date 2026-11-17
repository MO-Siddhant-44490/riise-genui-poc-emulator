import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mo_mutual_funds/mf_finder/data/mf_finder_respository_impl.dart';
import 'package:trader_search/data/search_repository_impl.dart';

/// A mutual fund scheme as resolved from the user's words. The ISIN is the key
/// every MF API uses.
class FundRef {
  const FundRef({required this.isin, required this.name, this.category = '', this.subCategory = '', this.nav = 0, this.rating = 0, this.return3Y = 0, this.logo = ''});
  final String isin;
  final String name;
  final String category;
  final String subCategory;
  final double nav;
  final int rating;
  final double return3Y;
  final String logo;

  String get shortName => name.replaceAll(RegExp(r'\s*-\s*(Direct|Regular).*$', caseSensitive: false), '').trim();

  @override
  String toString() => '$name ($isin)';
}

/// Resolves a fund name through the app's global search (the same call the
/// search bar makes, reading its mutual-fund section), with the AMC scheme
/// list as a fallback. Never guesses: returns null when nothing matches.
class FundResolver {
  FundResolver._();
  static final FundResolver instance = FundResolver._();
  final Map<String, FundRef?> _cache = <String, FundRef?>{};
  List<FundRef>? _all;

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<List<FundRef>> suggest(String query, {int limit = 6}) async {
    final q = query.trim();
    if (q.length < 2) return const <FundRef>[];
    try {
      final res = await SearchRepositoryImpl().getSearchSchemeNew(q, 0, true, <int>[], CancelToken());
      final list = res.mf
          .where((m) => m.isin.isNotEmpty)
          .map((m) => FundRef(isin: m.isin, name: m.name, category: m.category, subCategory: m.subCategory, nav: m.currentNav.toInt() / 100, rating: m.rating, return3Y: m.return3Year / 100, logo: m.logoUrl))
          .toList();
      if (list.isNotEmpty) return list.take(limit).toList();
    } catch (e) {
      debugPrint('FundResolver search failed: $e');
    }
    // Fallback: the full AMC scheme list, matched by words.
    final all = await _allSchemes();
    final words = _norm(q).split(' ').where((w) => w.length > 2).toList();
    final scored = <MapEntry<FundRef, int>>[];
    for (final f in all) {
      final n = _norm(f.name);
      final hits = words.where(n.contains).length;
      if (hits > 0) scored.add(MapEntry(f, hits * 10 - (n.contains('direct') ? 0 : 1)));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  Future<FundRef?> resolve(String query) async {
    final key = _norm(query);
    if (_cache.containsKey(key)) return _cache[key];
    final list = await suggest(query, limit: 8);
    FundRef? pick;
    if (list.isNotEmpty) {
      // Prefer an exact-ish name match, then the first search result.
      pick = list.cast<FundRef?>().firstWhere((f) => _norm(f!.name).startsWith(key) || _norm(f.shortName) == key, orElse: () => list.first);
    }
    _cache[key] = pick;
    return pick;
  }

  Future<List<FundRef>> _allSchemes() async {
    if (_all != null) return _all!;
    try {
      final r = await MFFinderRepositoryImpl().fetchFinderData('0');
      _all = <FundRef>[
        for (final amc in r.data?.entry ?? const [])
          for (final s in amc.schemes ?? const [])
            FundRef(isin: s.isinCode ?? '', name: s.name ?? '', category: s.category ?? '', subCategory: s.subCategory ?? '', rating: int.tryParse('${s.ratings ?? ''}') ?? 0, return3Y: (s.ret3Y ?? 0).toDouble(), logo: amc.amcLogo ?? ''),
      ].where((f) => f.isin.isNotEmpty && f.name.isNotEmpty).toList();
    } catch (e) {
      debugPrint('FundResolver finder failed: $e');
      _all = const <FundRef>[];
    }
    return _all!;
  }
}
