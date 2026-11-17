import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_portfolio_2_0/data/mo_portfolio_dashboard_repository_impl.dart';
import 'package:mo_portfolio_2_0/domain/mo_portfolio_dashboard_model/equity_detail_response.dart';
import 'package:mo_portfolio_2_0/domain/mo_portfolio_dashboard_repository.dart';
import 'package:mo_portfolio_2_0/utils/mo_portfolio_formatter.dart';
import 'package:mo_portfolio_analysis/data/portfolio_analysis_repository_impl.dart';
import 'package:mo_portfolio_analysis/utils/enums.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioAnalysisCommon.pb.dart' show Benchmark;
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioRevamp.pb.dart';
import 'package:trader_proto_gen/PortfolioRevamp/UsEquity.pb.dart';

/// "How is my portfolio doing?" and everything under it.
///
/// Views: `summary` (totals + one tappable row per asset class), `stocks`,
/// `funds`, `bonds`, `us` (full holdings lists from the same Detail APIs the
/// Portfolio tab uses, stocks with live prices), `chart` (invested vs current
/// per asset class) and `trend` (lines: my stocks, my mutual funds and a
/// Nifty benchmark over a period, from the Portfolio Analysis benchmark API,
/// each rebased to 100 so they can be compared).
class PortfolioCard extends StatefulWidget {
  const PortfolioCard({super.key, this.section, this.view, this.repository});

  /// Optional focus: `equity`/`stocks`, `mf`/`funds`, `bonds`, `us`, `all`.
  final String? section;
  final String? view;
  final MoPortfolioDashboardRepository? repository;

  static const List<String> views = <String>['summary', 'stocks', 'funds', 'bonds', 'us', 'chart', 'trend'];

  static String? viewForSection(String? s) => switch ((s ?? '').toLowerCase()) {
        'equity' || 'stocks' || 'stock' => 'stocks',
        'mf' || 'funds' || 'mutual funds' => 'funds',
        'bonds' || 'bond' => 'bonds',
        'us' || 'us stocks' => 'us',
        _ => null,
      };

  @override
  State<PortfolioCard> createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  MoPortfolioDashboardRepository get _repo => widget.repository ?? MoPortfolioDashBoardRepositoryImpl();
  late Future<PortfolioDashboardResponse> _future = _load();
  late String _view = PortfolioCard.views.contains(widget.view) ? widget.view! : (PortfolioCard.viewForSection(widget.section) ?? 'summary');
  final Map<String, Future<dynamic>> _details = <String, Future<dynamic>>{};

  Future<PortfolioDashboardResponse> _load({bool force = false}) => _repo.getPortfolioAllTabAPI(forceRefresh: force);

  Future<dynamic> _detail(String view) => _details.putIfAbsent(view, () {
        switch (view) {
          case 'stocks':
            return _repo.getEquityDetailAPI(loadFromCache: false);
          case 'funds':
            return _repo.getMfDetailAPI(loadFromCache: false);
          case 'bonds':
            return _repo.getBondsDataAPI();
          case 'us':
            return _repo.getUsEquityDetailAPI(loadFromCache: false);
        }
        return Future<dynamic>.value(null);
      });

  void _retry() => setState(() {
        _future = _load(force: true);
        _details.remove(_view);
      });

