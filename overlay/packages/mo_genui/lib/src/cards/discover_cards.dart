import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_explore_fno/data/fno_repository_impl.dart' as fno;
import 'package:mo_explore_stock_tab/stock/data/stock_repository_impl.dart';
import 'package:mo_explore_stock_tab/stock_tab_api.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mo_portfolio/domain/holding_repository.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_mtf_hub/domain/mo_mtf_repository.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_broadcaster/models/request_models.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_orders/order_position/domain/net_position_repository.dart';
import 'package:trader_proto_gen/News/NewsResponseModels.pb.dart' as pn;
import 'package:trader_proto_gen/Explore/ExploreModels.pb.dart';
import 'package:trader_proto_gen/Home/HomeModelsV2.pb.dart';
import 'package:trader_proto_gen/Markets/MarketEquityModels.pb.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:trader_proto_gen/TradingCore/TrendlyneModels.pb.dart';
import 'package:trader_report_news/news/data/news_repository_impl.dart';
import 'package:trader_report_news/news/domain/models/news_item.dart';
import 'package:trader_report_news/news/helper/news_constanst.dart';

/// Discovery feeds from the Explore tab's own repositories: best performers,
/// trending, ETFs, FII/DII, market news, MTF stocks and IPOs.

// ----------------------------------------------------------------- shared

/// One stock row with a live price, used by every list below.
class QuoteRow extends StatelessWidget {
  const QuoteRow({super.key, required this.id, required this.symbol, this.name = '', this.trailing, this.fallbackLtp = 0, this.fallbackPct = 0});
  final ScripId id;
  final String symbol;
  final String name;
  final String? trailing;
  final double fallbackLtp;
  final double fallbackPct;

  @override
  Widget build(BuildContext context) => LivePrice.scrip(
        scrip: id,
        builder: (context, t) {
          final ltp = (t?.ltp ?? 0) == 0 ? fallbackLtp : t!.ltp;
          final pc = (t?.ltp ?? 0) == 0 ? fallbackPct : t!.perChange;
          return InkWell(
            onTap: () => GenUiNav.openStock(GenUiNav.refOf(id, symbol, name)),
            child: Padding(
            padding: MOSpacing.paddingVertical6,
            child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(symbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                  if (name.isNotEmpty) Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                Text(ltp == 0 ? '—' : money(ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                Text(trailing ?? (ltp == 0 ? '' : pct(pc)), style: MOTypography.bodyXsmallSemibold.copyWith(color: trailing != null ? context.surfaceTextNeutralStrong : deltaColor(context, pc))),
              ])),
          ),
          );
        },
      );
}

String money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);

void _subscribe(Iterable<ScripId> ids) => subscribeLive(ids.map((s) => BroadcastSymbol.forScrip(scripCode: s.scripCode, exchangeCode: s.exchange.value)));

Widget _empty(BuildContext context, String text) => Text(text, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));

Future<StockDashboardResponseV41> _dashboard(List<String> sections) async {
  final list = await StockRepositoryImpl().getStockDashboardNewWithAWS(sections, false, (_) {});
  return list.first as StockDashboardResponseV41;
}

// --------------------------------------------------------- best performers

class BestPerformersCard extends StatefulWidget {
  const BestPerformersCard({super.key, this.period, this.view});
  final String? period; // 1W 1M 3M 6M YTD 1Y 2Y 5Y 10Y
  final String? view;
  static const List<String> views = <String>['list', 'bars'];
  static const List<String> periods = <String>['1W', '1M', '3M', '6M', 'YTD', '1Y', '2Y', '5Y', '10Y'];

  @override
  State<BestPerformersCard> createState() => _BestPerformersCardState();
}

class _BestPerformersCardState extends State<BestPerformersCard> {
  late String _period = BestPerformersCard.periods.contains((widget.period ?? '').toUpperCase()) ? widget.period!.toUpperCase() : '1Y';
  late String _view = BestPerformersCard.views.contains(widget.view) ? widget.view! : 'list';
  late Future<BestPerformersSection> _future = _load();

