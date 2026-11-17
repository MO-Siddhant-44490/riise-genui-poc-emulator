import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_explore_stock_tab/stock/data/stock_repository_impl.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_broadcaster/models/request_models.dart';
import 'package:trader_proto_gen/Explore/ExploreModels.pb.dart';
import 'package:trader_proto_gen/Markets/MarketEquityModels.pb.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';

/// "How is the market today?" Indices from Explore/Stocks, prices live.
class MarketOverviewCard extends StatefulWidget {
  const MarketOverviewCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['tiles', 'list'];

  @override
  State<MarketOverviewCard> createState() => _MarketOverviewCardState();
}

class _MarketOverviewCardState extends State<MarketOverviewCard> {
  late Future<StockDashboardResponseV41> _future = _load();
  late String _view = MarketOverviewCard.views.contains(widget.view) ? widget.view! : 'tiles';

  Future<StockDashboardResponseV41> _load() async {
    final list = await StockRepositoryImpl().getStockDashboardNewWithAWS(<String>['Indices'], false, (_) {});
    return list.first as StockDashboardResponseV41;
  }

  @override
  Widget build(BuildContext context) {
    return CardFrame(
      live: true,
      title: 'Market today',
      views: MarketOverviewCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: () => setState(() { _future = _load(); }),
      child: FutureBuilder<StockDashboardResponseV41>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching indices…');
          if (snap.hasError || !snap.hasData) {
            return CardError(title: "Couldn't load the market.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _load(); }));
          }
          final indices = snap.data!.indices.index.where((i) => i.hasIndex()).toList();
          if (indices.isEmpty) return Text('No indices configured.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
          if (_view == 'list') {
            return Column(children: <Widget>[for (final i in indices) _IndexRow(info: i)]);
          }
          return Wrap(
            spacing: MOSpacing.spacing8,
            runSpacing: MOSpacing.spacing8,
            children: <Widget>[for (final i in indices) _IndexTile(info: i)],
          );
        },
      ),
    );
  }
}

Widget _indexLive(UserSelectedIndexV2 info, Widget Function(BuildContext, double ltp, double change, double pc) build) {
  final idx = info.index;
  final id = idx.indexId.isNotEmpty ? idx.indexId : idx.index.indexCode.toString();
  return InkWell(
    borderRadius: BorderRadius.circular(MOSpacing.spacing12),
    onTap: () => GenUiNav.openIndex(id, idx.index.exchange.value, info.title.isNotEmpty ? info.title : idx.indexName),
    child: LivePrice.index(
      indexId: id,
      exchangeCode: idx.index.exchange.value,
      builder: (context, t) => build(context, t?.ltp ?? 0, t?.change ?? 0, t?.perChange ?? 0),
    ),
  );
}

class _IndexTile extends StatelessWidget {
  const _IndexTile({required this.info});
  final UserSelectedIndexV2 info;

  @override
  Widget build(BuildContext context) => _indexLive(info, (context, ltp, ch, pc) => Container(
        width: 150,
        padding: MOSpacing.paddingAll12,
        decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(info.title.isNotEmpty ? info.title : info.index.indexName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            Text(ltp == 0 ? '—' : _money(ltp), style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            Text(ltp == 0 ? '' : '${signed(ch)} (${pct(pc)})', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, ch))),
          ],
        ),
      ));
}

class _IndexRow extends StatelessWidget {
  const _IndexRow({required this.info});
  final UserSelectedIndexV2 info;

  @override
  Widget build(BuildContext context) => _indexLive(info, (context, ltp, ch, pc) => Padding(
        padding: MOSpacing.paddingVertical6,
        child: Row(
          children: <Widget>[
            Expanded(child: Text(info.title.isNotEmpty ? info.title : info.index.indexName, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal))),
            Text(ltp == 0 ? '—' : _money(ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            MOSpacing.horizontalSpace8,
            SizedBox(width: 96, child: Text(ltp == 0 ? '' : pct(pc), textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, ch)))),
          ],
        ),
      ));
}

/// Top gainers or losers, as a list or a bar chart.
class MoversCard extends StatefulWidget {
  const MoversCard({super.key, this.kind, this.view});
  final String? kind; // gainers | losers
  final String? view;
  static const List<String> views = <String>['list', 'bars'];

  @override
  State<MoversCard> createState() => _MoversCardState();
}

class _MoversCardState extends State<MoversCard> {
  late final bool _losers = (widget.kind ?? '').toLowerCase().contains('los');
  late Future<MarketEquityResponse> _future = _load();
  late String _view = MoversCard.views.contains(widget.view) ? widget.view! : 'list';

