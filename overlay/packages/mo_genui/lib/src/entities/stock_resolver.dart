import 'package:mo_genui/src/entities/scrip_ref.dart';

/// Turns "hdfc bank", "HDFCBANK" or "एचडीएफसी बैंक" into a [ScripRef] using the
/// app's real search endpoint. Returns null when nothing matches well enough;
/// callers must then ask the user, never guess.
abstract class StockResolver {
  Future<ScripRef?> resolve(String query);

  /// Up to [limit] candidates, for a "did you mean" chip row.
  Future<List<ScripRef>> suggest(String query, {int limit = 5});

  /// Injection point; the host wires the real implementation at startup.
  static StockResolver? instance;
}