  @override
  Widget build(BuildContext context) {
    return CardFrame(
      title: switch (_view) { 'stocks' => 'My stocks', 'funds' => 'My mutual funds', 'bonds' => 'My bonds', 'us' => 'My US stocks', 'trend' => 'Portfolio vs benchmark', _ => 'My portfolio' },
      views: PortfolioCard.views,
      view: _view,
      live: _view == 'stocks',
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: _retry,
      child: _view == 'trend'
          ? const _TrendView()
          : FutureBuilder<PortfolioDashboardResponse>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching your portfolio…');
                if (snap.hasError || !snap.hasData) {
                  return CardError(title: "Couldn't load your portfolio.", message: '${snap.error ?? 'No data'}', onRetry: _retry);
                }
                final r = snap.data!;
                final assets = _assets(r);
                if (_view == 'summary') {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _Summary(summary: r.summary),
                      MOSpacing.verticalSpace12,
                      Divider(height: 1, color: context.surfaceBorderNeutralNormal),
                      MOSpacing.verticalSpace4,
                      for (final a in assets) _AssetRow(asset: a, onTap: a.view == null ? null : () => setState(() => _view = a.view!)),
                      Text('Tap an asset to see every holding. "Trend" compares stocks, funds and Nifty over time.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    ],
                  );
                }
                if (_view == 'chart') return _AllocationChart(assets: assets);
                return FutureBuilder<dynamic>(
                  future: _detail(_view),
                  builder: (context, ds) {
                    if (ds.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching holdings…');
                    if (ds.hasError || ds.data == null) return CardError(title: "Couldn't load holdings.", message: '${ds.error ?? 'No data'}', onRetry: _retry);
                    return switch (_view) {
                      'stocks' => _StocksList(data: ds.data as EquityDetailResponse),
                      'funds' => _FundsList(data: ds.data as PortfolioMfResponse),
                      'bonds' => _BondsList(data: ds.data as PortfolioBondResponse),
                      'us' => _UsList(data: ds.data as UsEquityHoldingResponse),
                      _ => const SizedBox.shrink(),
                    };
                  },
                );
              },
            ),
    );
  }

  static List<_Asset> _assets(PortfolioDashboardResponse r) {
    final a = r.assets;
    return <_Asset>[
      if (a.hasEquity()) _Asset.of(a.equity, 'Stocks', view: 'stocks'),
      if (a.hasMf()) _Asset.of(a.mf, 'Mutual Funds', view: 'funds'),
      if (a.hasBonds() && a.bonds.marketValue.toInt() != 0) _Asset(name: 'Bonds', invested: a.bonds.investedValue.toInt(), market: a.bonds.marketValue.toInt(), day: a.bonds.daysChange.toInt(), overall: a.bonds.overallChange.toInt(), view: 'bonds'),
      if (a.hasUsEquity() && a.usEquity.marketValue.toInt() != 0) _Asset(name: 'US stocks', invested: a.usEquity.investedValue.toInt(), market: a.usEquity.marketValue.toInt(), day: a.usEquity.daysChange.toInt(), overall: a.usEquity.overallChange.toInt(), view: 'us'),
      if (a.hasBasket() && a.basket.marketValue.toInt() != 0) _Asset.of(a.basket, 'Baskets'),
      if (a.hasPms() && a.pms.marketValue.toInt() != 0) _Asset.of(a.pms, 'PMS'),
      if (a.hasAif() && a.aif.marketValue.toInt() != 0) _Asset.of(a.aif, 'AIF'),
      if (a.hasNonTradable() && a.nonTradable.marketValue.toInt() != 0) _Asset.nonTradable(a.nonTradable),
    ];
  }
}

/// Small view model so every asset class renders alike.
class _Asset {
  const _Asset({required this.name, required this.invested, required this.market, required this.day, required this.overall, this.hasDay = true, this.view});
  final String name;
  final int invested; // paise
  final int market;
  final int day;
  final int overall;
  final bool hasDay;
  final String? view;

  factory _Asset.of(PortfolioAssetV2 a, String fallbackName, {String? view}) => _Asset(
        name: a.name.isEmpty ? fallbackName : a.name,
        invested: a.investedValue.toInt(),
        market: a.marketValue.toInt(),
        day: a.daysChange.toInt(),
        overall: a.overallChange.toInt(),
        view: view,
      );

  factory _Asset.nonTradable(NonTradableSummary n) => _Asset(name: 'Non-tradable', invested: n.investedValue.toInt(), market: n.marketValue.toInt(), day: 0, overall: n.overallChange.toInt(), hasDay: false);
}

class _Summary extends StatelessWidget {
  const _Summary({required this.summary});
  final PortfolioOverallSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(_rupees(s.currentValue.toInt()), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextNeutralNormal)),
        MOSpacing.verticalSpace4,
        Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing4, children: <Widget>[
          _Delta(label: 'Today', paise: s.daysChange.toInt(), bps: s.daysChangePer),
          _Delta(label: 'Overall', paise: s.overallChange.toInt(), bps: s.overallChangePer),
        ]),
        MOSpacing.verticalSpace4,
        Text('Invested ${_rupees(s.investedValue.toInt())}${s.ledgerBalance.toInt() != 0 ? ' · Ledger ${_rupees(s.ledgerBalance.toInt())}' : ''}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
      ],
    );
  }
}

