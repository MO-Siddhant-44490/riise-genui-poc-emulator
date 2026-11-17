import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/index_resolver.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_genui/src/ui/research_narrative.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_funds_order_book/data/transactions_type_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_funds_order_book/domain/model/order_book_response_model.dart';
import 'package:mo_portfolio_2_0/data/mo_portfolio_dashboard_repository_impl.dart';
import 'package:mo_portfolio_2_0/domain/mo_portfolio_dashboard_model/equity_detail_response.dart';
import 'package:mo_portfolio_analysis/data/portfolio_analysis_repository_impl.dart';
import 'package:mo_portfolio_analysis/utils/enums.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioAnalysisCommon.pb.dart' show Benchmark;
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioRevamp.pb.dart' show UpcomingEventEntry;
import 'package:trader_proto_gen/PortfolioRevamp/StockAnalysis.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteFundamentalModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteOverviewModels.pb.dart';

// ---------------------------------------------------------------------------------------------
// AI-native cards: answers the classic app has no screen for. Each one reads the user's own data
// through the app's repositories and composes a view; the numbers are computed here, never by
// the model, so they are exactly what the classic screens would show.
// ---------------------------------------------------------------------------------------------

String _rs(num v) => '₹${NumberFormat('#,##,##0', 'en_IN').format(v.round())}';
String _rs2(num v) => '₹${NumberFormat('#,##,##0.00', 'en_IN').format(v)}';
String _pct(num v, {int d = 1}) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(d)}%';
Color _delta(BuildContext c, num v) => v < 0 ? c.surfaceTextNegativeNormal : c.surfaceTextPositiveNormal;
TextStyle _h(BuildContext c) => MOTypography.bodySmallSemibold.copyWith(color: c.surfaceTextNeutralNormal);
TextStyle _b(BuildContext c) => MOTypography.bodySmallRegular.copyWith(color: c.surfaceTextNeutralNormal);
TextStyle _sub(BuildContext c) => MOTypography.bodyXsmallRegular.copyWith(color: c.surfaceTextNeutralStrong);
Widget _note(BuildContext c, String t) => Padding(padding: MOSpacing.paddingVertical4, child: Text(t, style: _sub(c)));
Widget _err(BuildContext c, Object e) => Padding(padding: MOSpacing.paddingVertical8, child: Text('$e'.replaceFirst('Exception: ', ''), style: MOTypography.bodySmallRegular.copyWith(color: c.surfaceTextNegativeNormal)));
const Widget _spin = Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))));

String _periodLabel(String p) {
  const m = <String, String>{'oneday': '1D', 'oneweek': '1W', 'onemonth': '1M', 'threemonth': '3M', 'sixmonth': '6M', 'oneyear': '1Y', 'twoyear': '2Y', 'threeyear': '3Y', 'fiveyear': '5Y', 'ytd': 'YTD', '1d': '1D', '1w': '1W', '1m': '1M', '3m': '3M', '6m': '6M', '1y': '1Y', '2y': '2Y', '3y': '3Y', '5y': '5Y'};
  return m[p.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')] ?? p;
}

String _date(int epoch) {
  if (epoch == 0) return '';
  final ms = epoch > 100000000000 ? epoch : epoch * 1000;
  return DateFormat('d MMM').format(DateTime.fromMillisecondsSinceEpoch(ms));
}

Widget _chip(BuildContext c, String label, {bool selected = false, VoidCallback? onTap}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(label: Text(label), selected: selected, visualDensity: VisualDensity.compact, onSelected: onTap == null ? null : (_) => onTap()),
    );

Widget _askChip(BuildContext c, String label, String question) => ActionChip(
      label: Text(label, style: MOTypography.labelSmallMediumAbc.copyWith(color: c.surfaceTextPrimaryNormal)),
      onPressed: () => GenUiNav.ask(question),
      backgroundColor: c.surfaceBackgroundPrimaryFaded,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );

Future<List<EquityHoldingItem>> _holdings() async => (await MoPortfolioDashBoardRepositoryImpl().getEquityDetailAPI(loadFromCache: false)).holdings;

// ============================================================================================
// What if the market falls X%?
// ============================================================================================

/// "What if the market falls 10%?" / "what if HDFC Bank drops 20%": the user's holdings re-priced
/// by the shock, biggest hits first. Uniform shock; a stock-specific one applies to that holding.
class WhatIfCard extends StatefulWidget {
  const WhatIfCard({super.key, this.shock, this.scrip});
  final num? shock;
  final ScripRef? scrip;

  @override
  State<WhatIfCard> createState() => _WhatIfCardState();
}

class _WhatIfCardState extends State<WhatIfCard> {
  late double _shock = (widget.shock ?? -10).toDouble();
  late Future<List<EquityHoldingItem>> _future = _holdings();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<EquityHoldingItem>>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: widget.scrip == null ? 'What if the market moves ${_pct(_shock, d: 0)}?' : 'What if ${widget.scrip!.symbol} moves ${_pct(_shock, d: 0)}?',
          subtitle: 'Your holdings re-priced by that move. A what-if, not a forecast.',
          onRefresh: () => setState(() => _future = _holdings()),
          child: snap.hasError
              ? _err(context, snap.error!)
              : !snap.hasData
                  ? _spin
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, List<EquityHoldingItem> all) {
    final target = widget.scrip;
    final rows = target == null ? all : all.where((h) => h.tradeSymbol.toUpperCase() == target.symbol.toUpperCase() || h.scripId?.scripCode == target.scripCode).toList();
    if (all.isEmpty) return _note(context, 'No stock holdings to re-price.');
    if (rows.isEmpty) return _note(context, 'You do not hold ${target!.symbol}, so a move in it would not change your portfolio.');
    final total = all.fold<double>(0, (a, h) => a + h.marketValue);
    final hit = rows.fold<double>(0, (a, h) => a + h.marketValue * _shock / 100);
    final after = total + hit;
    final invested = all.fold<double>(0, (a, h) => a + (h.investedValue > 0 ? h.investedValue : h.avgPrice * h.totalQuantity));
    final sorted = <EquityHoldingItem>[...rows]..sort((a, b) => b.marketValue.compareTo(a.marketValue));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(children: <Widget>[
        for (final s in const <double>[-20, -10, -5, 5, 10]) _chip(context, _pct(s, d: 0), selected: _shock == s, onTap: () => setState(() => _shock = s)),
      ]),
      MOSpacing.verticalSpace8,
      Row(children: <Widget>[
        Expanded(child: _kv(context, 'Today', _rs(total))),
        Expanded(child: _kv(context, 'After ${_pct(_shock, d: 0)}', _rs(after), color: _delta(context, hit))),
        Expanded(child: _kv(context, 'Change', '${hit < 0 ? '−' : '+'}${_rs(hit.abs())}', color: _delta(context, hit))),
      ]),
      MOSpacing.verticalSpace4,
      Text(
        invested > 0
            ? 'Against ${_rs(invested)} invested that would be ${_pct((after - invested) / invested * 100)} overall (${_pct((total - invested) / invested * 100)} today).'
            : 'Overall change from invested value is not available.',
        style: _sub(context),
      ),
      const Divider(height: 20),
      Text(target == null ? 'Biggest rupee impact' : 'Holding', style: _h(context)),
      for (final h in sorted.take(8))
        AdaptiveRow(
          leading: Text(h.tradeSymbol, style: _b(context)),
          trailing: Text('${h.marketValue * _shock / 100 < 0 ? '−' : '+'}${_rs((h.marketValue * _shock / 100).abs())} · ${_rs(h.marketValue)} held', style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, _shock))),
        ),
      MOSpacing.verticalSpace8,
      Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
        _askChip(context, 'Is my portfolio too risky?', 'Is my portfolio too risky?'),
        _askChip(context, 'How should I rebalance?', 'How should I rebalance my portfolio?'),
      ]),
      ResearchNarrative(
        key: ValueKey<String>('whatif-${_shock.round()}-${target?.symbol ?? ''}'),
        heading: "Research desk's view",
        question: target == null
            ? 'My stock portfolio is worth ${_rs(total)} today (${_rs(invested)} invested, ${_pct((total - invested) / (invested == 0 ? 1 : invested) * 100)} so far), concentrated in ${sorted.take(2).map((h) => h.tradeSymbol).join(' and ')}. '
                'A ${_shock.abs().toStringAsFixed(0)}% market fall would take it to ${_rs(after)}, a change of ${_rs(hit.abs())}; use these figures as given. '
                'Explain, in three short bullets for a retail investor, what such a fall typically means for a portfolio like this and what is worth checking afterwards. This is an educational explanation, not a recommendation.'
            : 'Explain, in three short bullets for a retail investor, what it means when a single holding such as ${target.symbol} (worth ${_rs(rows.fold<double>(0, (a, h) => a + h.marketValue))} in my portfolio) '
                'falls ${_shock.abs().toStringAsFixed(0)}%, and what is worth checking. This is an educational explanation, not a recommendation.',
      ),
    ]);
  }

  Widget _kv(BuildContext c, String k, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(k, style: _sub(c)),
        Text(v, style: MOTypography.bodyMediumSemibold.copyWith(color: color ?? c.surfaceTextNeutralNormal)),
      ]);
}

