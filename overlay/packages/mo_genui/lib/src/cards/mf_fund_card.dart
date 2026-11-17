import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/cards/mf_transact_cards.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_mutual_funds/compare/data/compare_mf_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_details/data/mutual_fund_details_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_details/domain/models/know_this_fund_model.dart' hide Data;
import 'package:mo_mutual_funds/mutual_fund_details/domain/models/similar_mutualfund_model.dart' hide Data;
import 'package:mo_mutual_funds/mutual_fund_details/ui/mutual_fund_detail_graph/data/mutual_fund_graph_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_holding/domain/models/fund_details_model.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

/// One mutual fund, many views, from the same repositories the classic fund
/// detail screen uses: overview (NAV, returns, rank, risk, costs), chart (NAV
/// history as a line), holdings (top stocks and sectors), similar funds, and
/// invest (lumpsum or SIP, see [MfInvestCard]).
class FundCard extends StatefulWidget {
  const FundCard({super.key, required this.ref, this.view, this.amount, this.mode, this.frequency});
  final FundRef ref;
  final String? view;
  final double? amount;
  final String? mode;
  final String? frequency;

  static const List<String> views = <String>['overview', 'chart', 'holdings', 'similar', 'invest'];

  @override
  State<FundCard> createState() => _FundCardState();
}

class _FundCardState extends State<FundCard> {
  final MutualFundDetailsRepositoryImpl _repo = MutualFundDetailsRepositoryImpl();
  late String _view = FundCard.views.contains(widget.view) ? widget.view! : 'overview';
  Future<SchemeDetailsModel>? _details;
  Future<KnowThisFundModel>? _know;
  Future<SimilarMutualFundModel>? _similar;

  Future<SchemeDetailsModel> get _detailsF => _details ??= _repo.getSchemeDetails(widget.ref.isin);

  @override
  Widget build(BuildContext context) => CardFrame(
        title: widget.ref.shortName,
        subtitle: widget.ref.category.isEmpty ? null : '${widget.ref.category}${widget.ref.subCategory.isEmpty ? '' : ' · ${widget.ref.subCategory}'}',
        tag: 'Mutual fund',
        views: FundCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() {
          _details = null;
          _know = null;
          _similar = null;
        }),
        child: switch (_view) {
          'chart' => _NavChart(isin: widget.ref.isin),
          'holdings' => _Holdings(future: _know ??= _repo.getKnowThisFundDetail(widget.ref.isin)),
          'invest' => MfInvestCard(key: ValueKey<String>('invest-${widget.ref.isin}-${widget.amount}'), ref: widget.ref, amount: widget.amount, mode: widget.mode, frequency: widget.frequency, embedded: true),
          'similar' => FutureBuilder<SchemeDetailsModel>(
              future: _detailsF,
              builder: (context, s) {
                final d = s.data?.data.firstOrNull;
                if (s.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
                final sub = d?.subCategory ?? widget.ref.subCategory;
                if (sub.isEmpty) return _note(context, 'No category to compare with.');
                return _Similar(future: _similar ??= _repo.getSimilarFundDetails(sub), isin: widget.ref.isin);
              },
            ),
          _ => _Overview(future: _detailsF, onInvest: () => setState(() => _view = 'invest'), onRetry: () => setState(() => _details = null)),
        },
      );

  Widget _note(BuildContext c, String t) => Text(t, style: MOTypography.bodySmallRegular.copyWith(color: c.surfaceTextNeutralStrong));
}

class _Overview extends StatelessWidget {
  const _Overview({required this.future, required this.onInvest, required this.onRetry});
  final Future<SchemeDetailsModel> future;
  final VoidCallback onInvest, onRetry;