// ----------------------------------------------------------------- holdings

class _StocksList extends StatelessWidget {
  const _StocksList({required this.data});
  final EquityDetailResponse data;

  @override
  Widget build(BuildContext context) {
    final rows = data.holdings;
    if (rows.isEmpty) return Text('No stock holdings.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text('${rows.length} stocks', style: sub),
      for (final h in rows)
        Builder(builder: (context) {
          Widget row(double ltp, double dayPct) {
            final market = h.totalQuantity * (ltp > 0 ? ltp : h.ltp);
            final invested = h.investedValue > 0 ? h.investedValue : h.avgPrice * h.totalQuantity;
            final pnl = market - invested;
            final pct = invested == 0 ? 0.0 : pnl / invested * 100;
            final symbol = Text(h.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal));
            final detail = Text('${h.totalQuantity} × avg ₹${_n(h.avgPrice)}${ltp > 0 ? ' · LTP ₹${_n(ltp)}' : ''}${h.mtfQty > 0 ? ' · MTF ${h.mtfQty}' : ''}${h.pledgedQty > 0 ? ' · pledged ${h.pledgedQty}' : ''}', style: sub);
            final value = Text('₹${_n(market)}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal));
            final delta = Text('${pnl < 0 ? '−' : '+'}₹${_n(pnl.abs())} (${pct.toStringAsFixed(1)}%)${dayPct != 0 ? ' · ${pct2(dayPct)} today' : ''}', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, pnl)));
            final body = CardLayout.narrowOf(context)
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[symbol, value, delta, detail])
                : AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[symbol, detail]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[value, delta]));
            return InkWell(
              onTap: h.scripId == null ? null : () => GenUiNav.openStock(GenUiNav.refOf(h.scripId!, h.tradeSymbol, h.companyName)),
              child: Padding(padding: MOSpacing.paddingVertical6, child: body),
            );
          }
          final id = h.scripId;
          if (id == null || id.scripCode == 0) return row(h.ltp, h.daysChangePercent);
          return LivePrice.scrip(scrip: id, builder: (context, t) => row(t != null && t.ltp > 0 ? t.ltp : h.ltp, t != null && t.ltp > 0 ? t.perChange : h.daysChangePercent));
        }),
      if (data.unlistedHoldings.isNotEmpty) Text('+ ${data.unlistedHoldings.length} unlisted holdings', style: sub),
    ]);
  }

  String pct2(double v) => '${v < 0 ? '' : '+'}${v.toStringAsFixed(2)}%';
}

class _FundsList extends StatelessWidget {
  const _FundsList({required this.data});
  final PortfolioMfResponse data;

  @override
  Widget build(BuildContext context) {
    final rows = data.entry;
    if (rows.isEmpty) return Text('No mutual fund holdings.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text('${rows.length} funds · ${_rupees(data.summary.marketValue.toInt())} (${_signed(data.summary.overallChange.toInt())})', style: sub),
      for (final f in rows)
        InkWell(
          onTap: f.isin.isEmpty ? null : () => GenUiNav.openFund(FundRef(isin: f.isin, name: f.schemeName)),
          child: Padding(
          padding: MOSpacing.paddingVertical6,
          child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(f.schemeName, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text('${(f.units.toInt() / 1000).toStringAsFixed(3)} units · avg NAV ₹${_n(f.avgNav.toInt() / 100)}${f.sip.marketValue.toInt() != 0 ? ' · SIP' : ''}${f.lumpsum.xirr != 0 || f.sip.xirr != 0 ? ' · XIRR ${((f.sip.xirr != 0 ? f.sip.xirr : f.lumpsum.xirr) / 100).toStringAsFixed(1)}%' : ''}', style: sub),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text(_rupees(f.marketValue.toInt()), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text('${_signed(f.marketValue.toInt() - f.investedValue.toInt())} · today ${_signed(f.dayChange.toInt())}', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, f.marketValue.toInt() - f.investedValue.toInt()))),
            ])),
        ),
        ),
    ]);
  }
}

class _BondsList extends StatelessWidget {
  const _BondsList({required this.data});
  final PortfolioBondResponse data;