// ============================================================================================
// My portfolio vs the market
// ============================================================================================

class _Perf {
  const _Perf({required this.period, required this.portfolio, required this.benchmark, required this.points, required this.from, required this.to, this.benchKnown = true, this.sincePurchase = false});
  final String period;
  final double portfolio;
  final double benchmark;
  final int points;
  final DateTime from;
  final DateTime to;
  final bool benchKnown;

  /// True when the trend had no points and the portfolio side is the overall return since purchase.
  final bool sincePurchase;
}

/// "Am I beating the market?": the portfolio's own return against Nifty over a period, from the
/// same benchmark-trend series the classic analysis screen draws.
class PfVsMarketCard extends StatefulWidget {
  const PfVsMarketCard({super.key, this.period, this.benchmark});
  final String? period;
  final String? benchmark;
  static const List<String> periods = <String>['1M', '3M', '6M', '1Y', '3Y', '5Y'];

  @override
  State<PfVsMarketCard> createState() => _PfVsMarketCardState();
}

class _PfVsMarketCardState extends State<PfVsMarketCard> {
  late String _period = PfVsMarketCard.periods.contains((widget.period ?? '').toUpperCase()) ? widget.period!.toUpperCase() : '1Y';
  late String _bench = _benchId(widget.benchmark);
  Future<_Perf?>? _future;

  static String _benchId(String? b) {
    final l = (b ?? '').toLowerCase();
    if (l.contains('500')) return 'NIFTY500';
    if (l.contains('100')) return 'NIFTY100';
    return 'NIFTY50';
  }

  int get _months => switch (_period) { '1M' => 1, '3M' => 3, '6M' => 6, '3Y' => 36, '5Y' => 60, _ => 12 };

  Future<_Perf?> _load() async {
    final fmt = DateFormat('MM/dd/yyyy HH:mm:ss');
    DateTime parse(String s) {
      try {
        return fmt.parse(s);
      } catch (_) {
        return DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    // The analysis trend, stocks first, then funds: whichever has points for this period.
    final repo = PortfolioAnalysisRepositoryImpl();
    List<(DateTime, double, double)> pts = const <(DateTime, double, double)>[];
    for (final sub in <AnalysisSubTabType>[AnalysisSubTabType.stocks, AnalysisSubTabType.mutualFund]) {
      try {
        final Benchmark b = await repo.fetchBenchMarkPerformanceTrend(_months, _bench, AnalysisType.mofsl.index, sub, _period);
        final got = b.details.map((d) => (parse(d.asOfDate), d.portfolioValue.toInt() / 100, d.benchmarkValue.toInt() / 100)).where((e) => e.$2 > 0).toList()..sort((x, y) => x.$1.compareTo(y.$1));
        debugPrint('GenUI pf vs market: ${sub.name} $_period → ${b.details.length} details, ${got.length} usable');
        if (got.length >= 2) {
          pts = got;
          break;
        }
      } catch (e) {
        debugPrint('GenUI pf vs market trend failed: $e');
      }
    }
    // Benchmark side: the trend's own series when it has one, else the index's published return.
    double? bench;
    if (pts.length >= 2 && pts.first.$3 > 0 && pts.last.$3 > 0) {
      bench = (pts.last.$3 - pts.first.$3) / pts.first.$3 * 100;
    } else {
      try {
        final idx = await resolveIndex(name: _benchName(_bench));
        final det = await MoGetQuoteRepositoryImpl().fetchIndexQuoteDetail(indexId: idx.indexId, exchangeCode: idx.exchangeCode);
        for (final r in det.returns.entry) {
          if (_periodLabel(r.period) == _period) bench = r.value / 100;
        }
      } catch (e) {
        debugPrint('GenUI pf vs market index failed: $e');
      }
    }
    if (pts.length >= 2) {
      return _Perf(period: _period, portfolio: (pts.last.$2 - pts.first.$2) / pts.first.$2 * 100, benchmark: bench ?? 0, points: pts.length, from: pts.first.$1, to: pts.last.$1, benchKnown: bench != null);
    }
    // No trend at all: fall back to the holdings' overall return since purchase.
    final h = await _holdings();
    final inv = h.fold<double>(0, (a, x) => a + (x.investedValue > 0 ? x.investedValue : x.avgPrice * x.totalQuantity));
    final cur = h.fold<double>(0, (a, x) => a + x.marketValue);
    if (inv <= 0) return null;
    return _Perf(period: _period, portfolio: (cur - inv) / inv * 100, benchmark: bench ?? 0, points: 0, from: DateTime.now(), to: DateTime.now(), benchKnown: bench != null, sincePurchase: true);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Perf?>(
        future: _future ??= _load(),
        builder: (context, snap) => CardFrame(
          title: 'My portfolio vs the market',
          subtitle: 'Your stocks against ${_benchName(_bench)}, from the analysis trend',
          onRefresh: () => setState(() => _future = null),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Wrap(children: <Widget>[
              for (final p in PfVsMarketCard.periods)
                _chip(context, p, selected: _period == p, onTap: () => setState(() {
                      _period = p;
                      _future = null;
                    })),
            ]),
            MOSpacing.verticalSpace8,
            if (snap.hasError)
              _err(context, snap.error!)
            else if (snap.connectionState != ConnectionState.done)
              _spin
            else if (snap.data == null)
              _note(context, 'Neither the analysis trend nor your holdings gave a return to compare for $_period.')
            else
              _body(context, snap.data!),
          ]),
        ),
      );

  static String _benchName(String id) => switch (id) { 'NIFTY100' => 'Nifty 100', 'NIFTY500' => 'Nifty 500', _ => 'Nifty 50' };

  Widget _body(BuildContext context, _Perf p) {
    final gap = p.portfolio - p.benchmark;
    final verdict = !p.benchKnown
        ? 'Your stocks: ${_pct(p.portfolio)}. The index return for $_period was not available to compare.'
        : gap.abs() < 0.5
        ? 'Level with the market over $_period.'
        : gap > 0
            ? 'Ahead of the market by ${gap.toStringAsFixed(1)} points over $_period.'
            : 'Behind the market by ${gap.abs().toStringAsFixed(1)} points over $_period.';
    final maxAbs = math.max(p.portfolio.abs(), p.benchmark.abs()).clamp(1, double.infinity);
    Widget bar(String label, double v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: <Widget>[
            SizedBox(width: 92, child: Text(label, style: _sub(context))),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: (v.abs() / maxAbs).clamp(0.02, 1).toDouble(),
                  child: Container(height: 12, decoration: BoxDecoration(color: _delta(context, v), borderRadius: BorderRadius.circular(3))),
                ),
              ),
            ),
            MOSpacing.horizontalSpace8,
            SizedBox(width: 64, child: Text(_pct(v), textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, v)))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(verdict, style: MOTypography.bodyMediumSemibold.copyWith(color: _delta(context, gap))),
      MOSpacing.verticalSpace8,
      bar(p.sincePurchase ? 'My stocks (since purchase)' : 'My stocks', p.portfolio),
      if (p.benchKnown) bar('${_benchName(_bench)} ($_period)', p.benchmark),
      MOSpacing.verticalSpace4,
      Text(
        p.sincePurchase
            ? 'The analysis trend has no points for $_period on this account, so your side is the overall return on what you hold today.'
            : '${DateFormat('d MMM yy').format(p.from)} → ${DateFormat('d MMM yy').format(p.to)} · ${p.points} points',
        style: _sub(context),
      ),
      MOSpacing.verticalSpace8,
      Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
        _askChip(context, 'Show the trend chart', 'Show my portfolio trend'),
        _askChip(context, 'What is dragging it?', 'What is dragging my portfolio today?'),
      ]),
      ResearchNarrative(
        key: ValueKey<String>('pfvm-$_period-$_bench'),
        heading: "Research desk's view",
        question: 'My stock portfolio returned ${_pct(p.portfolio)}${p.sincePurchase ? ' since purchase' : ' over $_period'}'
            '${p.benchKnown ? ' while ${_benchName(_bench)} returned ${_pct(p.benchmark)} over $_period' : ''}. '
            'In three short bullets: what does a gap like this usually mean for a retail investor and what is worth checking, without naming stocks to buy?',
      ),
    ]);
  }
}

