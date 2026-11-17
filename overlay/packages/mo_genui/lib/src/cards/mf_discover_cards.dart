import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_mutual_funds/compare/data/compare_mf_repository_impl.dart';
import 'package:mo_mutual_funds/compare/models/mf_fund_details_model.dart';
import 'package:mo_mutual_funds/compare/models/mf_graph_details_model.dart';
import 'package:mo_mutual_funds/compare/models/nav_data_model.dart';
import 'package:mo_mutual_funds/mf_common/model/collections_model.dart';
import 'package:mo_mutual_funds/mutual_fund_basket/data/mutual_fund_basket_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_basket/domain/models/mutual_fund_basket_details_model.dart';
import 'package:mo_mutual_funds/mutual_funds_landing/data/most_bought_sips_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_funds_landing/data/mutual_fund_landing_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_funds_landing/domain/models/collection_details_model.dart' as cd;
import 'package:mo_mutual_funds/mutual_funds_landing/domain/models/landingpage_nfo_data_model.dart';
import 'package:mo_mutual_funds/mutual_funds_landing/domain/models/mutual_fund_basket_list_model.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

/// Mutual fund discovery: funds by category (the app's curated collections),
/// most bought, NFOs, MF baskets, and a side-by-side compare with a NAV chart.

String _pct(num? v) => v == null || v == 0 ? '—' : '${v < 0 ? '' : '+'}${v.toStringAsFixed(1)}%';
Widget _sub(BuildContext c, String t) => Text(t, style: MOTypography.bodyXsmallRegular.copyWith(color: c.surfaceTextNeutralStrong));

/// One fund row shared by the lists.
class _FundRow extends StatelessWidget {
  const _FundRow({required this.name, required this.meta, required this.ret1y, required this.ret3y, this.rating, this.onTap});
  final String name, meta;
  final double? ret1y, ret3y;
  final String? rating;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: MOSpacing.paddingVertical6,
          child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                _sub(context, '${meta}${(rating ?? '').isNotEmpty && rating != '0' ? ' · $rating ★' : ''}'),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text('1Y ${_pct(ret1y)}', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, ret1y ?? 0))),
              _sub(context, '3Y ${_pct(ret3y)}'),
            ])),
        ),
      );
}

