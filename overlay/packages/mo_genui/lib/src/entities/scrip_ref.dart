import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';

/// A stock identified the way RIISE APIs identify it. Never produced by the
/// LLM: always resolved by our code through the app's own search.
class ScripRef {
  const ScripRef({
    required this.scripCode,
    required this.exchange,
    required this.symbol,
    required this.name,
    this.exchangeCode,
    this.id,
  });

  final String scripCode;

  /// `NSE` or `BSE` (as the search API returns it).
  final String exchange;

  /// The proto enum value, used by quote and broadcast calls.
  final int? exchangeCode;

  /// The proto id, when it came from the search API.
  final ScripId? id;
  final String symbol;
  final String name;

  ScripId get scripId => id ?? (ScripId()..scripCode = int.tryParse(scripCode) ?? 0);

  Map<String, dynamic> toJson() => <String, dynamic>{'scripCode': scripCode, 'exchange': exchange, 'exchangeCode': exchangeCode, 'symbol': symbol, 'name': name};

  @override
  String toString() => '$symbol ($exchange $scripCode)';
}