// ============================================================================================
// A stock vs the market, and stocks side by side
// ============================================================================================

class _StockFacts {
  _StockFacts(this.ref);
  final ScripRef ref;
  Map<String, double> returns = <String, double>{};
  FundamentalRatios? ratios;
  Object? error;
}

Future<_StockFacts> _facts(ScripRef ref) async {
  final f = _StockFacts(ref);
  final repo = MoGetQuoteRepositoryImpl();
  final sym = ref.symbol.replaceAll('&', '%26');
  try {
    final QuoteOverviewResponse o = await repo.fetchQuoteOverviewData(symbol: sym, sections: <String>['Returns']);
    for (final e in o.returns.entry) {
      f.returns[_periodLabel(e.period)] = e.value / 100;
    }
  } catch (e) {
    f.error = e;
  }
  try {
    final FundamentalResponseV2 r = await repo.fetchQuoteFundamentalData(symbol: sym, sections: <String>['Ratios']);
    f.ratios = r.ratios;
  } catch (e) {
    f.error ??= e;
  }
  return f;
}

const List<String> _periods = <String>['1W', '1M', '3M', '6M', '1Y', '3Y'];

/// "How has Infosys done against Nifty?": the stock's returns beside the index's, period by period.
class StockVsIndexCard extends StatefulWidget {
  const StockVsIndexCard({super.key, required this.scrip, this.index});
  final ScripRef scrip;
  final String? index;

  @override
  State<StockVsIndexCard> createState() => _StockVsIndexCardState();
}

class _StockVsIndexCardState extends State<StockVsIndexCard> {
  Future<(_StockFacts, IndexRef, Map<String, double>)>? _future;

  Future<(_StockFacts, IndexRef, Map<String, double>)> _load() async {
    final idx = await resolveIndex(name: widget.index ?? 'Nifty 50');
    final facts = _facts(widget.scrip);
    final det = await MoGetQuoteRepositoryImpl().fetchIndexQuoteDetail(indexId: idx.indexId, exchangeCode: idx.exchangeCode);
    final ir = <String, double>{for (final r in det.returns.entry) _periodLabel(r.period): r.value / 100};
    return (await facts, idx, ir);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(_StockFacts, IndexRef, Map<String, double>)>(
        future: _future ??= _load(),
        builder: (context, snap) => CardFrame(
          live: true,
          title: '${widget.scrip.symbol} vs ${snap.data?.$2.name ?? widget.index ?? 'Nifty 50'}',
          subtitle: 'Returns by period, and the gap',
          onRefresh: () => setState(() => _future = null),
          child: snap.hasError
              ? _err(context, snap.error!)
              : !snap.hasData
                  ? _spin
                  : _body(context, snap.data!.$1, snap.data!.$2, snap.data!.$3),
        ),
      );

  Widget _body(BuildContext context, _StockFacts f, IndexRef idx, Map<String, double> ir) {
    final periods = _periods.where((p) => f.returns.containsKey(p) || ir.containsKey(p)).toList();
    if (periods.isEmpty) return _note(context, 'No period returns came back for ${widget.scrip.symbol} or ${idx.name} on UAT.');
    final ahead = periods.where((p) => (f.returns[p] ?? 0) > (ir[p] ?? 0)).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      LivePrice.scrip(
        scrip: widget.scrip.scripId,
        builder: (context, t) => Text(t == null || t.ltp == 0 ? widget.scrip.name : '${widget.scrip.name} · ${_rs2(t.ltp)} (${_pct(t.perChange, d: 2)} today)', style: _sub(context)),
      ),
      MOSpacing.verticalSpace6,
      Text('${widget.scrip.symbol} is ahead of ${idx.name} in $ahead of ${periods.length} periods.', style: MOTypography.bodyMediumSemibold.copyWith(color: ahead * 2 >= periods.length ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal)),
      MOSpacing.verticalSpace8,
      Row(children: <Widget>[
        const SizedBox(width: 44),
        Expanded(child: Text(widget.scrip.symbol, textAlign: TextAlign.right, style: _sub(context))),
        Expanded(child: Text(idx.name, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: _sub(context))),
        Expanded(child: Text('Gap', textAlign: TextAlign.right, style: _sub(context))),
      ]),
      for (final p in periods)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: <Widget>[
            SizedBox(width: 44, child: Text(p, style: _h(context))),
            Expanded(child: Text(f.returns.containsKey(p) ? _pct(f.returns[p]!) : '—', textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, f.returns[p] ?? 0)))),
            Expanded(child: Text(ir.containsKey(p) ? _pct(ir[p]!) : '—', textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, ir[p] ?? 0)))),
            Expanded(child: Text(f.returns.containsKey(p) && ir.containsKey(p) ? _pct(f.returns[p]! - ir[p]!) : '—', textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, (f.returns[p] ?? 0) - (ir[p] ?? 0))))),
          ]),
        ),
      if (f.ratios != null && f.ratios!.peRatio != 0) ...<Widget>[
        MOSpacing.verticalSpace6,
        Text('P/E ${f.ratios!.peRatio.toStringAsFixed(1)}${f.ratios!.industryPe == 0 ? '' : ' vs industry ${f.ratios!.industryPe}'}', style: _sub(context)),
      ],
      MOSpacing.verticalSpace8,
      Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
        _askChip(context, 'Open ${widget.scrip.symbol}', 'Tell me about ${widget.scrip.symbol}'),
        _askChip(context, 'Open ${idx.name}', idx.name),
      ]),
    ]);
  }
}