  @override
  Widget build(BuildContext context) => FutureBuilder<SchemeDetailsModel>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching fund details…');
          final d = snap.data?.data.firstOrNull;
          if (snap.hasError || d == null) return CardError(title: "Couldn't load this fund.", message: '${snap.error ?? 'No data'}', onRetry: onRetry);
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          final val = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
          final returns = <MapEntry<String, double>>[
            MapEntry('1M', d.ret1Month), MapEntry('6M', d.ret6Month), MapEntry('1Y', d.ret1Year), MapEntry('3Y', d.ret3Year), MapEntry('5Y', d.ret5Year), MapEntry('10Y', d.ret10Year),
          ].where((e) => e.value != 0).toList();
          Widget kv(String k, String v) => Padding(padding: MOSpacing.paddingVertical2, child: Row(children: <Widget>[Text(k, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)), MOSpacing.horizontalSpace8, Expanded(child: Text(v, textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis, style: val))]));
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(d.amcFullName.isEmpty ? d.amcShortName : d.amcFullName, style: sub),
            MOSpacing.verticalSpace6,
            Wrap(spacing: MOSpacing.spacing12, runSpacing: MOSpacing.spacing6, children: <Widget>[
              for (final r in returns)
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Text(r.key, style: sub), Text('${signed(r.value)}%', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, r.value)))]),
            ]),
            if (d.rank1Year > 0 || d.rank3Year > 0) Padding(padding: MOSpacing.paddingVertical4, child: Text('Category rank: ${d.rank1Year > 0 ? '#${d.rank1Year} (1Y)' : ''}${d.rank3Year > 0 ? '  #${d.rank3Year} (3Y)' : ''}', style: sub)),
            if (d.benchmarkName.isNotEmpty && d.benchmark1Yr != 0) Text('vs ${d.benchmarkName}: 1Y ${signed(d.benchmark1Yr)}% · 3Y ${signed(d.benchmark3Yr)}%', style: sub),
            MOSpacing.verticalSpace8,
            Divider(height: 1, color: context.surfaceBorderNeutralNormal),
            MOSpacing.verticalSpace6,
            if (d.ratings.isNotEmpty && d.ratings != '0') kv('Rating', '${d.ratings} ★'),
            if (d.riskLevel.isNotEmpty) kv('Risk', d.riskLevel),
            if (d.fundAum > 0) kv('Fund size (AUM)', '₹${NumberFormat.compact(locale: 'en_IN').format(d.fundAum)} Cr'),
            if (d.expenseRatioInclusiveGst > 0) kv('Expense ratio', '${d.expenseRatioInclusiveGst}%'),
            kv('Exit load', d.exitLoad == 0 ? 'Nil' : '${d.exitLoad}%${d.loadDuration > 0 ? ' within ${d.loadDuration} days' : ''}'),
            if (d.minInitialInvestment > 0) kv('Min investment', '₹${NumberFormat('#,##,###', 'en_IN').format(d.minInitialInvestment)}'),
            if (d.fundManagers.isNotEmpty) kv('Fund manager', _managers(d.fundManagers)),
            if (d.taxImplication.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: Text(d.taxImplication.replaceAll(RegExp(r'\s*\n\s*'), ' · ').trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: sub)),
            MOSpacing.verticalSpace8,
            Row(children: <Widget>[
              Expanded(child: MOButton(label: d.LumFlag.toUpperCase() == 'N' ? 'Start SIP' : 'Invest', onPressed: onInvest, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small)),
            ]),
            Text('${d.sipFlag.toUpperCase() == 'N' ? 'SIP not available' : 'SIP available'} · ${d.LumFlag.toUpperCase() == 'N' ? 'lumpsum not available' : 'lumpsum available'}', style: sub),
          ]);
        },
      );
}

/// The API returns the managers as a JSON string: [{"name": "...", "education": "..."}].
String _managers(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is List) return v.map((m) => m is Map ? '${m['name'] ?? ''}' : '$m').where((s) => s.isNotEmpty).join(', ');
  } catch (_) {}
  return raw;
}

class _NavChart extends StatefulWidget {
  const _NavChart({required this.isin});
  final String isin;

  @override
  State<_NavChart> createState() => _NavChartState();
}