  /// Same two-step the classic Market Movers screen does: load the filter
  /// list, pick the "Top Gainers" / "Top Losers" filter id and its first
  /// group, then ask for that id. The API rejects named types.
  Future<MarketEquityResponse> _load() async {
    final repo = StockRepositoryImpl();
    final filters = await repo.getMarketMoversFilters(Exchange.NSE.value);
    final want = _losers ? 'TOPLOSERS' : 'TOPGAINERS';
    final entry = filters.entries.cast<MarketMoversFilter?>().firstWhere(
          (e) => e!.filterLabel.toUpperCase().replaceAll(' ', '') == want,
          orElse: () => filters.entries.isEmpty ? null : filters.entries.first,
        );
    if (entry == null) throw 'No market-mover filters returned.';
    final group = entry.groups.isEmpty ? null : entry.groups.first.groupName;
    return repo.getMarketMoverInfo('${entry.filterId}', group: group, exchange: Exchange.NSE.name);
  }

  @override
  Widget build(BuildContext context) {
    return CardFrame(
      live: true,
      title: _losers ? 'Top losers' : 'Top gainers',
      views: MoversCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: () => setState(() { _future = _load(); }),
      child: FutureBuilder<MarketEquityResponse>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching movers…');
          if (snap.hasError || !snap.hasData) {
            return CardError(title: "Couldn't load movers.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _load(); }));
          }
          final scrips = snap.data!.scrips.take(8).toList();
          if (scrips.isEmpty) return Text('No movers right now.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
          subscribeLive(scrips.map((s) => BroadcastSymbol.forScrip(scripCode: s.scripId.scripCode, exchangeCode: s.scripId.exchange.value)));
          if (_view == 'bars') return _MoversBars(scrips: scrips);
          return Column(children: <Widget>[for (final s in scrips) _MoverRow(scrip: s)]);
        },
      ),
    );
  }
}

class _MoverRow extends StatelessWidget {
  const _MoverRow({required this.scrip});
  final MarketEquityScrip scrip;

  @override
  Widget build(BuildContext context) => LivePrice.scrip(
        scrip: scrip.scripId,
        builder: (context, t) {
          final ltp = (t?.ltp ?? 0) == 0 ? scrip.tick.ltp : t!.ltp;
          final pc = t == null || t.ltp == 0 ? scrip.tick.perChange : t.perChange;
          final ch = t == null || t.ltp == 0 ? scrip.tick.change : t.change;
          return InkWell(
            onTap: () => GenUiNav.openStock(GenUiNav.refOf(scrip.scripId, scrip.tradeSymbol)),
            child: Padding(
            padding: MOSpacing.paddingVertical6,
            child: AdaptiveRow(
              leading: Text(scrip.tradeSymbol, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                Text(_money(ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                MOSpacing.horizontalSpace8,
                Text('${signed(ch)} (${pct(pc)})', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, ch))),
              ]),
            ),
          ),
          );
        },
      );
}

class _MoversBars extends StatelessWidget {
  const _MoversBars({required this.scrips});
  final List<MarketEquityScrip> scrips;

  @override
  Widget build(BuildContext context) {
    final maxAbs = scrips.map((s) => s.tick.perChange.abs()).fold<double>(1, (a, b) => a > b ? a : b);
    final pos = context.surfaceTextPositiveNormal;
    final neg = context.surfaceTextNegativeNormal;
    return SizedBox(
      height: 44.0 * scrips.length,
      child: RotatedBox(
        quarterTurns: 1,
        child: BarChart(
          BarChartData(
            maxY: maxAbs * 1.25,
            minY: scrips.any((s) => s.tick.perChange < 0) ? -maxAbs * 1.25 : 0,
            barTouchData: BarTouchData(enabled: false),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              topTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 90,
                  getTitlesWidget: (v, _) => RotatedBox(
                    quarterTurns: -1,
                    child: Text('${scrips[v.toInt()].tradeSymbol}  ${pct(scrips[v.toInt()].tick.perChange)}',
                        style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, scrips[v.toInt()].tick.perChange))),
                  ),
                ),
              ),
            ),
            barGroups: <BarChartGroupData>[
              for (var i = 0; i < scrips.length; i++)
                BarChartGroupData(x: i, barRods: <BarChartRodData>[
                  BarChartRodData(toY: scrips[i].tick.perChange, width: 14, color: scrips[i].tick.perChange < 0 ? neg : pos, borderRadius: BorderRadius.circular(3)),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
