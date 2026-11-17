import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mo_genui/src/cards/discover_cards.dart' show QuoteRow;
import 'package:mo_genui/src/cards/stock_chart_view.dart';
import 'package:trader_proto_gen/News/NewsResponseModels.pb.dart';
import 'package:trader_proto_gen/Quote/Financials.pb.dart';
import 'package:trader_proto_gen/Quote/PeerComparison.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteFundamentalModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteOverviewModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteTechnicalModels.pb.dart';

/// One stock, many views. Live price comes from the broadcaster; everything
/// else from the Get Quote repository the classic quote screen uses.
class StockCard extends StatefulWidget {
  const StockCard({super.key, required this.ref, this.view});

  final ScripRef ref;
  final String? view;

  static const List<String> views = <String>['snapshot', 'chart', 'returns', 'fundamentals', 'financials', 'technicals', 'peers', 'similar', 'news'];

  @override
  State<StockCard> createState() => _StockCardState();
}

class _StockCardState extends State<StockCard> {
  final MoGetQuoteRepositoryImpl _repo = MoGetQuoteRepositoryImpl();
  late String _view = StockCard.views.contains(widget.view) ? widget.view! : 'snapshot';
  final Map<String, Future<dynamic>> _futures = <String, Future<dynamic>>{};

  String get _symbol => widget.ref.symbol.replaceAll('&', '%26');

  Future<dynamic> _load(String view) => _futures.putIfAbsent(view, () {
        switch (view) {
          case 'returns':
            return _repo.fetchQuoteOverviewData(symbol: _symbol, sections: <String>['Returns']);
          case 'fundamentals':
            return _repo.fetchQuoteFundamentalData(symbol: _symbol, sections: <String>['Ratios']);
          case 'technicals':
            return _repo.fetchQuoteTechnicalData(symbol: _symbol, sections: <String>['MovingAverage', 'ResistanceAndSupport']);
          case 'news':
            return _repo.fetchQuoteOverviewData(symbol: _symbol, sections: <String>['News']);
          case 'financials':
            return _repo.fetchFinancialDetails(symbol: _symbol, type: _statement);
          case 'peers':
            return _repo.fetchPeerComparisonDetails(symbol: _symbol);
          case 'similar':
            return _repo.fetchQuoteOverviewData(symbol: _symbol, sections: <String>['SimilarStocks']);
          default:
            return Future<dynamic>.value(null);
        }
      });

  // Same `type` strings the classic financials screens send.
  String _statement = 'ProfitLoss';
  static const Map<String, String> statements = <String, String>{'ProfitLoss': 'P&L', 'BalanceSheets': 'Balance sheet', 'CashFlow': 'Cash flow', 'QuarterlyResults': 'Quarterly'};

  void _refresh() => setState(() => _futures.remove(_view));