double? _d(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

// ------------------------------------------------------------- find funds

class FindFundsCard extends StatefulWidget {
  const FindFundsCard({super.key, this.query, this.kind, this.view, this.onOpenFund});
  final String? query; // category words: "small cap", "elss", "index"
  final String? kind; // category | mostbought | nfo
  final String? view;
  final void Function(FundRef ref)? onOpenFund;
  static const List<String> views = <String>['list', 'bars'];

  @override
  State<FindFundsCard> createState() => _FindFundsCardState();
}

class _Found {
  _Found(this.title, this.funds, {this.collections = const <CollectionsModel>[]});
  final String title;
  final List<cd.Data> funds;
  final List<CollectionsModel> collections;
}

class _FindFundsCardState extends State<FindFundsCard> {
  late String _view = FindFundsCard.views.contains(widget.view) ? widget.view! : 'list';
  late String _kind = (widget.kind ?? ((widget.query ?? '').isEmpty ? 'mostbought' : 'category')).toLowerCase();
  int? _collectionId;
  Future<_Found>? _future;
  Future<NfoDataModel>? _nfo;

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<_Found> _load() async {
    final repo = MutualFundLandingRepositoryImpl();
    if (_kind == 'mostbought') {
      final r = await MostBoughtSipsRepositoryImpl().fetchMostBoughtSips();
      return _Found('Most bought on MO', r.data ?? const <cd.Data>[]);
    }
    final cols = (await repo.fetchCollectionsList()).data ?? const <CollectionsModel>[];
    CollectionsModel? pick;
    if (_collectionId != null) pick = cols.cast<CollectionsModel?>().firstWhere((c) => c?.id == _collectionId, orElse: () => null);
    if (pick == null && (widget.query ?? '').isNotEmpty) {
      final q = _norm(widget.query!);
      final words = q.split(' ').where((w) => w.length > 2).toList();
      final scored = cols.map((c) {
        final n = _norm('${c.collectionname ?? ''} ${c.collectiondescription ?? ''}');
        return MapEntry(c, words.where(n.contains).length + (n.contains(q) ? 5 : 0));
      }).where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      pick = scored.firstOrNull?.key;
    }
    pick ??= cols.firstOrNull;
    if (pick?.id == null) return _Found('Funds', const <cd.Data>[], collections: cols);
    final det = await repo.fetchCollectionDetailsByCollectionId(pick!.id!, pageSize: 30);
    return _Found(pick.collectionname ?? 'Funds', det.data ?? const <cd.Data>[], collections: cols);
  }

  @override
  Widget build(BuildContext context) => CardFrame(
        title: _kind == 'nfo' ? 'New fund offers' : _kind == 'mostbought' ? 'Most bought funds' : 'Find funds',
        subtitle: _kind == 'category' && (widget.query ?? '').isNotEmpty ? 'For "${widget.query}"' : null,
        tag: 'Mutual funds',
        views: _kind == 'nfo' ? const <String>[] : FindFundsCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() {
          _future = null;
          _nfo = null;
        }),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Wrap(spacing: 6, children: <Widget>[
            ChoiceChip(label: const Text('By category'), selected: _kind == 'category', visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _kind = 'category'; _future = null; })),
            ChoiceChip(label: const Text('Most bought'), selected: _kind == 'mostbought', visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _kind = 'mostbought'; _future = null; })),
            ChoiceChip(label: const Text('NFOs'), selected: _kind == 'nfo', visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _kind = 'nfo')),
          ]),
          MOSpacing.verticalSpace6,
          if (_kind == 'nfo') _nfoList(context) else _fundList(context),
        ]),
      );

  Widget _fundList(BuildContext context) => FutureBuilder<_Found>(
        future: _future ??= _load(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching funds…');
          final f = snap.data;
          if (snap.hasError || f == null) return CardError(title: "Couldn't load funds.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _future = null));
          final funds = f.funds.where((x) => (x.isinCode ?? '').isNotEmpty).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (f.collections.length > 1)
              SizedBox(
                height: 30,
                child: ListView(scrollDirection: Axis.horizontal, children: <Widget>[
                  for (final c in f.collections.where((c) => (c.collectionname ?? '').isNotEmpty).take(20))
                    Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: Text(c.collectionname!), selected: f.title == c.collectionname, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _collectionId = c.id; _kind = 'category'; _future = null; }))),
                ]),
              ),
            MOSpacing.verticalSpace6,
            if (funds.isEmpty) _sub(context, 'No funds in "${f.title}".'),
            if (_view == 'bars' && funds.isNotEmpty)
              _ReturnBars(labels: funds.take(10).map((x) => (x.shortSchemeName ?? x.schemeName ?? '').split(' ').take(3).join(' ')).toList(), values: funds.take(10).map((x) => x.ret1year ?? 0).toList())
            else
              for (final x in funds.take(12))
                _FundRow(
                  name: x.schemeName ?? '',
                  meta: '${x.subCategory ?? x.category ?? ''}${(x.sipMinInvAmount ?? '').isNotEmpty ? ' · SIP from ₹${x.sipMinInvAmount!.split(RegExp(r'[/,]')).first.trim()}' : ''}',
                  ret1y: x.ret1year,
                  ret3y: x.ret3year,
                  rating: x.ratings,
                  onTap: () => (widget.onOpenFund ?? GenUiNav.openFund)(FundRef(isin: x.isinCode!, name: x.schemeName ?? '', category: x.category ?? '', subCategory: x.subCategory ?? '', nav: _d(x.currentNav) ?? 0, rating: int.tryParse('${x.ratings ?? ''}') ?? 0, return3Y: x.ret3year ?? 0, logo: x.amcLogo ?? '')),
                ),
            _sub(context, 'Tap a fund for details, chart and invest. Returns are annualised for periods over a year.'),
          ]);
        },
      );

  Widget _nfoList(BuildContext context) => FutureBuilder<NfoDataModel>(
        future: _nfo ??= MutualFundLandingRepositoryImpl().getNFOData(20),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching NFOs…');
          final rows = snap.data?.data ?? const <NfoDataModelData>[];
          if (snap.hasError || rows.isEmpty) return CardError(title: 'No open NFOs.', message: '${snap.error ?? 'Nothing listed right now.'}', onRetry: () => setState(() => _nfo = null));
          return Column(children: <Widget>[
            for (final n in rows.take(10))
              Padding(
                padding: MOSpacing.paddingVertical6,
                child: Row(children: <Widget>[
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(n.schemeName ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                    _sub(context, '${n.amcShortName ?? ''}${(n.nfoStartDate ?? '').isEmpty ? '' : ' · ${n.nfoStartDate} to ${n.nfoEndDate ?? ''}'}'),
                  ])),
                  if ((n.isinCode ?? '').isNotEmpty) TextButton(onPressed: () => (widget.onOpenFund ?? GenUiNav.openFund)(FundRef(isin: n.isinCode!, name: n.schemeName ?? '')), child: const Text('View')),
                ]),
              ),
          ]);
        },
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
      height: 40.0 * values.length,
      child: RotatedBox(
        quarterTurns: 1,
        child: BarChart(BarChartData(
          maxY: maxAbs * 1.25, minY: values.any((v) => v < 0) ? -maxAbs * 1.25 : 0,
          gridData: const FlGridData(show: false), borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(), rightTitles: const AxisTitles(), topTitles: const AxisTitles(),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 110, getTitlesWidget: (v, _) => RotatedBox(quarterTurns: -1, child: Text('${labels[v.toInt()]}  ${_pct(values[v.toInt()])}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))))),
          ),
          barGroups: <BarChartGroupData>[for (var i = 0; i < values.length; i++) BarChartGroupData(x: i, barRods: <BarChartRodData>[BarChartRodData(toY: values[i], width: 14, color: values[i] >= 0 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal, borderRadius: BorderRadius.circular(3))])],
        )),
      ),
    );
  }
}