  Future<BestPerformersSection> _load() => StockRepositoryImpl().getBestPerformers(period: _period, top: 10);

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'Best performers',
        subtitle: '$_period returns',
        live: true,
        views: BestPerformersCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() { _future = _load(); }),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SizedBox(
            height: 30,
            child: ListView(scrollDirection: Axis.horizontal, children: <Widget>[
              for (final p in BestPerformersCard.periods)
                Padding(
                  padding: EdgeInsets.only(right: MOSpacing.spacing6),
                  child: ChoiceChip(label: Text(p), selected: _period == p, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _period = p; _future = _load(); })),
                ),
            ]),
          ),
          FutureBuilder<BestPerformersSection>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
              final r = snap.data;
              if (snap.hasError || r == null) return CardError(title: "Couldn't load.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _load(); }));
              final rows = r.entries.take(10).toList();
              if (rows.isEmpty) return _empty(context, 'Nothing for this period.');
              _subscribe(rows.map((e) => e.scripId));
              if (_view == 'bars') return _ReturnBars(labels: rows.map((e) => e.stockInfo.tradeSymbol).toList(), values: rows.map((e) => e.returnPercent / 100).toList());
              return Column(children: <Widget>[
                for (final e in rows)
                  QuoteRow(id: e.scripId, symbol: e.stockInfo.tradeSymbol, name: '${e.stockInfo.fullName}${e.stockInfo.sector.isEmpty ? '' : ' · ${e.stockInfo.sector}'}', trailing: '${signed(e.returnPercent / 100)}% $_period'),
              ]);
            },
          ),
        ]),
      );
}

class _ReturnBars extends StatelessWidget {
  const _ReturnBars({required this.labels, required this.values});
  final List<String> labels;
  final List<double> values;

  @override
  Widget build(BuildContext context) {
    final maxAbs = values.fold<double>(1, (a, b) => a > b.abs() ? a : b.abs());
    return SizedBox(
      height: 44.0 * values.length,
      child: RotatedBox(
        quarterTurns: 1,
        child: BarChart(BarChartData(
          maxY: maxAbs * 1.25,
          minY: values.any((v) => v < 0) ? -maxAbs * 1.25 : 0,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(), rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 90, getTitlesWidget: (v, _) => RotatedBox(quarterTurns: -1, child: Text('${labels[v.toInt()]}  ${signed(values[v.toInt()])}%', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))))),
          ),
          barGroups: <BarChartGroupData>[
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(x: i, barRods: <BarChartRodData>[BarChartRodData(toY: values[i], width: 14, color: values[i] >= 0 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal, borderRadius: BorderRadius.circular(3))]),
          ],
        )),
      ),
    );
  }
}

// ---------------------------------------------------------------- trending

class TrendingCard extends StatefulWidget {
  const TrendingCard({super.key, this.kind});
  final String? kind; // searched | traded
  static const List<String> views = <String>['searched', 'traded'];

  @override
  State<TrendingCard> createState() => _TrendingCardState();
}

class _TrendingCardState extends State<TrendingCard> {
  late String _view = TrendingCard.views.contains(widget.kind) ? widget.kind! : 'searched';
  final Map<String, Future<HotStocksV41>> _futures = <String, Future<HotStocksV41>>{};

  Future<HotStocksV41> _load(String v) => _futures.putIfAbsent(v, () => StockRepositoryImpl().getHotStocksByType(v == 'traded' ? HotStockType.mostTraded : HotStockType.mostSearched, Exchange.NSE.value, count: 10));

  @override
  Widget build(BuildContext context) => CardFrame(
        title: _view == 'traded' ? 'Most traded on MO' : 'Most searched on MO',
        live: true,
        views: TrendingCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() => _futures.remove(_view)),
        child: FutureBuilder<HotStocksV41>(
          future: _load(_view),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _futures.remove(_view)));
            final rows = r.stocks.quotes.take(10).toList();
            if (rows.isEmpty) return _empty(context, 'Nothing trending right now.');
            _subscribe(rows.map((q) => q.id));
            return Column(children: <Widget>[for (final q in rows) QuoteRow(id: q.id, symbol: q.tradeSymbol, name: q.description)]);
          },
        ),
      );
}

// -------------------------------------------------------------------- ETFs

class EtfCard extends StatefulWidget {
  const EtfCard({super.key});

  @override
  State<EtfCard> createState() => _EtfCardState();
}