  @override
  Widget build(BuildContext context) {
    final rows = data.holdings;
    if (rows.isEmpty) return Text('No bond holdings.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(children: <Widget>[
      for (final b in rows)
        Padding(
          padding: MOSpacing.paddingVertical6,
          child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(b.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text('${b.totalQuantity} × ₹${_n(b.avgPrice.toInt() / 100)}${b.rating.isEmpty ? '' : ' · ${b.rating}'}${b.maturity.isEmpty ? '' : ' · matures ${b.maturity}'}', style: sub),
            ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text(_rupees(b.currentValue.toInt()), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text(_signed(b.currentValue.toInt() - b.investedValue.toInt()), style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, b.currentValue.toInt() - b.investedValue.toInt()))),
            ])),
        ),
    ]);
  }
}

class _UsList extends StatelessWidget {
  const _UsList({required this.data});
  final UsEquityHoldingResponse data;

  @override
  Widget build(BuildContext context) {
    final rows = data.entry;
    if (rows.isEmpty) return Text('No US stock holdings.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(children: <Widget>[
      for (final u in rows)
        Padding(
          padding: MOSpacing.paddingVertical6,
          child: Builder(builder: (context) {
            final qty = u.availableQty.toInt() / 10000;
            final px = (u.ltp.toInt() != 0 ? u.ltp : u.marketPrice).toInt() / 100;
            final avg = u.avgPrice.toInt() / 100;
            final pnl = (px - avg) * qty;
            return AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(u.symbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text('${u.stockName} · ${qty.toStringAsFixed(4)} × \$${_n(avg)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                Text('\$${_n(px * qty)}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text('${pnl < 0 ? '−' : '+'}\$${_n(pnl.abs())}', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, pnl))),
              ]));
          }),
        ),
    ]);
  }
}

// -------------------------------------------------------------------- trend

/// Lines: my stocks, my mutual funds and the benchmark, rebased to 100.
class _TrendView extends StatefulWidget {
  const _TrendView();

  @override
  State<_TrendView> createState() => _TrendViewState();
}

class _Series {
  _Series(this.label, this.points);
  final String label;
  final List<MapEntry<DateTime, double>> points; // value in rupees (or index level)
}

class _TrendViewState extends State<_TrendView> {
  static const List<String> periods = <String>['1M', '3M', '6M', '1Y', '3Y', '5Y'];
  static const Map<String, String> benchmarks = <String, String>{'NIFTY50': 'Nifty 50', 'NIFTY100': 'Nifty 100', 'NIFTY500': 'Nifty 500'};
  String _period = '1Y';
  String _benchmark = 'NIFTY50';
  bool _showStocks = true, _showFunds = true, _showBench = true;
  Future<List<_Series>>? _future;

  int get _months => switch (_period) { '1M' => 1, '3M' => 3, '6M' => 6, '3Y' => 36, '5Y' => 60, _ => 12 };