  @override
  Widget build(BuildContext context) {
    final r = widget.ref;
    return CardFrame(
      live: true,
      title: r.name.isEmpty ? r.symbol : r.name,
      subtitle: '${r.symbol} · ${r.exchange}',
      views: StockCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: _view == 'snapshot' || _view == 'chart' ? null : _refresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _LiveHeader(ref: r, compact: _view != 'snapshot'),
          if (_view == 'chart') ...<Widget>[
            MOSpacing.verticalSpace8,
            StockChartView(key: ValueKey<String>('chart-${r.scripId.scripCode}'), scrip: r.scripId),
          ],
          if (_view != 'snapshot' && _view != 'chart') ...<Widget>[
            MOSpacing.verticalSpace8,
            FutureBuilder<dynamic>(
              future: _load(_view),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
                if (snap.hasError || snap.data == null) {
                  return CardError(title: "Couldn't load this section.", message: '${snap.error ?? 'No data'}', onRetry: _refresh);
                }
                switch (_view) {
                  case 'returns':
                    return _ReturnsChart(returns: (snap.data as QuoteOverviewResponse).returns);
                  case 'fundamentals':
                    return _Ratios(ratios: (snap.data as FundamentalResponseV2).ratios);
                  case 'technicals':
                    return _Technicals(data: snap.data as QuoteTechnicalResponse);
                  case 'news':
                    return _News(news: (snap.data as QuoteOverviewResponse).news.news);
                  case 'financials':
                    return _Financials(data: snap.data as FinancialsResponse, statement: _statement, onStatement: (t) => setState(() { _statement = t; _futures.remove('financials'); }));
                  case 'peers':
                    return _Peers(data: snap.data as PeerComparisonResponse);
                  case 'similar':
                    final entries = (snap.data as QuoteOverviewResponse).similarStocks.entry;
                    if (entries.isEmpty) return Text('No similar stocks listed.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
                    return Column(children: <Widget>[
                      for (final e in entries.take(8))
                        QuoteRow(id: e.id, symbol: e.tradeSymbol, name: '${e.stockInfo.fullName}${e.pe == 0 ? '' : ' · P/E ${e.pe.toStringAsFixed(1)}'}', trailing: e.oneYearReturn == 0 ? null : '1Y ${signed(e.oneYearReturn)}%'),
                    ]);
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _LiveHeader extends StatelessWidget {
  const _LiveHeader({required this.ref, required this.compact});
  final ScripRef ref;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LivePrice.scrip(
      scrip: ref.scripId,
      builder: (context, t) {
        final ltp = t?.ltp ?? 0;
        final ch = t?.change ?? 0;
        final pc = t?.perChange ?? 0;
        final price = Text(ltp == 0 ? '—' : '₹${_money(ltp)}',
            style: (compact ? MOTypography.headingSmall : MOTypography.headingLarge).copyWith(color: context.surfaceTextNeutralNormal));
        final delta = Text(ltp == 0 ? 'waiting for live price…' : '${signed(ch)} (${pct(pc)}) today',
            style: MOTypography.bodySmallSemibold.copyWith(color: ltp == 0 ? context.surfaceTextNeutralStrong : deltaColor(context, ch)));
        if (compact) {
          return Row(children: <Widget>[price, MOSpacing.horizontalSpace8, Expanded(child: delta)]);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            price,
            MOSpacing.verticalSpace2,
            delta,
            MOSpacing.verticalSpace12,
            Wrap(
              spacing: MOSpacing.spacing16,
              runSpacing: MOSpacing.spacing8,
              children: <Widget>[
                _Stat('Open', t == null || t.open == 0 ? '—' : _money(t.open)),
                _Stat('Prev close', t == null || t.prevClose == 0 ? '—' : _money(t.prevClose)),
                _Stat('Volume', t == null || t.volume == 0 ? '—' : NumberFormat.compact(locale: 'en_IN').format(t.volume)),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          Text(value, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
        ],
      );
}

/// Returns per period as a bar chart (values arrive ×100).
class _ReturnsChart extends StatelessWidget {
  const _ReturnsChart({required this.returns});
  final ReturnsResponse returns;

  @override
  Widget build(BuildContext context) {
    final entries = returns.entry;
    if (entries.isEmpty) return Text('No returns data.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final pos = context.surfaceTextPositiveNormal;
    final neg = context.surfaceTextNegativeNormal;
    final maxAbs = entries.map((e) => (e.value / 100).abs()).fold<double>(1, (a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Returns by period', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
        MOSpacing.verticalSpace8,
        SizedBox(
          height: 160,
          child: BarChart(
            BarChartData(
              maxY: maxAbs * 1.2,
              minY: entries.any((e) => e.value < 0) ? -maxAbs * 1.2 : 0,
              barTouchData: BarTouchData(enabled: false),
              gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: maxAbs / 2, getDrawingHorizontalLine: (v) => FlLine(color: context.surfaceBorderNeutralNormal, strokeWidth: .5)),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                topTitles: const AxisTitles(),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(entries[v.toInt()].period, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    ),
                  ),
                ),
              ),
              barGroups: <BarChartGroupData>[
                for (var i = 0; i < entries.length; i++)
                  BarChartGroupData(x: i, barRods: <BarChartRodData>[
                    BarChartRodData(toY: entries[i].value / 100, width: 18, color: entries[i].value < 0 ? neg : pos, borderRadius: BorderRadius.circular(4)),
                  ]),
              ],
            ),
          ),
        ),
        MOSpacing.verticalSpace8,
        Wrap(
          spacing: MOSpacing.spacing12,
          children: <Widget>[
            for (final e in entries)
              Text('${e.period} ${pct(e.value / 100)}', style: MOTypography.bodyXsmallRegular.copyWith(color: deltaColor(context, e.value))),
          ],
        ),
      ],
    );
  }
}

class _Ratios extends StatelessWidget {
  const _Ratios({required this.ratios});
  final FundamentalRatios ratios;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      MapEntry('Market cap', ratios.marketCap == 0 ? '—' : '₹${NumberFormat.compact(locale: 'en_IN').format(ratios.marketCap)}'),
      MapEntry('P/E', _n(ratios.peRatio)),
      MapEntry('Industry P/E', ratios.industryPe == 0 ? '—' : ratios.industryPe.toString()),
      MapEntry('P/B', _n(ratios.pbRatio)),
      MapEntry('EPS', _n(ratios.eps)),
      MapEntry('ROE', ratios.roe == 0 ? '—' : '${_n(ratios.roe)}%'),
      MapEntry('Dividend yield', ratios.dividend == 0 ? '—' : '${_n(ratios.dividend)}%'),
      MapEntry('Debt / equity', _n(ratios.debtToEquityRatio)),
      MapEntry('Book value', ratios.bookValue == 0 ? '—' : ratios.bookValue.toString()),
      MapEntry('Face value', ratios.faceValue == 0 ? '—' : ratios.faceValue.toString()),
    ];
    return _Table(rows: rows);
  }
}

class _Technicals extends StatelessWidget {
  const _Technicals({required this.data});
  final QuoteTechnicalResponse data;

  @override
  Widget build(BuildContext context) {
    final rs = data.rs;
    final rows = <MapEntry<String, String>>[
      for (final e in data.movingAverage.sma) MapEntry('SMA ${e.dayCount}d', _n(e.avgPrice)),
      for (final e in data.movingAverage.ema) MapEntry('EMA ${e.dayCount}d', _n(e.avgPrice)),
      if (rs.pivotPoint != 0) ...<MapEntry<String, String>>[
        MapEntry('Pivot', _n(rs.pivotPoint / 100)),
        MapEntry('Resistance', '${_n(rs.r1 / 100)} · ${_n(rs.r2 / 100)} · ${_n(rs.r3 / 100)}'),
        MapEntry('Support', '${_n(rs.s1 / 100)} · ${_n(rs.s2 / 100)} · ${_n(rs.s3 / 100)}'),
      ],
    ];
    if (rows.isEmpty) return Text('No technical data.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    return _Table(rows: rows);
  }
}

class _News extends StatelessWidget {
  const _News({required this.news});
  final List<NewsEntry> news;

  @override
  Widget build(BuildContext context) {
    if (news.isEmpty) return Text('No recent news.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final n in news.take(5))
          Padding(
            padding: MOSpacing.paddingVertical6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                if (n.description.isNotEmpty)
                  Text(n.description, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                if (n.newsDateTime != 0)
                  Text(DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(n.newsDateTime * (n.newsDateTime < 100000000000 ? 1000 : 1))),
                      style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Statements from the same `Financials` API as the classic Financials tab.
class _Financials extends StatelessWidget {
  const _Financials({required this.data, required this.statement, required this.onStatement});
  final FinancialsResponse data;
  final String statement;
  final ValueChanged<String> onStatement;

  @override
  Widget build(BuildContext context) {
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    final val = MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
    final h = data.header;
    final cols = <String>[h.value1, h.value2, h.value3, h.value4, h.value5].where((c) => c.isNotEmpty).toList();
    final quarterly = statement == 'QuarterlyResults';
    final rows = quarterly
        ? data.quarterly.map((q) => MapEntry(q.particulars, <double>[q.quarter1, q.quarter2, q.quarter3, q.quarter4, q.quarter5])).toList()
        : (statement == 'BalanceSheets' ? data.balSheet : statement == 'CashFlow' ? data.cashFlow : data.profitLoss).map((y) => MapEntry(y.particulars, <double>[y.year1, y.year2, y.year3, y.year4, y.year5])).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: 6, children: <Widget>[
        for (final e in _StockCardState.statements.entries) ChoiceChip(label: Text(e.value), selected: statement == e.key, visualDensity: VisualDensity.compact, onSelected: (_) => onStatement(e.key)),
      ]),
      MOSpacing.verticalSpace6,
      if (rows.isEmpty) Text('No data for this statement.', style: sub) else ...<Widget>[
        if (h.label.isNotEmpty) Text(h.label, style: sub),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            columnWidths: const <int, TableColumnWidth>{0: FixedColumnWidth(120)},
            children: <TableRow>[
              TableRow(children: <Widget>[Padding(padding: MOSpacing.paddingAll4, child: Text('', style: sub)), for (final c in cols) Padding(padding: MOSpacing.paddingAll4, child: Text(c, textAlign: TextAlign.end, style: sub))]),
              for (final r in rows.take(14))
                TableRow(children: <Widget>[
                  Padding(padding: MOSpacing.paddingAll4, child: Text(r.key, maxLines: 2, style: sub)),
                  for (var i = 0; i < cols.length; i++) Padding(padding: MOSpacing.paddingAll4, child: Text(_compact(r.value[i]), textAlign: TextAlign.end, style: val)),
                ]),
            ],
          ),
        ),
        Text('₹ crore unless the row says otherwise.', style: sub),
      ],
    ]);
  }

  String _compact(double v) => v == 0 ? '—' : NumberFormat('#,##,##0.##', 'en_IN').format(v);
}

/// Peer comparison and the house view, from the Get Quote peer API.
class _Peers extends StatelessWidget {
  const _Peers({required this.data});
  final PeerComparisonResponse data;

  @override
  Widget build(BuildContext context) {
    final d = data;
    final rows = <MapEntry<String, String>>[
      if (d.recommendationText.isNotEmpty) MapEntry('View', d.recommendationText),
      if (d.qvtInsight.quality.isNotEmpty) MapEntry('Quality', d.qvtInsight.quality),
      if (d.qvtInsight.valuation.isNotEmpty) MapEntry('Valuation', d.qvtInsight.valuation),
      if (d.qvtInsight.technical.isNotEmpty) MapEntry('Technical', d.qvtInsight.technical),
      if (d.mojoFinTrend.isNotEmpty) MapEntry('Financial trend', d.mojoFinTrend),
      if (d.mojoQuality.isNotEmpty) MapEntry('Mojo quality', d.mojoQuality),
      if (d.mojoValuation.isNotEmpty) MapEntry('Mojo valuation', d.mojoValuation),
      MapEntry('P/E', _n(d.pe)),
      MapEntry('P/B', _n(d.pb)),
      MapEntry('EPS', _n(d.eps)),
      MapEntry('Dividend', d.dividend == 0 ? '—' : '${_n(d.dividend)}%'),
      MapEntry('1Y return', d.oneYearReturn == 0 ? '—' : '${signed(d.oneYearReturn)}%'),
      MapEntry('Market cap', d.marketCap == 0 ? '—' : '₹${NumberFormat.compact(locale: 'en_IN').format(d.marketCap)}'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _Table(rows: rows),
      Text('Ratings are research inputs, not advice.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
    ]);
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.rows});
  final List<MapEntry<String, String>> rows;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          for (final r in rows)
            Padding(
              padding: MOSpacing.paddingVertical4,
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(r.key, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
                  Text(r.value, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                ],
              ),
            ),
        ],
      );
}

String _n(num v) => v == 0 ? '—' : v.toStringAsFixed(2);
String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
