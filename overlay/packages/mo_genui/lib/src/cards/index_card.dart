import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_explore_stock_tab/stock/data/stock_repository_impl.dart';
import 'package:mo_genui/src/cards/discover_cards.dart' show QuoteRow;
import 'package:mo_genui/src/entities/index_resolver.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_proto_gen/Explore/ExploreModels.pb.dart';
import 'package:trader_proto_gen/Quote/IndexQuoteModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteOverviewModels.pb.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
String _period(String p) {
  const m = <String, String>{'oneday': '1D', 'oneweek': '1W', 'onemonth': '1M', 'threemonth': '3M', 'sixmonth': '6M', 'oneyear': '1Y', 'twoyear': '2Y', 'threeyear': '3Y', 'fiveyear': '5Y', 'ytd': 'YTD'};
  return m[p.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')] ?? p;
}

String _pct(num v) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(2)}%';
Color _delta(BuildContext context, num v) => v < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal;

class _IndexData {
  _IndexData({required this.indexId, required this.exchangeCode, required this.name, this.detail, this.stocks = const <IndexStock>[]});
  final String indexId;
  final int exchangeCode;
  final String name;
  final IndexDetailV4? detail;
  final List<IndexStock> stocks;
}

/// One index, the way the classic index page shows it: live level, breadth,
/// returns, and the constituents (tap one to open its stock card).
class IndexCard extends StatefulWidget {
  const IndexCard({super.key, this.indexId, this.exchangeCode, this.name, this.view});
  /// Either the API id (from a tapped row) or the user's words ("Nifty 50").
  final String? indexId;
  final int? exchangeCode;
  final String? name;
  final String? view;
  static const List<String> views = <String>['overview', 'gainers', 'losers', 'all'];

  @override
  State<IndexCard> createState() => _IndexCardState();
}

class _IndexCardState extends State<IndexCard> {
  late String _view = IndexCard.views.contains(widget.view) ? widget.view! : 'overview';
  late Future<_IndexData> _future = _load();

  Future<_IndexData> _load() async {
    final ref = await resolveIndex(indexId: widget.indexId, exchangeCode: widget.exchangeCode, name: widget.name);
    final id = ref.indexId;
    final ex = ref.exchangeCode;
    final name = ref.name;
    final repo = MoGetQuoteRepositoryImpl();
    IndexDetailV4? detail;
    var stocks = const <IndexStock>[];
    try {
      detail = await repo.fetchIndexQuoteDetail(indexId: id, exchangeCode: ex);
    } catch (e) {
      debugPrint('GenUI index detail failed: $e');
    }
    try {
      stocks = (await repo.fetchIndexStocks(indexId: id)).entry;
    } catch (e) {
      debugPrint('GenUI index stocks failed: $e');
    }
    return _IndexData(indexId: id, exchangeCode: ex, name: name, detail: detail, stocks: stocks);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_IndexData>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: snap.data?.name ?? widget.name ?? 'Index',
          views: IndexCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = _load();
          }),
          child: snap.hasError
              ? Padding(padding: MOSpacing.paddingVertical8, child: Text('${snap.error}'.replaceFirst('Exception: ', ''), style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal)))
              : !snap.hasData
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, _IndexData d) {
    final det = d.detail;
    final sorted = <IndexStock>[...d.stocks]..sort((a, b) => b.perChange.compareTo(a.perChange));
    final up = sorted.where((s) => s.perChange > 0).length;
    final down = sorted.where((s) => s.perChange < 0).length;
    final rows = switch (_view) {
      'gainers' => sorted.where((s) => s.perChange > 0).take(10).toList(),
      'losers' => sorted.reversed.where((s) => s.perChange < 0).take(10).toList(),
      'all' => sorted,
      _ => <IndexStock>[...sorted.take(3), ...sorted.reversed.take(3)],
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      LivePrice.index(
        indexId: d.indexId,
        exchangeCode: d.exchangeCode,
        builder: (context, t) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
          Text(t == null || t.ltp == 0 ? '—' : _money(t.ltp), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextNeutralStrong)),
          MOSpacing.horizontalSpace8,
          if (t != null && t.ltp != 0)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('${t.change < 0 ? '−' : '+'}${_money(t.change.abs())} (${_pct(t.perChange)})', style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, t.change)))),
        ]),
      ),
      MOSpacing.verticalSpace8,
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
        _kv(context, 'Advancing', '${(det?.advanceCount ?? 0) > 0 ? det!.advanceCount : up}', color: context.surfaceTextPositiveNormal),
        _kv(context, 'Declining', '${(det?.declineCount ?? 0) > 0 ? det!.declineCount : down}', color: context.surfaceTextNegativeNormal),
        if ((det?.pcr ?? 0) != 0) _kv(context, 'PCR', det!.pcr.toStringAsFixed(2)),
        if ((det?.lotSize ?? 0) != 0) _kv(context, 'F&O lot', '${det!.lotSize}'),
        for (final r in det?.returns.entry ?? const <ReturnEntry>[])
          if (r.value != 0) _kv(context, _period(r.period), _pct(r.value / 100), color: _delta(context, r.value)),
      ]),
      if (up + down > 0) ...<Widget>[
        MOSpacing.verticalSpace8,
        ClipRRect(
          borderRadius: BorderRadius.circular(MOSpacing.spacing4),
          child: SizedBox(height: 8, child: Row(children: <Widget>[
            Expanded(flex: up == 0 ? 1 : up, child: Container(color: up == 0 ? context.surfaceBackgroundNeutralFaded : context.surfaceTextPositiveNormal)),
            Expanded(flex: down == 0 ? 1 : down, child: Container(color: down == 0 ? context.surfaceBackgroundNeutralFaded : context.surfaceTextNegativeNormal)),
          ])),
        ),
      ],
      MOSpacing.verticalSpace12,
      if (d.stocks.isEmpty)
        Text('Constituent list is not available for this index on UAT.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))
      else ...<Widget>[
        Text(_view == 'overview' ? 'Top movers in the index · ${d.stocks.length} stocks' : '${rows.length} of ${d.stocks.length} stocks', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final s in rows) QuoteRow(id: s.scrip, symbol: s.tradeSymbol, name: s.stockInfo.fullName, fallbackLtp: s.ltp, fallbackPct: s.perChange),
        Text('Tap a stock to open it.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ],
      if ((det?.news.news.length ?? 0) > 0) ...<Widget>[
        MOSpacing.verticalSpace8,
        Text('News', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final n in det!.news.news.take(3)) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
      ],
    ]);
  }

  Widget _kv(BuildContext context, String k, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(k, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        Text(v, style: MOTypography.bodySmallSemibold.copyWith(color: color ?? context.surfaceTextNeutralStrong)),
      ]);
}