/// "Compare TCS, Infosys and Wipro": price, returns and ratios side by side.
class StockCompareCard extends StatefulWidget {
  const StockCompareCard({super.key, required this.scrips});
  final List<ScripRef> scrips;

  @override
  State<StockCompareCard> createState() => _StockCompareCardState();
}

class _StockCompareCardState extends State<StockCompareCard> {
  Future<List<_StockFacts>>? _future;

  @override
  Widget build(BuildContext context) {
    final refs = widget.scrips.take(3).toList();
    return FutureBuilder<List<_StockFacts>>(
      future: _future ??= Future.wait(refs.map(_facts)),
      builder: (context, snap) => CardFrame(
        live: true,
        title: refs.map((r) => r.symbol).join(' vs '),
        subtitle: refs.length < 2 ? 'Name two or three stocks to compare' : 'Side by side: price, returns, valuation',
        onRefresh: () => setState(() => _future = null),
        child: refs.length < 2
            ? _note(context, 'Say "compare TCS and Infosys" to put two stocks side by side.')
            : snap.hasError
                ? _err(context, snap.error!)
                : !snap.hasData
                    ? _spin
                    : _body(context, snap.data!),
      ),
    );
  }

  /// One table row whose cells come from each stock's live tick.
  Widget _liveRow(BuildContext context, String label, List<_StockFacts> facts, String Function(dynamic t) text, num Function(dynamic t) tone) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: <Widget>[
          SizedBox(width: 88, child: Text(label, style: _sub(context))),
          for (final f in facts)
            Expanded(
              child: LivePrice.scrip(
                scrip: f.ref.scripId,
                builder: (context, t) => Text(text(t), textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: tone(t) == 0 ? context.surfaceTextNeutralNormal : _delta(context, tone(t)))),
              ),
            ),
        ]),
      );

  Widget _body(BuildContext context, List<_StockFacts> facts) {
    final cols = facts.length;
    Widget head() => Row(children: <Widget>[
          const SizedBox(width: 88),
          for (final f in facts) Expanded(child: Text(f.ref.symbol, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: _h(context))),
        ]);
    Widget row(String label, List<String> cells, {List<num>? tone}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: <Widget>[
            SizedBox(width: 88, child: Text(label, style: _sub(context))),
            for (var i = 0; i < cols; i++)
              Expanded(child: Text(cells[i], textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: tone == null ? context.surfaceTextNeutralNormal : _delta(context, tone[i])))),
          ]),
        );
    String n(num v, {int d = 1}) => v == 0 ? '—' : v.toStringAsFixed(d);
    final best = <String>[];
    for (final p in const <String>['1Y', '3M']) {
      final have = facts.where((f) => f.returns.containsKey(p)).toList();
      if (have.length >= 2) {
        have.sort((a, b) => b.returns[p]!.compareTo(a.returns[p]!));
        best.add('${have.first.ref.symbol} leads over $p (${_pct(have.first.returns[p]!)})');
        break;
      }
    }
    final cheap = facts.where((f) => (f.ratios?.peRatio ?? 0) > 0).toList()..sort((a, b) => a.ratios!.peRatio.compareTo(b.ratios!.peRatio));
    if (cheap.length >= 2) best.add('${cheap.first.ref.symbol} is the cheapest on P/E (${cheap.first.ratios!.peRatio.toStringAsFixed(1)})');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (best.isNotEmpty) Text(best.join('. '), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
      MOSpacing.verticalSpace8,
      head(),
      _liveRow(context, 'Price', facts, (t) => t == null || t.ltp == 0 ? '—' : _rs2(t.ltp), (t) => 0),
      _liveRow(context, 'Today', facts, (t) => t == null || t.ltp == 0 ? '—' : _pct(t.perChange, d: 2), (t) => t?.perChange ?? 0),
      for (final p in _periods)
        if (facts.any((f) => f.returns.containsKey(p))) row(p, [for (final f in facts) f.returns.containsKey(p) ? _pct(f.returns[p]!) : '—'], tone: [for (final f in facts) f.returns[p] ?? 0]),
      const Divider(height: 16),
      row('Market cap', [for (final f in facts) (f.ratios?.marketCap ?? 0) == 0 ? '—' : '₹${NumberFormat.compact(locale: 'en_IN').format(f.ratios!.marketCap)} Cr']),
      row('P/E', [for (final f in facts) n(f.ratios?.peRatio ?? 0)]),
      row('P/B', [for (final f in facts) n(f.ratios?.pbRatio ?? 0)]),
      row('ROE', [for (final f in facts) (f.ratios?.roe ?? 0) == 0 ? '—' : '${n(f.ratios!.roe)}%']),
      row('EPS', [for (final f in facts) n(f.ratios?.eps ?? 0)]),
      row('Debt/equity', [for (final f in facts) n(f.ratios?.debtToEquityRatio ?? 0, d: 2)]),
      if (facts.any((f) => f.error != null)) _note(context, 'Some numbers did not load on UAT: ${facts.where((f) => f.error != null).map((f) => f.ref.symbol).join(', ')}.'),
      MOSpacing.verticalSpace8,
      Wrap(spacing: 8, runSpacing: 6, children: <Widget>[for (final f in facts) _askChip(context, 'Open ${f.ref.symbol}', 'Tell me about ${f.ref.symbol}')]),
    ]);
  }
}

// ============================================================================================
// Explain a term, with the user's own numbers
// ============================================================================================

class _Term {
  const _Term(this.keys, this.title, this.what, this.why, {this.needsStock = false});
  final List<String> keys;
  final String title;
  final String what;
  final String why;
  final bool needsStock;
}