// ---------------------------------------------------------------- baskets

class MfBasketsCard extends StatefulWidget {
  const MfBasketsCard({super.key});

  @override
  State<MfBasketsCard> createState() => _MfBasketsCardState();
}

class _MfBasketsCardState extends State<MfBasketsCard> {
  Future<MfBasketListModel>? _list;
  int? _open;
  Future<MfBasketDetails>? _detail;

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'Mutual fund baskets',
        tag: 'Mutual funds',
        onRefresh: () => setState(() => _list = null),
        child: FutureBuilder<MfBasketListModel>(
          future: _list ??= MutualFundLandingRepositoryImpl().getMutualFundBaskets(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching baskets…');
            final rows = snap.data?.data ?? const <MFBasketListData>[];
            if (snap.hasError || rows.isEmpty) return CardError(title: 'No MF baskets.', message: '${snap.error ?? 'None listed.'}', onRetry: () => setState(() => _list = null));
            return Column(children: <Widget>[
              for (final b in rows.take(10)) ...<Widget>[
                InkWell(
                  onTap: () => setState(() {
                    _open = _open == b.id ? null : b.id;
                    _detail = _open == null ? null : MutualFundBasketRepositoryImpl().getBasketDetails(b.id);
                  }),
                  child: Padding(
                    padding: MOSpacing.paddingVertical6,
                    child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text(b.name, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                        _sub(context, '${b.fundCount} funds · ${b.risk} risk · equity ${b.equityPercentage}% · debt ${b.debtPercentage}%${b.minSip != null ? ' · SIP from ₹${b.minSip}' : ''}'),
                      ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                        Text('3Y ${_pct(b.threeYearReturns / 100)}', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, b.threeYearReturns))),
                        _sub(context, '5Y ${_pct(b.fiveYearReturns / 100)}'),
                      ]), end: Icon(_open == b.id ? Icons.expand_less : Icons.expand_more, size: 18, color: context.surfaceIconNeutralNormal)),
                  ),
                ),
                if (_open == b.id)
                  FutureBuilder<MfBasketDetails>(
                    future: _detail,
                    builder: (context, ds) {
                      if (ds.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching constituents…');
                      final d = ds.data;
                      if (d == null) return _sub(context, 'No details.');
                      return Padding(
                        padding: EdgeInsets.only(left: MOSpacing.spacing12, bottom: MOSpacing.spacing6),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          if (d.description.isNotEmpty) _sub(context, d.description),
                          for (final f in d.funds) _sub(context, '${f.name} · ${f.allocation}%${f.threeYearReturns != 0 ? ' · 3Y ${_pct(f.threeYearReturns / 100)}' : ''}'),
                          _sub(context, 'Min SIP ₹${d.minInvestments.sip} · min lumpsum ₹${d.minInvestments.lumpSum}. Basket investing goes through the MF basket order flow, not in the AI view yet.'),
                        ]),
                      );
                    },
                  ),
              ],
            ]);
          },
        ),
      );
}