  Future<List<_Series>> _load() async {
    final repo = PortfolioAnalysisRepositoryImpl();
    final fmt = DateFormat('MM/dd/yyyy HH:mm:ss');
    DateTime parse(String s) {
      try {
        return fmt.parse(s);
      } catch (_) {
        return DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    Future<Benchmark?> fetch(AnalysisSubTabType t) => repo.fetchBenchMarkPerformanceTrend(_months, _benchmark, AnalysisType.mofsl.index, t, _period).then<Benchmark?>((b) => b).catchError((Object _) => null);
    final res = await Future.wait(<Future<Benchmark?>>[fetch(AnalysisSubTabType.stocks), fetch(AnalysisSubTabType.mutualFund)]);
    final out = <_Series>[];
    List<MapEntry<DateTime, double>> pts(Benchmark? b, bool bench) => b == null
        ? const <MapEntry<DateTime, double>>[]
        : b.details.map((d) => MapEntry(parse(d.asOfDate), (bench ? d.benchmarkValue : d.portfolioValue).toInt() / 100)).where((e) => e.value > 0).toList()
      ..sort((a, c) => a.key.compareTo(c.key));
    final stocks = pts(res[0], false);
    final funds = pts(res[1], false);
    final bench = pts(res[0] ?? res[1], true);
    if (stocks.isNotEmpty) out.add(_Series('My stocks', stocks));
    if (funds.isNotEmpty) out.add(_Series('My mutual funds', funds));
    if (bench.isNotEmpty) out.add(_Series(benchmarks[_benchmark] ?? _benchmark, bench));
    return out;
  }

  void _reload() => setState(() => _future = null);

  @override
  Widget build(BuildContext context) {
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      SizedBox(
        height: 30,
        child: ListView(scrollDirection: Axis.horizontal, children: <Widget>[
          for (final p in periods) Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: Text(p), selected: _period == p, visualDensity: VisualDensity.compact, onSelected: (_) { _period = p; _reload(); })),
          MOSpacing.horizontalSpace8,
          for (final b in benchmarks.entries) Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: Text(b.value), selected: _benchmark == b.key, visualDensity: VisualDensity.compact, onSelected: (_) { _benchmark = b.key; _reload(); })),
        ]),
      ),
      MOSpacing.verticalSpace6,
      FutureBuilder<List<_Series>>(
        future: _future ??= _load(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching performance trend…');
          final series = snap.data ?? const <_Series>[];
          if (snap.hasError || series.isEmpty) return CardError(title: 'No trend data.', message: '${snap.error ?? 'The analysis API returned no points for this period.'}', onRetry: _reload);
          final colors = <String, Color>{'My stocks': context.actionBackgroundPrimaryDefault, 'My mutual funds': context.feedbackIconWarningNormal, benchmarks[_benchmark] ?? _benchmark: context.surfaceTextNeutralStrong};
          final shown = series.where((s) => (s.label == 'My stocks' && _showStocks) || (s.label == 'My mutual funds' && _showFunds) || (!s.label.startsWith('My') && _showBench)).toList();
          // Rebase every series to 100 at its first point so rupees and index levels share one axis.
          final lines = <LineChartBarData>[];
          double minY = 100, maxY = 100;
          DateTime? t0, t1;
          for (final s in shown) {
            final base = s.points.first.value;
            final spots = <FlSpot>[];
            for (final p in s.points) {
              final v = base == 0 ? 100.0 : p.value / base * 100;
              spots.add(FlSpot(p.key.millisecondsSinceEpoch.toDouble(), v));
              if (v < minY) minY = v;
              if (v > maxY) maxY = v;
              t0 = t0 == null || p.key.isBefore(t0!) ? p.key : t0;
              t1 = t1 == null || p.key.isAfter(t1!) ? p.key : t1;
            }
            lines.add(LineChartBarData(spots: spots, isCurved: false, color: colors[s.label], barWidth: 2, dotData: const FlDotData(show: false)));
          }
          final span = (t1 ?? DateTime.now()).millisecondsSinceEpoch - (t0 ?? DateTime.now()).millisecondsSinceEpoch;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Wrap(spacing: 10, children: <Widget>[
              for (final s in series)
                InkWell(
                  onTap: () => setState(() {
                    if (s.label == 'My stocks') _showStocks = !_showStocks;
                    else if (s.label == 'My mutual funds') _showFunds = !_showFunds;
                    else _showBench = !_showBench;
                  }),
                  child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[s.label], borderRadius: BorderRadius.circular(2))),
                    MOSpacing.horizontalSpace4,
                    Text('${s.label}  ${_growth(s)}', style: sub.copyWith(decoration: shown.contains(s) ? null : TextDecoration.lineThrough)),
                  ]),
                ),
            ]),
            MOSpacing.verticalSpace8,
            SizedBox(
              height: 190,
              child: lines.isEmpty
                  ? Center(child: Text('Nothing selected.', style: sub))
                  : LineChart(LineChartData(
                      minY: minY - 2, maxY: maxY + 2,
                      lineBarsData: lines,
                      gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (v) => FlLine(color: context.surfaceBorderNeutralNormal, strokeWidth: .5)),
                      borderData: FlBorderData(show: false),
                      lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(getTooltipItems: (spots) => spots.map((p) => LineTooltipItem('${DateFormat('d MMM yy').format(DateTime.fromMillisecondsSinceEpoch(p.x.toInt()))}\n${p.y.toStringAsFixed(1)}', MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextStaticWhiteNormal))).toList())),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
                        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 34, getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0), style: sub))),
                        bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22, interval: span <= 0 ? null : span / 3, getTitlesWidget: (v, _) => Text(DateFormat(_months > 12 ? 'MMM yy' : 'd MMM').format(DateTime.fromMillisecondsSinceEpoch(v.toInt())), style: sub))),
                      ),
                    )),
            ),
            Text('Each line starts at 100, so the gap between lines is relative performance over $_period. Source: Portfolio Analysis benchmark trend.', style: sub),
          ]);
        },
      ),
    ]);
  }

  String _growth(_Series s) {
    if (s.points.length < 2 || s.points.first.value == 0) return '';
    final g = (s.points.last.value / s.points.first.value - 1) * 100;
    return '${g < 0 ? '' : '+'}${g.toStringAsFixed(1)}%';
  }
}