class _EtfCardState extends State<EtfCard> {
  late Future<StockDashboardResponseV41> _future = _dashboard(<String>['EtfsForYou']);

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'ETFs for you',
        live: true,
        onRefresh: () => setState(() { _future = _dashboard(<String>['EtfsForYou']); }),
        child: FutureBuilder<StockDashboardResponseV41>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load ETFs.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _dashboard(<String>['EtfsForYou']); }));
            final rows = r.etfsForYou.entries.take(12).toList();
            if (rows.isEmpty) return _empty(context, 'No ETFs listed.');
            _subscribe(rows.map((e) => e.id));
            return Column(children: <Widget>[
              for (final e in rows) QuoteRow(id: e.id, symbol: e.tradeSymbol, name: '${e.fullName}${e.etfType.isEmpty ? '' : ' · ${e.etfType}'}', trailing: '1Y ${signed(e.oneYearReturn / 100)}%'),
            ]);
          },
        ),
      );
}

// ----------------------------------------------------------------- FII/DII

class FiiDiiCard extends StatefulWidget {
  const FiiDiiCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['chart', 'table'];

  @override
  State<FiiDiiCard> createState() => _FiiDiiCardState();
}

class _FiiDiiCardState extends State<FiiDiiCard> {
  late String _view = FiiDiiCard.views.contains(widget.view) ? widget.view! : 'chart';
  late Future<FiiAndDiiResponse> _future = _load();

  Future<FiiAndDiiResponse> _load() => fno.StockRepositoryImpl().getFnoFiiDiiActivity(top: 10);

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'FII / DII activity',
        subtitle: 'Cash market, net ₹ crore',
        views: FiiDiiCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() { _future = _load(); }),
        child: FutureBuilder<FiiAndDiiResponse>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _load(); }));
            final days = r.cash.day.take(8).toList().reversed.toList();
            if (days.isEmpty) return _empty(context, 'No data.');
            final label = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
            if (_view == 'table') {
              return Column(children: <Widget>[
                Row(children: <Widget>[Expanded(child: Text('Date', style: label)), SizedBox(width: 90, child: Text('FII', textAlign: TextAlign.end, style: label)), SizedBox(width: 90, child: Text('DII', textAlign: TextAlign.end, style: label))]),
                for (final d in days.reversed)
                  Padding(
                    padding: MOSpacing.paddingVertical4,
                    child: Row(children: <Widget>[
                      Expanded(child: Text(_fmtDate(d.date), style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
                      SizedBox(width: 90, child: Text(signed(d.fiiCash), textAlign: TextAlign.end, style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, d.fiiCash)))),
                      SizedBox(width: 90, child: Text(signed(d.diiCash), textAlign: TextAlign.end, style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, d.diiCash)))),
                    ]),
                  ),
              ]);
            }
            final maxAbs = days.map((d) => [d.fiiCash.abs(), d.diiCash.abs()].reduce((a, b) => a > b ? a : b)).fold<double>(1, (a, b) => a > b ? a : b);
            return Column(children: <Widget>[
              SizedBox(
                height: 160,
                child: BarChart(BarChartData(
                  maxY: maxAbs * 1.2, minY: -maxAbs * 1.2,
                  gridData: const FlGridData(show: false), borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(leftTitles: const AxisTitles(), rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (v, _) => Text(_fmtDate(days[v.toInt()].date, short: true), style: label)))),
                  barGroups: <BarChartGroupData>[
                    for (var i = 0; i < days.length; i++)
                      BarChartGroupData(x: i, barsSpace: 2, barRods: <BarChartRodData>[
                        BarChartRodData(toY: days[i].fiiCash, width: 8, color: context.actionBackgroundPrimaryDefault, borderRadius: BorderRadius.circular(2)),
                        BarChartRodData(toY: days[i].diiCash, width: 8, color: context.feedbackIconWarningNormal, borderRadius: BorderRadius.circular(2)),
                      ]),
                  ],
                )),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
                Container(width: 10, height: 10, color: context.actionBackgroundPrimaryDefault), MOSpacing.horizontalSpace4, Text('FII', style: label), MOSpacing.horizontalSpace12,
                Container(width: 10, height: 10, color: context.feedbackIconWarningNormal), MOSpacing.horizontalSpace4, Text('DII', style: label),
              ]),
            ]);
          },
        ),
      );

  String _fmtDate(int d, {bool short = false}) {
    // Server sends yyyyMMdd or epoch seconds.
    DateTime? dt;
    if (d > 19000000 && d < 30000000) dt = DateTime(d ~/ 10000, (d ~/ 100) % 100, d % 100);
    if (d > 1000000000) dt = DateTime.fromMillisecondsSinceEpoch(d < 100000000000 ? d * 1000 : d);
    if (dt == null) return '$d';
    return DateFormat(short ? 'd/M' : 'd MMM').format(dt);
  }
}

