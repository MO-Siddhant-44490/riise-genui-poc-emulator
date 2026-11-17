import 'package:mo_explore_stock_tab/stock/data/stock_repository_impl.dart';
import 'package:trader_proto_gen/Explore/ExploreModels.pb.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';

/// An index the quote APIs understand.
class IndexRef {
  const IndexRef({required this.indexId, required this.exchangeCode, required this.name});
  final String indexId;
  final int exchangeCode;
  final String name;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Resolves the user's words ("Nifty", "bank nifty", "Sensex") against the indices the Markets
/// dashboard lists, with a few aliases the dashboard may not carry. Throws when nothing matches.
Future<IndexRef> resolveIndex({String? indexId, int? exchangeCode, String? name}) async {
  if ((indexId ?? '').isNotEmpty && exchangeCode != null) return IndexRef(indexId: indexId!, exchangeCode: exchangeCode, name: name ?? indexId);
  final list = await StockRepositoryImpl().getStockDashboardNewWithAWS(<String>['Indices'], false, (_) {});
  final indices = (list.first as StockDashboardResponseV41).indices.index;
  final want = _norm(name ?? indexId ?? 'nifty 50');
  UserSelectedIndexV2? hit;
  for (final i in indices) {
    if (<String>[i.title, i.index.indexName, i.index.indexId, i.index.tradingSymbol].map(_norm).contains(want)) {
      hit = i;
      break;
    }
  }
  const alias = <String, String>{'nifty': 'NIFTY 50', 'nifty50': 'NIFTY 50', 'banknifty': 'NIFTY BANK', 'niftybank': 'NIFTY BANK', 'finnifty': 'NIFTY FIN SERVICE', 'sensex': 'SENSEX', 'midcapnifty': 'NIFTY MID SELECT', 'market': 'NIFTY 50', 'index': 'NIFTY 50', 'themarket': 'NIFTY 50'};
  // A bare "Nifty" means Nifty 50, never the first index whose name contains the word.
  if (hit == null && alias.containsKey(want)) {
    final a = alias[want]!;
    for (final i in indices) {
      if (<String>[i.title, i.index.indexName, i.index.indexId].map(_norm).contains(_norm(a))) {
        hit = i;
        break;
      }
    }
    if (hit == null) return IndexRef(indexId: a, exchangeCode: a == 'SENSEX' ? Exchange.BSE.value : Exchange.NSE.value, name: a);
  }
  hit ??= indices.cast<UserSelectedIndexV2?>().firstWhere((i) => <String>[i!.title, i.index.indexName, i.index.indexId].any((n) => _norm(n).contains(want) || want.contains(_norm(n))), orElse: () => null);
  if (hit != null) {
    return IndexRef(
      indexId: hit.index.indexId.isNotEmpty ? hit.index.indexId : hit.index.index.indexCode.toString(),
      exchangeCode: hit.index.index.exchange.value,
      name: hit.title.isNotEmpty ? hit.title : hit.index.indexName,
    );
  }
  final a = alias[want];
  if (a == null) throw Exception('Could not find an index called "${name ?? indexId}".');
  return IndexRef(indexId: a, exchangeCode: a == 'SENSEX' ? Exchange.BSE.value : Exchange.NSE.value, name: a);
}
