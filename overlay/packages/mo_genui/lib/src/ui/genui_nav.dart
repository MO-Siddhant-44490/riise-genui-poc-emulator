import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';

/// Tap-through for every list in the AI view: a stock, fund or index row opens
/// its own card as a new turn, the way the classic app opens a detail screen.
/// The screen registers the handlers; cards only call the static methods.
class GenUiNav {
  GenUiNav._();

  static void Function(ScripRef ref, {String? view})? onStock;
  static void Function(FundRef ref)? onFund;
  static void Function(String indexId, int exchangeCode, String name)? onIndex;
  static void Function(String question)? onAsk;

  static bool get ready => onStock != null;

  static void openStock(ScripRef ref, {String? view}) => onStock?.call(ref, view: view);
  static void openFund(FundRef ref) => onFund?.call(ref);
  static void openIndex(String indexId, int exchangeCode, String name) => onIndex?.call(indexId, exchangeCode, name);
  static void ask(String question) => onAsk?.call(question);

  static ScripRef refOf(ScripId id, String symbol, [String name = '']) => ScripRef(
        scripCode: '${id.scripCode}',
        exchange: id.exchange.name,
        exchangeCode: id.exchange.value,
        id: id,
        symbol: symbol,
        name: name.isEmpty ? symbol : name,
      );
}