// -------------------------------------------------------------------- news

class NewsCard extends StatefulWidget {
  const NewsCard({super.key, this.scope});
  final String? scope; // all | portfolio | global
  static const List<String> views = <String>['all', 'portfolio', 'global'];

  @override
  State<NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<NewsCard> {
  late String _view = NewsCard.views.contains(widget.scope) ? widget.scope! : 'all';
  final Map<String, Future<NewsListResponse>> _futures = <String, Future<NewsListResponse>>{};

  Future<NewsListResponse> _load(String v) => _futures.putIfAbsent(v, () => NewsRepositoryImpl().fetchNewsData(switch (v) { 'portfolio' => NewsChips.portfolio, 'global' => NewsChips.global, _ => NewsChips.all }));

  /// UAT's news feed is often empty. For "my stocks", fall back to the
  /// per-stock news the quote screen shows, for the user's top holdings.
  Future<List<_StockNews>>? _fallback;
  Future<List<_StockNews>> _loadFallback() async {
    final holdings = await getIt<HoldingRepository>().getTopHoldings('');
    final ids = holdings.scrips.map((e) => e.id).where((id) => id.scripCode != 0).take(6).toList();
    if (ids.isEmpty) return const <_StockNews>[];
    final quotes = await getIt<NetPositionRepository>().getQuoteList(ids);
    final repo = MoGetQuoteRepositoryImpl();
    final out = <_StockNews>[];
    await Future.wait(quotes.quotes.map((q) async {
      try {
        final r = await repo.fetchQuoteOverviewData(symbol: q.tradeSymbol.replaceAll('&', '%26'), sections: <String>['News']);
        for (final n in r.news.news.take(3)) {
          out.add(_StockNews(q.tradeSymbol, n));
        }
      } catch (_) {}
    }));
    out.sort((a, b) => b.n.newsDateTime.compareTo(a.n.newsDateTime));
    return out;
  }

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'Market news',
        views: NewsCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() { _futures.remove(_view); _fallback = null; }),
        child: FutureBuilder<NewsListResponse>(
          future: _load(_view),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching news…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load news.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _futures.remove(_view)));
            // A half-width slot gets the top headlines only; full width the longer list.
            final items = r.newsItems.take(CardLayout.narrowOf(context) ? 3 : 8).toList();
            if (items.isEmpty && _view == 'portfolio') {
              return FutureBuilder<List<_StockNews>>(
                future: _fallback ??= _loadFallback(),
                builder: (context, fs) {
                  if (fs.connectionState != ConnectionState.done) return const CardLoading(text: 'Portfolio feed is empty on UAT; checking your top holdings…');
                  final list = fs.data ?? const <_StockNews>[];
                  if (list.isEmpty) return _empty(context, 'No news for your holdings right now.');
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    _empty(context, 'From your top holdings:'),
                    for (final s in list.take(10))
                      Padding(
                        padding: MOSpacing.paddingVertical6,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('${s.symbol} · ${s.n.title}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                          if (s.n.description.isNotEmpty) Text(s.n.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                          if (s.n.newsDateTime != 0) Text(DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(s.n.newsDateTime < 100000000000 ? s.n.newsDateTime * 1000 : s.n.newsDateTime)), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                        ]),
                      ),
                  ]);
                },
              );
            }
            if (items.isEmpty) return _empty(context, 'No news right now (UAT feed is empty). Try "news on HDFC Bank" for a stock.');
            return Column(children: <Widget>[
              for (final n in items)
                Padding(
                  padding: MOSpacing.paddingVertical6,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(n.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                    if (n.description.isNotEmpty) Text(n.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text('${n.sentiment.name} · ${n.newsDateTime == 0 ? '' : DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(n.newsDateTime < 100000000000 ? n.newsDateTime * 1000 : n.newsDateTime))}',
                        style: MOTypography.bodyXsmallSemibold.copyWith(color: n.sentiment.name.toLowerCase().contains('neg') ? context.surfaceTextNegativeNormal : n.sentiment.name.toLowerCase().contains('pos') ? context.surfaceTextPositiveNormal : context.surfaceTextNeutralStrong)),
                  ]),
                ),
            ]);
          },
        ),
      );
}