const List<_Term> _glossary = <_Term>[
  _Term(['pe', 'p/e', 'price to earnings', 'pe ratio'], 'P/E ratio', 'Price divided by earnings per share: how many years of today\'s profit you pay for one share.', 'Compare it with the industry P/E. Higher can mean growth expectations or an expensive stock.', needsStock: true),
  _Term(['pb', 'p/b', 'price to book', 'book value'], 'P/B ratio', 'Price divided by book value per share: price against the company\'s net assets on paper.', 'Below 1 can mean cheap or troubled; banks and asset-heavy firms are judged on it most.', needsStock: true),
  _Term(['eps', 'earnings per share'], 'Earnings per share', 'Net profit divided by the number of shares.', 'Rising EPS over years is what long-term returns are built on.', needsStock: true),
  _Term(['roe', 'return on equity'], 'Return on equity', 'Profit as a percentage of shareholders\' money.', 'Consistently above 15% is a sign the business earns well on what it keeps.', needsStock: true),
  _Term(['market cap', 'marketcap', 'market capitalisation', 'market capitalization'], 'Market cap', 'Share price times shares outstanding: the market\'s price for the whole company.', 'Large caps are the top 100 by market cap, mid caps the next 150, small caps the rest.', needsStock: true),
  _Term(['dividend yield', 'yield'], 'Dividend yield', 'Yearly dividend per share as a percentage of the price.', 'Steady, not high, yield is the usual sign of a healthy payer.', needsStock: true),
  _Term(['xirr', 'overall return', 'absolute return', 'returns'], 'Your overall return', 'Current value against what you invested. XIRR goes further and weights each rupee by how long it was invested.', 'Compare it with Nifty over the same period; "my portfolio vs the market" does that.'),
  _Term(['ltcg', 'long term capital gain', 'long term capital gains'], 'Long-term capital gains', 'Profit on shares or equity funds held for more than a year.', 'Taxed at 12.5% above ₹1.25 lakh of such gains in a financial year.'),
  _Term(['stcg', 'short term capital gain', 'short term capital gains'], 'Short-term capital gains', 'Profit on shares or equity funds sold within a year of buying.', 'Taxed at 20%, with no exemption. Holding past a year moves the gain to the lower LTCG rate.'),
  _Term(['sip', 'systematic investment plan'], 'SIP', 'A fixed amount invested in a fund on a fixed date every month.', 'You buy more units when prices are low and fewer when high, which averages your cost.'),
  _Term(['nav', 'net asset value'], 'NAV', 'The price of one unit of a mutual fund: the fund\'s assets divided by its units.', 'A low NAV is not cheap and a high NAV is not expensive; only the return matters.'),
  _Term(['expense ratio', 'ter'], 'Expense ratio', 'The yearly fee a fund takes, as a percentage of your money, deducted from the NAV.', 'Direct plans have lower expense ratios than regular plans of the same fund.'),
  _Term(['beta'], 'Beta', 'How much a stock moves for a 1% move in the market.', 'Beta 1.5 means it tends to rise or fall half again as much as Nifty.'),
  _Term(['oi', 'open interest'], 'Open interest', 'The number of option or future contracts still open.', 'Rising OI with a rising price suggests new long positions; the option chain shows it strike by strike.'),
  _Term(['pcr', 'put call ratio', 'put-call ratio'], 'Put-call ratio', 'Put open interest divided by call open interest.', 'Above about 1.3 is read as oversold or heavily hedged; below 0.7 as overbought. "How is Nifty looking" shows today\'s.'),
  _Term(['vix', 'india vix'], 'India VIX', 'The market\'s expected volatility over the next 30 days, from option prices.', 'Below 15 is calm; above 20 means options are pricing big moves.'),
  _Term(['max pain'], 'Max pain', 'The strike at which option buyers lose the most at expiry.', 'Prices are often said to drift toward it near expiry; treat it as one signal among many.'),
  _Term(['strike', 'strike price'], 'Strike price', 'The price at which an option lets you buy (call) or sell (put) the underlying.', 'In-the-money strikes already have value; out-of-the-money ones are cheaper bets.'),
  _Term(['premium', 'option premium'], 'Option premium', 'The price you pay for an option contract.', 'It is time value plus intrinsic value; time value melts as expiry nears.'),
  _Term(['delta', 'theta', 'gamma', 'vega', 'greeks'], 'Option greeks', 'Delta: move per ₹1 in the underlying. Theta: value lost per day. Gamma: how fast delta changes. Vega: sensitivity to volatility.', 'The option chain\'s "greeks" view shows them strike by strike.'),
  _Term(['lot size', 'lot'], 'Lot size', 'The minimum number of units in one F&O contract.', 'Nifty\'s lot is set by the exchange and changes from time to time; the option chain shows it.'),
  _Term(['margin', 'margin required'], 'Margin', 'The money the exchange blocks when you take a leveraged position.', '"My funds" shows what is available; charges show what an order needs.'),
  _Term(['mtf', 'margin trading facility'], 'MTF', 'Buying shares with part of the money borrowed from the broker, for interest.', 'Good for conviction buys you will hold weeks; interest accrues daily.'),
  _Term(['ltp', 'last traded price'], 'LTP', 'The price of the most recent trade.', 'It is not necessarily the price you will get; the bid and ask show that.'),
  _Term(['circuit', 'upper circuit', 'lower circuit'], 'Circuit limit', 'The daily price band beyond which a stock cannot trade.', 'A stock at upper circuit has buyers but no sellers; at lower circuit the reverse.'),
  _Term(['stop loss', 'sl'], 'Stop loss', 'An order that sells automatically if the price falls to a level you set.', 'Research calls carry an SL; TrigX can place one that waits for the trigger.'),
  _Term(['gtt', 'trigx'], 'TrigX (GTT)', 'An order that waits until the price reaches your trigger, for up to a year.', 'Use it for targets and stop losses you do not want to watch every day.'),
  _Term(['intraday', 'delivery', 'intraday vs delivery'], 'Intraday vs delivery', 'Intraday positions are squared off the same day; delivery buys go to your demat.', 'Intraday has lower charges and more leverage; delivery is for holding.'),
  _Term(['btst'], 'BTST', 'Buy today, sell tomorrow: selling shares before they reach your demat.', 'Allowed on most liquid stocks; check the stock\'s BTST flag.'),
  _Term(['pledge', 'pledging'], 'Pledging', 'Using shares you hold as collateral for margin.', 'The pledged shares stay yours; a haircut decides how much margin they give.'),
  _Term(['ipo'], 'IPO', 'A company selling shares to the public for the first time.', 'Apply through the app during the bidding window; allotment follows in a few days.'),
  _Term(['etf', 'exchange traded fund'], 'ETF', 'A fund that trades on the exchange like a share, usually tracking an index.', 'Cheaper than most active funds; you need a demat account to hold them.'),
  _Term(['elss', 'tax saving fund'], 'ELSS', 'An equity fund with a three-year lock-in that qualifies for a Section 80C deduction.', 'The shortest lock-in among 80C options.'),
  _Term(['rebalance', 'rebalancing'], 'Rebalancing', 'Selling what has grown past its target weight and buying what has shrunk below it.', 'Once or twice a year is usual; "how should I rebalance" checks your portfolio.'),
];

