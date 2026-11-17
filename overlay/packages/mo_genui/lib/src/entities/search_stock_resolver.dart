import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/entities/stock_resolver.dart';
import 'package:trader_proto_gen/SearchRevamp/SearchModels.pb.dart';
import 'package:trader_search/data/search_repository_impl.dart';

/// Resolves stock names through the app's real search endpoint
/// (`v2/api/Search?query=`), exactly what the search bar calls.
class SearchStockResolver implements StockResolver {
  SearchStockResolver({SearchRepositoryImpl? repository}) : _repo = repository ?? SearchRepositoryImpl();

  final SearchRepositoryImpl _repo;
  final Map<String, List<ScripRef>> _cache = <String, List<ScripRef>>{};

  @override
  Future<ScripRef?> resolve(String query) async {
    final list = await suggest(query, limit: 10);
    if (list.isEmpty) return null;
    final q = _norm(query);
    // 1. exact symbol, 2. exact name, 3. first NSE row, 4. first row.
    return list.firstWhere((s) => _norm(s.symbol) == q,
        orElse: () => list.firstWhere((s) => _norm(s.name) == q,
            orElse: () => list.firstWhere((s) => s.exchange == 'NSE', orElse: () => list.first)));
  }

  @override
  Future<List<ScripRef>> suggest(String query, {int limit = 5}) async {
    final q = query.trim();
    if (q.isEmpty) return const <ScripRef>[];
    final key = q.toLowerCase();
    if (!_cache.containsKey(key)) {
      try {
        final SearchResponse res = await _repo.getSearchSchemeNew(q, 0, true, const <int>[], CancelToken());
        _cache[key] = res.stock.map(_toRef).toList(growable: false);
      } catch (e) {
        debugPrint('GenUI search failed for "$q": $e');
        return const <ScripRef>[];
      }
    }
    return _cache[key]!.take(limit).toList(growable: false);
  }

  static ScripRef _toRef(IndianStocks s) => ScripRef(
        scripCode: s.id.scripCode.toString(),
        exchange: s.id.exchange.name,
        exchangeCode: s.id.exchange.value,
        symbol: s.tradeSymbol,
        name: s.description,
        id: s.id,
      );

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