class _NavChartState extends State<_NavChart> {
  static const Map<String, int> periods = <String, int>{'1M': 30, '3M': 91, '6M': 182, '1Y': 365, '3Y': 1095, '5Y': 1826};
  String _period = '1Y';
  Future<List<MapEntry<DateTime, double>>>? _future;

  /// NAV history from the fund-detail graph API; when UAT has no rows for the
  /// ISIN there, fall back to the compare API's NAV series (months tenure).
  Future<List<MapEntry<DateTime, double>>> _load() async {
    final now = DateTime.now();
    final f = DateFormat('yyyy-MM-dd');
    final pts = <MapEntry<DateTime, double>>[];
    try {
      final r = await MutualFundGraphRepositoryImpl().fetchGraphData(widget.isin, f.format(now.subtract(Duration(days: periods[_period]!))), f.format(now));
      for (final d in r.data) {
        final nav = d.nav ?? 0;
        final dt = DateTime.tryParse(d.navDate ?? '');
        if (nav > 0 && dt != null && dt.year > 1980) pts.add(MapEntry(dt, nav));
      }
    } catch (_) {}
    if (pts.length < 2) {
      final months = (periods[_period]! / 30).round().clamp(1, 120);
      final g = await CompareMfRepositoryImpl().fetchGraphDetails(<String>[widget.isin], '$months');
      for (final s in g.data.graphDetails) {
        for (final n in s.navData) {
          if (n.navDate > 0 && n.nav > 0) pts.add(MapEntry(DateTime.fromMillisecondsSinceEpoch(n.navDate < 100000000000 ? n.navDate * 1000 : n.navDate), n.nav / (n.navMultiplier == 0 ? 1 : n.navMultiplier)));
        }
      }
    }
    pts.sort((a, b) => a.key.compareTo(b.key));
    return pts;
  }

  @override
  Widget build(BuildContext context) {
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: 6, children: <Widget>[for (final p in periods.keys) ChoiceChip(label: Text(p), selected: _period == p, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _period = p; _future = null; }))]),
      MOSpacing.verticalSpace6,
      FutureBuilder<List<MapEntry<DateTime, double>>>(
        future: _future ??= _load(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching NAV history…');
          final pts = snap.data ?? const <MapEntry<DateTime, double>>[];
          if (snap.hasError || pts.length < 2) return CardError(title: 'No NAV history.', message: '${snap.error ?? 'The NAV API returned no points for $_period.'}', onRetry: () => setState(() => _future = null));
          final first = pts.first.value, last = pts.last.value;
          final growth = (last / first - 1) * 100;
          final minY = pts.map((e) => e.value).reduce((a, b) => a < b ? a : b), maxY = pts.map((e) => e.value).reduce((a, b) => a > b ? a : b);
          final span = pts.last.key.millisecondsSinceEpoch - pts.first.key.millisecondsSinceEpoch;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[
              Text('NAV ₹${last.toStringAsFixed(2)}', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
              MOSpacing.horizontalSpace8,
              Text('${signed(growth)}% in $_period', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, growth))),
            ]),
            MOSpacing.verticalSpace8,
            SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minY: minY * 0.98, maxY: maxY * 1.02,
                lineBarsData: <LineChartBarData>[
                  LineChartBarData(spots: <FlSpot>[for (final p in pts) FlSpot(p.key.millisecondsSinceEpoch.toDouble(), p.value)], isCurved: false, barWidth: 2, color: growth >= 0 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal, dotData: const FlDotData(show: false), belowBarData: BarAreaData(show: true, color: (growth >= 0 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal).withOpacity(0.08))),
                ],
                gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (v) => FlLine(color: context.surfaceBorderNeutralNormal, strokeWidth: .5)),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(getTooltipItems: (s) => s.map((p) => LineTooltipItem('${DateFormat('d MMM yy').format(DateTime.fromMillisecondsSinceEpoch(p.x.toInt()))}\n₹${p.y.toStringAsFixed(2)}', MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextStaticWhiteNormal))).toList())),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 44, getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0), style: sub))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22, interval: span <= 0 ? null : span / 3, getTitlesWidget: (v, _) => Text(DateFormat(periods[_period]! > 365 ? 'MMM yy' : 'd MMM').format(DateTime.fromMillisecondsSinceEpoch(v.toInt())), style: sub))),
                ),
              )),
            ),
            Text('${pts.length} NAV points · ${DateFormat('d MMM yy').format(pts.first.key)} to ${DateFormat('d MMM yy').format(pts.last.key)}', style: sub),
          ]);
        },
      ),
    ]);
  }
}