/// "What is XIRR?", "explain P/E for HDFC Bank": a plain definition, how to read it, and the
/// user's own number where one exists.
class ExplainCard extends StatefulWidget {
  const ExplainCard({super.key, this.term, this.scrip});
  final String? term;
  final ScripRef? scrip;

  @override
  State<ExplainCard> createState() => _ExplainCardState();
}

class _ExplainCardState extends State<ExplainCard> {
  Future<String?>? _number;

  _Term? get _term {
    final t = (widget.term ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9/ ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    for (final g in _glossary) {
      if (g.keys.any((k) => t == k)) return g;
    }
    for (final g in _glossary) {
      if (g.keys.any((k) => t.contains(k) || k.contains(t))) return g;
    }
    return null;
  }

  Future<String?> _yourNumber(_Term g) async {
    final s = widget.scrip;
    try {
      if (g.needsStock) {
        if (s == null) return null;
        final f = await _facts(s);
        final r = f.ratios;
        if (r == null) return null;
        return switch (g.title) {
          'P/E ratio' => r.peRatio == 0 ? null : '${s.symbol} trades at a P/E of ${r.peRatio.toStringAsFixed(1)}${r.industryPe == 0 ? '' : ', against an industry P/E of ${r.industryPe}'}.',
          'P/B ratio' => r.pbRatio == 0 ? null : '${s.symbol}\'s P/B is ${r.pbRatio.toStringAsFixed(2)}${r.bookValue == 0 ? '' : ' on a book value of ₹${r.bookValue.toStringAsFixed(1)} a share'}.',
          'Earnings per share' => r.eps == 0 ? null : '${s.symbol} earned ₹${r.eps.toStringAsFixed(2)} a share.',
          'Return on equity' => r.roe == 0 ? null : '${s.symbol}\'s ROE is ${r.roe.toStringAsFixed(1)}%.',
          'Market cap' => r.marketCap == 0 ? null : '${s.symbol}\'s market cap is ₹${NumberFormat.compact(locale: 'en_IN').format(r.marketCap)} crore.',
          'Dividend yield' => r.dividend == 0 ? null : '${s.symbol} pays a dividend of ${r.dividend.toStringAsFixed(2)}.',
          _ => null,
        };
      }
      if (g.title == 'Your overall return') {
        final h = await _holdings();
        final inv = h.fold<double>(0, (a, x) => a + (x.investedValue > 0 ? x.investedValue : x.avgPrice * x.totalQuantity));
        final cur = h.fold<double>(0, (a, x) => a + x.marketValue);
        if (inv <= 0) return null;
        return 'Your stocks: ${_rs(cur)} today against ${_rs(inv)} invested, ${_pct((cur - inv) / inv * 100)} overall.';
      }
    } catch (e) {
      debugPrint('GenUI explain number failed: $e');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final g = _term;
    if (g == null) {
      return CardFrame(
        title: 'Explain',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text((widget.term ?? '').isEmpty ? 'Which term would you like explained?' : 'I do not have "${widget.term}" in my glossary yet. Try one of these:', style: _b(context)),
          MOSpacing.verticalSpace8,
          Wrap(spacing: 6, runSpacing: 6, children: <Widget>[for (final t in _glossary.take(12)) _askChip(context, t.title, 'What is ${t.title}?')]),
        ]),
      );
    }
    return FutureBuilder<String?>(
      future: _number ??= _yourNumber(g),
      builder: (context, snap) => CardFrame(
        title: g.title,
        subtitle: widget.scrip == null ? null : 'For ${widget.scrip!.symbol}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(g.what, style: _b(context)),
          MOSpacing.verticalSpace6,
          Text('How to read it', style: _h(context)),
          Text(g.why, style: _b(context)),
          if (snap.connectionState != ConnectionState.done)
            Padding(padding: MOSpacing.paddingVertical8, child: Text('Looking up your number…', style: _sub(context)))
          else if (snap.data != null) ...<Widget>[
            MOSpacing.verticalSpace8,
            Container(
              padding: MOSpacing.paddingAll12,
              decoration: BoxDecoration(color: context.surfaceBackgroundPrimaryFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
              child: Text(snap.data!, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPrimaryNormal)),
            ),
          ] else if (g.needsStock && widget.scrip == null) ...<Widget>[
            MOSpacing.verticalSpace8,
            Text('Name a stock to see its number, e.g. "explain ${g.title.toLowerCase()} for HDFC Bank".', style: _sub(context)),
          ],
          // The research desk's own words, once we know which number (if any) to hand it.
          if (snap.connectionState == ConnectionState.done)
            ResearchNarrative(
              heading: "Research desk's explanation",
              question: 'Explain "${g.title}" to a retail investor in two or three plain sentences, then one sentence on how to read it.'
                  '${widget.scrip != null ? ' The investor is looking at ${widget.scrip!.name.isEmpty ? widget.scrip!.symbol : widget.scrip!.name} (${widget.scrip!.symbol}).' : ''}'
                  '${snap.data != null ? ' Their number: ${snap.data}' : ''}',
            ),
        ]),
      ),
    );
  }
}

// ============================================================================================
// How should I rebalance?
// ============================================================================================

/// Concentration against simple targets (no stock above 20%, no sector above 35%, some large-cap
/// weight), with rupee amounts to trim or add. Rules, not advice; the research desk's view sits in
/// the risk card.
class RebalanceCard extends StatefulWidget {
  const RebalanceCard({super.key});
  static const double maxStock = 2000; // bps
  static const double maxSector = 3500;
  static const double minLargeCap = 4000;

  @override
  State<RebalanceCard> createState() => _RebalanceCardState();
}

class _RebalanceCardState extends State<RebalanceCard> {
  Future<StockAnalysisDashboardResponse>? _future;