// ---------------------------------------------------------------- compare

class CompareFundsCard extends StatefulWidget {
  const CompareFundsCard({super.key, required this.refs});
  final List<FundRef> refs;

  @override
  State<CompareFundsCard> createState() => _CompareFundsCardState();
}

class _CompareFundsCardState extends State<CompareFundsCard> {
  static const Map<String, String> tenures = <String, String>{'3M': '3', '6M': '6', '1Y': '12', '3Y': '36', '5Y': '60'}; // label → months, as classic sends
  String _tenure = '1Y';
  Future<FundDetailsResponse>? _details;
  Future<MfGraphDetailsModel>? _graph;

  List<String> get _isins => widget.refs.map((r) => r.isin).toList();

  @override
  Widget build(BuildContext context) {
    if (widget.refs.length < 2) {
      return CardFrame(title: 'Compare funds', tag: 'Mutual funds', child: _sub(context, 'Name at least two funds to compare, e.g. "compare Parag Parikh Flexi Cap with Motilal Oswal Midcap".'));
    }
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    final colors = <Color>[context.actionBackgroundPrimaryDefault, context.feedbackIconWarningNormal, context.surfaceTextPositiveNormal, context.surfaceTextNegativeNormal];
    return CardFrame(
      title: 'Compare funds',
      subtitle: widget.refs.map((r) => r.shortName).join(' vs '),
      tag: 'Mutual funds',
      onRefresh: () => setState(() {
        _details = null;
        _graph = null;
      }),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        FutureBuilder<FundDetailsResponse>(
          future: _details ??= CompareMfRepositoryImpl().fetchFundDetails(_isins),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Comparing…');
            final rows = snap.data?.data.fundDetails ?? const <FundDetail>[];
            if (snap.hasError || rows.isEmpty) return CardError(title: "Couldn't compare.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _details = null));
            Widget cell(String t, {bool head = false, Color? color}) => Padding(padding: MOSpacing.paddingAll4, child: Text(t, textAlign: TextAlign.end, maxLines: head ? 3 : 1, style: (head ? MOTypography.bodyXsmallSemibold : MOTypography.bodyXsmallRegular).copyWith(color: color ?? context.surfaceTextNeutralNormal)));
            final metrics = <MapEntry<String, String Function(FundDetail)>>[
              MapEntry('1Y return', (f) => _pct(f.returns.oneYear / 100)),
              MapEntry('3Y return', (f) => _pct(f.returns.threeYear / 100)),
              MapEntry('5Y return', (f) => _pct(f.returns.fiveYear / 100)),
              MapEntry('Category avg 1Y', (f) => _pct(f.returnsComparison.categoryAvg / 100)),
              MapEntry('Category rank', (f) => f.returnsComparison.categoryRank == 0 ? '—' : '#${f.returnsComparison.categoryRank}'),
              MapEntry('Benchmark 1Y', (f) => _pct(f.returnsComparison.bmkreturn1Year / 100)),
              MapEntry('Rating', (f) => f.ratings.isEmpty || f.ratings == '0' ? '—' : '${f.ratings} ★'),
              MapEntry('Risk', (f) => f.risklevel.isEmpty ? '—' : f.risklevel),
              MapEntry('Category', (f) => f.subCategory.isEmpty ? f.category : f.subCategory),
            ];
            return Table(
              columnWidths: <int, TableColumnWidth>{0: const FixedColumnWidth(110), for (var i = 0; i < rows.length; i++) i + 1: const FlexColumnWidth()},
              children: <TableRow>[
                TableRow(children: <Widget>[const SizedBox(), for (var i = 0; i < rows.length; i++) cell(rows[i].schemeName.replaceAll(RegExp(r'\s*-\s*(Direct|Regular).*$', caseSensitive: false), ''), head: true, color: colors[i % colors.length])]),
                for (final m in metrics) TableRow(children: <Widget>[Padding(padding: MOSpacing.paddingAll4, child: Text(m.key, style: sub)), for (final f in rows) cell(m.value(f))]),
              ],
            );
          },
        ),
        MOSpacing.verticalSpace8,
        Wrap(spacing: 6, children: <Widget>[for (final t in tenures.keys) ChoiceChip(label: Text(t), selected: _tenure == t, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _tenure = t; _graph = null; }))]),
        FutureBuilder<MfGraphDetailsModel>(
          future: _graph ??= CompareMfRepositoryImpl().fetchGraphDetails(_isins, tenures[_tenure]!),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching NAV series…');
            final series = snap.data?.data.graphDetails ?? const <GraphDetail>[];
            if (snap.hasError || series.isEmpty) return _sub(context, snap.hasError ? '${snap.error}' : 'No NAV series for $_tenure.');
            final lines = <LineChartBarData>[];
            double minY = 100, maxY = 100;
            var i = 0;
            for (final s in series) {
              final pts = s.navData.map((n) => MapEntry(_navDate(n), _navValue(n))).where((e) => e.key != null && e.value > 0).map((e) => MapEntry(e.key!, e.value)).toList()..sort((a, b) => a.key.compareTo(b.key));
              if (pts.length < 2) continue;
              final base = pts.first.value;
              final spots = <FlSpot>[];
              for (final p in pts) {
                final v = p.value / base * 100;
                spots.add(FlSpot(p.key.millisecondsSinceEpoch.toDouble(), v));
                if (v < minY) minY = v;
                if (v > maxY) maxY = v;
              }
              lines.add(LineChartBarData(spots: spots, isCurved: false, barWidth: 2, color: colors[i++ % colors.length], dotData: const FlDotData(show: false)));
            }
            if (lines.isEmpty) return _sub(context, 'No NAV points.');
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Wrap(spacing: 10, children: <Widget>[for (var k = 0; k < widget.refs.length && k < lines.length; k++) Row(mainAxisSize: MainAxisSize.min, children: <Widget>[Container(width: 10, height: 10, color: colors[k % colors.length]), MOSpacing.horizontalSpace4, Text(widget.refs[k].shortName, style: sub)])]),
              MOSpacing.verticalSpace6,
              SizedBox(
                height: 180,
                child: LineChart(LineChartData(
                  minY: minY - 2, maxY: maxY + 2, lineBarsData: lines,
                  gridData: FlGridData(show: true, drawVerticalLine: false, getDrawingHorizontalLine: (v) => FlLine(color: context.surfaceBorderNeutralNormal, strokeWidth: .5)),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(rightTitles: const AxisTitles(), topTitles: const AxisTitles(), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 34, getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0), style: sub))), bottomTitles: const AxisTitles()),
                )),
              ),
              _sub(context, 'NAVs rebased to 100 at the start of $_tenure, so the gap is relative performance.'),
            ]);
          },
        ),
      ]),
    );
  }

  // NavDate is epoch (seconds or ms); Nav is scaled by navMultiplier. Only ratios matter here.
  DateTime? _navDate(NavData n) => n.navDate <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(n.navDate < 100000000000 ? n.navDate * 1000 : n.navDate);

  double _navValue(NavData n) => n.nav.toDouble();
}