class _Holdings extends StatelessWidget {
  const _Holdings({required this.future});
  final Future<KnowThisFundModel> future;

  @override
  Widget build(BuildContext context) => FutureBuilder<KnowThisFundModel>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching portfolio…');
          final d = snap.data?.data;
          if (snap.hasError || d == null) return CardError(title: "Couldn't load holdings.", message: '${snap.error ?? 'No data'}', onRetry: () {});
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          final val = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
          final eq = d.equity;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Equity ${eq.equitypercentage.toStringAsFixed(1)}% · Debt & others ${d.deptandothers.deptandotherspercentage.toStringAsFixed(1)}%', style: val),
            MOSpacing.verticalSpace8,
            if (eq.topholdings.isNotEmpty) ...<Widget>[
              Text('Top holdings', style: sub),
              for (final h in eq.topholdings.take(10))
                Padding(padding: MOSpacing.paddingVertical2, child: Row(children: <Widget>[Expanded(child: Text(h.company, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal))), Text('${h.companyAssetperc.toStringAsFixed(2)}%', style: val)])),
              MOSpacing.verticalSpace8,
            ],
            if (eq.topsectors.isNotEmpty) ...<Widget>[
              Text('Top sectors', style: sub),
              for (final s in eq.topsectors.take(8))
                Padding(
                  padding: MOSpacing.paddingVertical2,
                  child: Row(children: <Widget>[
                    Expanded(flex: 3, child: Text(s.sector, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
                    Expanded(flex: 4, child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: (s.sectorAssetperc / 100).clamp(0, 1).toDouble(), minHeight: 6, backgroundColor: context.surfaceBackgroundNeutralFaded, color: context.actionBackgroundPrimaryDefault))),
                    SizedBox(width: 56, child: Text('${s.sectorAssetperc.toStringAsFixed(1)}%', textAlign: TextAlign.end, style: val)),
                  ]),
                ),
            ],
            if (eq.topholdings.isEmpty && eq.topsectors.isEmpty) Text('No equity breakdown for this fund.', style: sub),
          ]);
        },
      );
}

class _Similar extends StatelessWidget {
  const _Similar({required this.future, required this.isin});
  final Future<SimilarMutualFundModel> future;
  final String isin;

  @override
  Widget build(BuildContext context) => FutureBuilder<SimilarMutualFundModel>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching similar funds…');
          final list = (snap.data?.data ?? const []).where((f) => f.isinCode != isin).toList();
          if (snap.hasError || list.isEmpty) return CardError(title: 'No similar funds.', message: '${snap.error ?? 'Nothing in this category.'}', onRetry: () {});
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          return Column(children: <Widget>[
            for (final f in list.take(8))
              Padding(
                padding: MOSpacing.paddingVertical6,
                child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(f.schemeName ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                    Text('Min ₹${f.minimumInvestment ?? '—'}', style: sub),
                  ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                    Text('1Y ${signed((f.ret1year ?? 0).toDouble())}%', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, (f.ret1year ?? 0).toDouble()))),
                    Text('3Y ${signed((f.ret3year ?? 0).toDouble())}%', style: sub),
                  ])),
              ),
            Text('Ask "compare <fund> with <fund>" for a side-by-side.', style: sub),
          ]);
        },
      );
}