  @override
  Widget build(BuildContext context) => FutureBuilder<StockAnalysisDashboardResponse>(
        future: _future ??= PortfolioAnalysisRepositoryImpl().fetchStocksAnalysisDashboard(AnalysisType.mofsl, null),
        builder: (context, snap) => CardFrame(
          title: 'How should I rebalance?',
          subtitle: 'Simple targets: no stock above 20%, no sector above 35%, at least 40% large cap',
          onRefresh: () => setState(() => _future = null),
          child: snap.hasError
              ? _err(context, snap.error!)
              : !snap.hasData
                  ? _spin
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, StockAnalysisDashboardResponse s) {
    final total = s.stock.entry.fold<double>(0, (a, e) => a + e.marketValue.toInt()) / 100;
    if (total <= 0) return _note(context, 'The analysis API returned no holdings to rebalance.');
    final actions = <(String, String, String?)>[]; // (headline, detail, ask)
    for (final e in s.stock.entry) {
      if (e.allocation > RebalanceCard.maxStock) {
        final trim = (e.allocation - RebalanceCard.maxStock) / 10000 * total;
        actions.add(('Trim ${e.label}', '${(e.allocation / 100).toStringAsFixed(1)}% of your stocks. Selling about ${_rs(trim)} brings it to 20%.', 'Sell ${e.label}'));
      }
    }
    for (final e in s.sector.entry) {
      if (e.allocation > RebalanceCard.maxSector) {
        actions.add(('Lighten ${e.label}', '${(e.allocation / 100).toStringAsFixed(1)}% in one sector. Add to other sectors before adding here.', null));
      }
    }
    final large = s.marketcap.entry.cast<dynamic>().firstWhere((e) => e.label.toString().toLowerCase().contains('large'), orElse: () => null);
    if (large != null && large.allocation < RebalanceCard.minLargeCap) {
      final add = (RebalanceCard.minLargeCap - large.allocation) / 10000 * total;
      actions.add(('Add large caps', 'Only ${(large.allocation / 100).toStringAsFixed(1)}% is large cap. About ${_rs(add)} more would take it to 40%.', 'Best large cap funds'));
    }
    final under = s.sector.entry.where((e) => e.allocation < 500).map((e) => e.label).take(3).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(actions.isEmpty ? 'Nothing to rebalance: every stock and sector is inside the targets.' : '${actions.length} move${actions.length == 1 ? '' : 's'} would bring you inside the targets.',
          style: MOTypography.bodyMediumSemibold.copyWith(color: actions.isEmpty ? context.surfaceTextPositiveNormal : context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace6,
      for (final a in actions)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(a.$1, style: _h(context)),
            Text(a.$2, style: _sub(context)),
            if (a.$3 != null) Padding(padding: const EdgeInsets.only(top: 4), child: _askChip(context, a.$3!, a.$3!)),
          ]),
        ),
      const Divider(height: 20),
      Text('Where you stand', style: _h(context)),
      for (final e in (<dynamic>[...s.stock.entry]..sort((a, b) => (b.allocation as num).compareTo(a.allocation as num))).take(6))
        _bar(context, e.label as String, (e.allocation as num) / 100, RebalanceCard.maxStock / 100),
      if (under.isNotEmpty) _note(context, 'Thin or missing sectors: ${under.join(', ')}.'),
      _note(context, 'Targets are a common rule of thumb. The research desk\'s suggestions follow.'),
      ResearchNarrative(
        heading: "Research desk's suggestions",
        question: 'My stock portfolio is worth ${_rs(total)}. Allocation by stock: ${_alloc(s.stock.entry)}. By sector: ${_alloc(s.sector.entry)}. By market cap: ${_alloc(s.marketcap.entry)}. '
            'Give three short, specific suggestions on how to rebalance it, as a bulleted list, without naming specific stocks to buy.',
      ),
    ]);
  }

  static String _alloc(Iterable<dynamic> entries) => entries.map((e) => '${e.label} ${((e.allocation as num) / 100).toStringAsFixed(1)}%').take(8).join(', ');

  Widget _bar(BuildContext context, String label, double pct, double limit) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: <Widget>[
          SizedBox(width: 110, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _sub(context))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: (pct / 50).clamp(0, 1).toDouble(), minHeight: 8, backgroundColor: context.surfaceBackgroundNeutralFaded, color: pct > limit ? context.surfaceTextNegativeNormal : context.surfaceTextPrimaryNormal),
            ),
          ),
          MOSpacing.horizontalSpace8,
          SizedBox(width: 44, child: Text('${pct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: MOTypography.bodyXsmallSemibold.copyWith(color: pct > limit ? context.surfaceTextNegativeNormal : context.surfaceTextNeutralNormal))),
        ]),
      );
}

// ============================================================================================
// Plan a goal (SIP calculator)
// ============================================================================================

/// "I want ₹50 lakh in 10 years": the monthly SIP that gets there, or what a monthly amount grows
/// to, at a chosen return. Pure arithmetic, then a chip to pick a fund.
class GoalCard extends StatefulWidget {
  const GoalCard({super.key, this.target, this.years, this.monthly, this.rate, this.name});
  final num? target;
  final num? years;
  final num? monthly;
  final num? rate;
  final String? name;

  @override
  State<GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends State<GoalCard> {
  late double _years = (widget.years ?? 10).toDouble().clamp(1, 40);
  late double _rate = (widget.rate ?? 12).toDouble().clamp(1, 30);
  late double? _target = widget.target?.toDouble();
  late double? _monthly = widget.monthly?.toDouble();

  double _factor() {
    final r = _rate / 100 / 12;
    final n = (_years * 12).round();
    return (math.pow(1 + r, n) - 1) / r * (1 + r);
  }

  @override
  Widget build(BuildContext context) {
    final f = _factor();
    final toCorpus = _target == null && _monthly != null;
    final monthly = toCorpus ? _monthly! : (_target ?? 5000000) / f;
    final corpus = toCorpus ? _monthly! * f : (_target ?? 5000000);
    final invested = monthly * _years * 12;
    return CardFrame(
      title: widget.name == null || widget.name!.isEmpty ? 'Plan a goal' : 'Goal: ${widget.name}',
      subtitle: toCorpus ? 'What ${_rs(monthly)} a month grows to' : 'The monthly SIP that reaches ${_rs(corpus)}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: _kv(context, 'Monthly SIP', _rs(monthly), big: !toCorpus)),
          Expanded(child: _kv(context, 'In ${_years.round()} years', _rs(corpus), big: toCorpus)),
        ]),
        MOSpacing.verticalSpace6,
        Text('You would put in ${_rs(invested)} and the growth at $_rate% a year would add ${_rs(corpus - invested)}.', style: _sub(context)),
        MOSpacing.verticalSpace8,
        Text('Years', style: _sub(context)),
        Wrap(children: <Widget>[for (final y in const <double>[3, 5, 10, 15, 20]) _chip(context, '${y.round()}', selected: _years == y, onTap: () => setState(() => _years = y))]),
        MOSpacing.verticalSpace4,
        Text('Expected return a year', style: _sub(context)),
        Wrap(children: <Widget>[for (final r in const <double>[8, 10, 12, 15]) _chip(context, '$r%', selected: _rate == r, onTap: () => setState(() => _rate = r))]),
        MOSpacing.verticalSpace8,
        Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
          _askChip(context, 'Pick a fund for this SIP', 'Best ${_years >= 7 ? 'flexi cap' : 'large cap'} funds'),
          _askChip(context, 'My SIPs', 'Show my SIPs'),
        ]),
        _note(context, '12% is a long-run equity assumption, not a promise; 8% is closer to debt. Inflation is not deducted.'),
      ]),
    );
  }

  Widget _kv(BuildContext c, String k, String v, {bool big = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(k, style: _sub(c)),
        Text(v, style: (big ? MOTypography.headingMedium : MOTypography.bodyMediumSemibold).copyWith(color: big ? c.surfaceTextPrimaryNormal : c.surfaceTextNeutralNormal)),
      ]);
}

// ============================================================================================
// What's coming up / failed SIPs
// ============================================================================================

class _Soon {
  const _Soon(this.when, this.what, this.detail, {this.ask});
  final DateTime when;
  final String what;
  final String detail;
  final String? ask;
}