// --------------------------------------------------------------- allocation

class _AllocationChart extends StatelessWidget {
  const _AllocationChart({required this.assets});
  final List<_Asset> assets;

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty) return Text('No assets.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final maxV = assets.map((a) => a.invested > a.market ? a.invested : a.market).fold<int>(1, (m, v) => v > m ? v : m) / 100.0;
    final invColor = context.surfaceBackgroundPrimaryStrong;
    final curColor = context.actionBackgroundPrimaryDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: <Widget>[_Legend(color: invColor, text: 'Invested'), MOSpacing.horizontalSpace12, _Legend(color: curColor, text: 'Current')]),
        MOSpacing.verticalSpace8,
        SizedBox(
          height: 170,
          child: BarChart(BarChartData(
            maxY: maxV * 1.15, minY: 0,
            barTouchData: BarTouchData(enabled: false),
            gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: maxV / 2, getDrawingHorizontalLine: (v) => FlLine(color: context.surfaceBorderNeutralNormal, strokeWidth: .5)),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: const AxisTitles(), rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 30, getTitlesWidget: (v, _) => Padding(padding: const EdgeInsets.only(top: 4), child: Text(assets[v.toInt()].name, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))))),
            ),
            barGroups: <BarChartGroupData>[
              for (var i = 0; i < assets.length; i++)
                BarChartGroupData(x: i, barsSpace: 4, barRods: <BarChartRodData>[
                  BarChartRodData(toY: assets[i].invested / 100.0, width: 16, color: invColor, borderRadius: BorderRadius.circular(3)),
                  BarChartRodData(toY: assets[i].market / 100.0, width: 16, color: curColor, borderRadius: BorderRadius.circular(3)),
                ]),
            ],
          )),
        ),
        MOSpacing.verticalSpace8,
        for (final a in assets)
          Text('${a.name}: ${_rupees(a.market)} now vs ${_rupees(a.invested)} invested (${_signed(a.overall)})', style: MOTypography.bodyXsmallRegular.copyWith(color: deltaColor(context, a.overall))),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        MOSpacing.horizontalSpace4,
        Text(text, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
      ]);
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.asset, this.onTap});
  final _Asset asset;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final overallPct = asset.invested == 0 ? 0 : asset.overall * 10000 ~/ asset.invested;
    final name = Text(asset.name, style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal));
    final invested = Text('Invested ${_rupees(asset.invested)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    final market = Text(_rupees(asset.market), style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal));
    final delta = Text('${_signed(asset.overall)} (${_pct(overallPct)})${asset.hasDay ? ' · today ${_signed(asset.day)}' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: deltaColor(context, asset.overall)));
    final chevron = onTap == null ? null : Icon(Icons.chevron_right, size: 18, color: context.surfaceIconNeutralNormal);
    // Half-width card: stack the two columns instead of squeezing them.
    final body = CardLayout.narrowOf(context)
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[Expanded(child: name), if (chevron != null) chevron]),
            market,
            delta,
            invested,
          ])
        : AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[name, invested]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[market, delta]), end: chevron);
    return InkWell(onTap: onTap, child: Padding(padding: MOSpacing.paddingVertical8, child: body));
  }
}

class _Delta extends StatelessWidget {
  const _Delta({required this.label, required this.paise, required this.bps});
  final String label;
  final int paise;
  final int bps;

  @override
  Widget build(BuildContext context) => Text('$label ${_signed(paise)} (${_pct(bps)})', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, paise)));
}

String _rupees(int paise) => MoPortfolioFormatter.formatAmount(paise);
String _signed(int paise) => '${paise < 0 ? '−' : '+'}${MoPortfolioFormatter.formatAmount(paise.abs())}';
String _pct(int bps) => '${bps < 0 ? '−' : '+'}${(bps.abs() / 100).toStringAsFixed(2)}%';
String _n(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