// --------------------------------------------------------------- MTF stocks

class MtfStocksCard extends StatefulWidget {
  const MtfStocksCard({super.key, this.kind});
  final String? kind; // gainers | losers
  static const List<String> views = <String>['gainers', 'losers'];

  @override
  State<MtfStocksCard> createState() => _MtfStocksCardState();
}

class _MtfStocksCardState extends State<MtfStocksCard> {
  late String _view = MtfStocksCard.views.contains(widget.kind) ? widget.kind! : 'gainers';
  final Map<String, Future<MarketEquityResponse>> _futures = <String, Future<MarketEquityResponse>>{};

  Future<MarketEquityResponse> _load(String v) => _futures.putIfAbsent(v, () => getIt<MoMtfRepository>().moMtfGetStocks(type: v == 'losers' ? 'Losers' : 'Gainers'));

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'Stocks you can buy on MTF',
        subtitle: 'Pay part now, MOSL funds the rest',
        live: true,
        views: MtfStocksCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() => _futures.remove(_view)),
        child: FutureBuilder<MarketEquityResponse>(
          future: _load(_view),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _futures.remove(_view)));
            final rows = r.scrips.take(10).toList();
            if (rows.isEmpty) return _empty(context, 'No MTF stocks listed.');
            _subscribe(rows.map((s) => s.scripId));
            return Column(children: <Widget>[
              for (final s in rows)
                QuoteRow(id: s.scripId, symbol: s.tradeSymbol, name: '${s.stockInfo.fullName}${s.info.mtfPercent > 0 ? ' · pay ${s.info.mtfPercent.toStringAsFixed(0)}%' : ''}', fallbackLtp: s.tick.ltp, fallbackPct: s.tick.perChange),
            ]);
          },
        ),
      );
}

// -------------------------------------------------------------------- IPOs

class IpoCard extends StatefulWidget {
  const IpoCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['open', 'upcoming', 'listed'];

  @override
  State<IpoCard> createState() => _IpoCardState();
}

class _IpoCardState extends State<IpoCard> {
  late String _view = IpoCard.views.contains(widget.view) ? widget.view! : 'open';
  late Future<StockDashboardResponseV41> _future = _dashboard(<String>['Ipos']);

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'IPOs',
        views: IpoCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() { _future = _dashboard(<String>['Ipos']); }),
        child: FutureBuilder<StockDashboardResponseV41>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load IPOs.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _dashboard(<String>['Ipos']); }));
            final list = switch (_view) { 'upcoming' => r.ipos.upcomminglst.ipolist, 'listed' => r.ipos.listedlst.ipolist, _ => r.ipos.currentlst.ipolist };
            if (list.isEmpty) return _empty(context, 'No $_view IPOs.');
            return Column(children: <Widget>[
              for (final i in list.take(8))
                Padding(
                  padding: MOSpacing.paddingVertical6,
                  child: Row(children: <Widget>[
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text(i.companyName, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                        Text('${i.minPrice > 0 ? '₹${i.minPrice}–${i.maxPrice} · ' : ''}${i.minQty > 0 ? 'lot ${i.minQty} · ' : ''}${_epoch(i.issueDate)} – ${_epoch(i.endDate)}${i.ipoStatus.isEmpty ? '' : ' · ${i.ipoStatus}'}',
                            maxLines: 2, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                      ]),
                    ),
                    if (_view == 'listed' && i.listingGain != 0)
                      Text('${signed(i.listingGain)}%', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, i.listingGain)))
                    else if (i.overAllSubscription.isNotEmpty)
                      Text('${i.overAllSubscription}x', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                  ]),
                ),
              Text('Applying to an IPO (UPI mandate) is not in the AI view yet.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            ]);
          },
        ),
      );

  String _epoch(dynamic v) {
    final n = v is int ? v : int.tryParse('$v') ?? 0;
    if (n <= 0) return '';
    return DateFormat('d MMM').format(DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n));
  }
}

class _StockNews {
  const _StockNews(this.symbol, this.n);
  final String symbol;
  final pn.NewsEntry n;
}