DateTime? _parseDate(String s) {
  if (s.trim().isEmpty) return null;
  for (final f in <String>['dd-MM-yyyy', 'dd/MM/yyyy', 'yyyy-MM-dd', 'dd MMM yyyy', 'MM/dd/yyyy', 'dd-MMM-yyyy']) {
    try {
      return DateFormat(f).parseStrict(s.trim().split(' ').take(f.split(' ').length).join(' '));
    } catch (_) {}
  }
  return DateTime.tryParse(s);
}

/// SIP debits, ex-dates and record dates on the user's stocks, in date order.
class UpcomingCard extends StatefulWidget {
  const UpcomingCard({super.key, this.days});
  final num? days;

  @override
  State<UpcomingCard> createState() => _UpcomingCardState();
}

class _UpcomingCardState extends State<UpcomingCard> {
  Future<List<_Soon>>? _future;

  Future<List<_Soon>> _load() async {
    final out = <_Soon>[];
    final now = DateTime.now();
    final horizon = now.add(Duration(days: (widget.days ?? 30).toInt()));
    Future<void> safe(Future<void> f) => f.catchError((Object e) => debugPrint('GenUI upcoming: $e'));
    await Future.wait(<Future<void>>[
      safe(() async {
        for (final h in await _holdings()) {
          if (h.sipNextInstallmentDate > 0 && h.sipInstallmentAmt > 0) {
            out.add(_Soon(DateTime.fromMillisecondsSinceEpoch(h.sipNextInstallmentDate * 1000), 'Stock SIP · ${h.tradeSymbol}', '${_rs(h.sipInstallmentAmt)} instalment', ask: 'My stock SIPs'));
          }
        }
      }()),
      safe(() async {
        final book = await TransactionTypeRepositoryImpl().getCommonOrderBook('SIP', 'SUCCESSFUL', 50);
        for (final OrderBookResponseModel o in book.data ?? const <OrderBookResponseModel>[]) {
          final d = _parseDate(o.dueDate);
          if (d != null) out.add(_Soon(d, 'Fund SIP · ${o.schemeName}', '₹${o.amount}${o.sipFrequency.isEmpty ? '' : ' · ${o.sipFrequency}'}', ask: 'Show my SIPs'));
        }
      }()),
      safe(() async {
        final ev = await MoPortfolioDashBoardRepositoryImpl().getUpcomingEventsAPI();
        for (final UpcomingEventEntry e in ev.upcoming) {
          final ex = e.exDate;
          if (ex != 0) {
            final d = DateTime.fromMillisecondsSinceEpoch(ex > 100000000000 ? ex : ex * 1000);
            out.add(_Soon(d, '${e.corpActionType} · ${e.tradeSymbol}', '${e.amount != 0 ? '₹${e.amount} ' : ''}ex-date ${_date(ex)}${e.recordDate != 0 ? ', record ${_date(e.recordDate)}' : ''}', ask: 'Any dividends coming?'));
          }
        }
      }()),
    ]);
    out.sort((a, b) => a.when.compareTo(b.when));
    return out.where((s) => !s.when.isBefore(DateTime(now.year, now.month, now.day)) && !s.when.isAfter(horizon)).toList();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<_Soon>>(
        future: _future ??= _load(),
        builder: (context, snap) => CardFrame(
          title: "What's coming up",
          subtitle: 'Next ${(widget.days ?? 30).toInt()} days: SIP debits and corporate actions on your stocks',
          onRefresh: () => setState(() => _future = null),
          child: snap.hasError
              ? _err(context, snap.error!)
              : !snap.hasData
                  ? _spin
                  : snap.data!.isEmpty
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          _note(context, 'Nothing scheduled in the next ${(widget.days ?? 30).toInt()} days: no SIP debits and no ex-dates on your stocks.'),
                          Wrap(spacing: 8, runSpacing: 6, children: <Widget>[_askChip(context, 'Upcoming IPOs', 'Upcoming IPOs'), _askChip(context, 'Start a SIP', 'Best large cap funds')]),
                        ])
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          for (final s in snap.data!)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: AdaptiveRow(
                                start: SizedBox(width: 56, child: Text(DateFormat('d MMM').format(s.when), style: _h(context))),
                                leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                  Text(s.what, maxLines: 1, overflow: TextOverflow.ellipsis, style: _b(context)),
                                  Text(s.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: _sub(context)),
                                ]),
                                trailing: s.ask == null ? const SizedBox.shrink() : InkWell(onTap: () => GenUiNav.ask(s.ask!), child: Icon(Icons.chevron_right, size: 18, color: context.surfaceIconNeutralNormal)),
                              ),
                            ),
                        ]),
        ),
      );
}

/// SIP instalments that failed or were rejected, with a way to pay the missed one.
class FailedSipsCard extends StatefulWidget {
  const FailedSipsCard({super.key});

  @override
  State<FailedSipsCard> createState() => _FailedSipsCardState();
}

class _FailedSipsCardState extends State<FailedSipsCard> {
  Future<List<OrderBookResponseModel>>? _future;

  Future<List<OrderBookResponseModel>> _load() async {
    final repo = TransactionTypeRepositoryImpl();
    final out = <OrderBookResponseModel>[];
    bool bad(String s) => s.toUpperCase().contains('FAIL') || s.toUpperCase().contains('REJECT');
    for (final status in const <String>['REJECTED', 'SUCCESSFUL']) {
      try {
        final book = await repo.getCommonOrderBook('SIP', status, 50);
        for (final o in book.data ?? const <OrderBookResponseModel>[]) {
          if (status == 'REJECTED' || bad(o.paymentStatus) || bad(o.status)) {
            if (!out.any((x) => x.transactionID == o.transactionID)) out.add(o);
          }
        }
      } catch (e) {
        if (!'$e'.toLowerCase().contains('no data')) rethrow;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<OrderBookResponseModel>>(
        future: _future ??= _load(),
        builder: (context, snap) => CardFrame(
          title: 'Failed SIP payments',
          subtitle: 'Instalments rejected, unpaid or never initiated, from your MF order book',
          onRefresh: () => setState(() => _future = null),
          child: snap.hasError
              ? _err(context, snap.error!)
              : !snap.hasData
                  ? _spin
                  : snap.data!.isEmpty
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('No failed SIP payments. Every instalment on record went through.', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
                          MOSpacing.verticalSpace6,
                          _askChip(context, 'Show my SIPs', 'Show my SIPs'),
                        ])
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          for (final o in snap.data!)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                AdaptiveRow(
                                  leading: Text(o.schemeName, maxLines: 2, overflow: TextOverflow.ellipsis, style: _h(context)),
                                  trailing: Text('₹${o.amount}', style: _h(context)),
                                ),
                                Text('${o.transactionDate.isEmpty ? '' : '${o.transactionDate} · '}${o.paymentStatus.isEmpty ? o.status : o.paymentStatus}${o.remarksBseremarks.isEmpty ? '' : ' · ${o.remarksBseremarks}'}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNegativeNormal)),
                                Padding(padding: const EdgeInsets.only(top: 4), child: _askChip(context, 'Pay this instalment now', 'Invest ₹${o.amount} lumpsum in ${o.schemeName}')),
                              ]),
                            ),
                          _note(context, 'A failed instalment is usually a bank balance or mandate issue; the next one is attempted on the due date.'),
                        ]),
        ),
      );
}
