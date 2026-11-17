import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_portfolio_2_0/data/mo_portfolio_dashboard_repository_impl.dart';
import 'package:mo_portfolio_2_0/domain/mo_portfolio_dashboard_model/equity_detail_response.dart';
import 'package:mo_portfolio_2_0/utils/mo_portfolio_formatter.dart';
import 'package:mo_portfolio_analysis/data/portfolio_analysis_repository_impl.dart';
import 'package:mo_portfolio_analysis/utils/enums.dart';
import 'package:mo_report/pnl_report/data/pnl_report_repository_impl.dart';
import 'package:mo_report/pnl_report/domain/model/pnl_report_overview_summary_model.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/rise_shared_preference.dart';
import 'package:trader_proto_gen/PortfolioRevamp/ExternalPortfolio.pb.dart';
import 'package:trader_proto_gen/PortfolioRevamp/MfAnalysis.pb.dart';
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioAnalysisCommon.pb.dart' hide AnalysisType;
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioRevamp.pb.dart' hide FundPerformanceType;
import 'package:trader_proto_gen/PortfolioRevamp/PortfolioRevamp.pbenum.dart' hide FundPerformanceType;
import 'package:trader_proto_gen/PortfolioRevamp/StockAnalysis.pb.dart';

// ---------------------------------------------------------------------------
// Shared helpers (portfolio APIs return paise as Int64 and percentages in bps)
// ---------------------------------------------------------------------------

/// Proto money arrives as fixnum Int64 (paise); accept Int64 or num everywhere.
int _i(Object v) => v is Int64 ? v.toInt() : (v as num).toInt();
String _rupees(Object paise) => MoPortfolioFormatter.formatAmount(_i(paise));
String _signed(Object paise) => '${_i(paise) < 0 ? '−' : '+'}${MoPortfolioFormatter.formatAmount(_i(paise).abs())}';
String _bps(num bps) => '${bps < 0 ? '−' : '+'}${(bps.abs() / 100).toStringAsFixed(2)}%';
String _pct(num v) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(2)}%';
String _date(Object epochSeconds) => _i(epochSeconds) == 0 ? '—' : DateFormat('dd MMM yy').format(DateTime.fromMillisecondsSinceEpoch(_i(epochSeconds) * 1000));
Color _delta(BuildContext context, num v) => v < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal;

Widget _kv(BuildContext context, String k, String v, {Color? color, TextStyle? valueStyle}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(k, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      Text(v, style: (valueStyle ?? MOTypography.bodySmallSemibold).copyWith(color: color ?? context.surfaceTextNeutralStrong)),
    ]);

Widget _error(BuildContext context, Object e) => Padding(padding: MOSpacing.paddingVertical8, child: Text('$e'.replaceFirst('Exception: ', ''), style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal)));
Widget _loading() => const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))));
Widget _note(BuildContext context, String s) => Padding(padding: MOSpacing.paddingVertical6, child: Text(s, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)));

Widget _chips<T>(BuildContext context, List<T> items, T selected, String Function(T) label, ValueChanged<T> onPick) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: <Widget>[
        for (final it in items) ...<Widget>[
          ChoiceChip(label: Text(label(it), style: MOTypography.bodyXsmallSemibold), selected: it == selected, onSelected: (_) => onPick(it)),
          MOSpacing.horizontalSpace6,
        ],
      ]),
    );

/// A horizontal proportion bar: [parts] are (label, value, colour).
Widget _stackBar(BuildContext context, List<(String, num, Color)> parts) {
  final total = parts.fold<num>(0, (a, p) => a + (p.$2 < 0 ? 0 : p.$2));
  if (total <= 0) return const SizedBox.shrink();
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
    ClipRRect(
      borderRadius: BorderRadius.circular(MOSpacing.spacing4),
      child: SizedBox(
        height: 10,
        child: Row(children: <Widget>[
          for (final p in parts)
            if (p.$2 > 0) Expanded(flex: (p.$2 / total * 1000).round().clamp(1, 1000), child: Container(color: p.$3)),
        ]),
      ),
    ),
    MOSpacing.verticalSpace6,
    Wrap(spacing: MOSpacing.spacing12, runSpacing: MOSpacing.spacing4, children: <Widget>[
      for (final p in parts)
        if (p.$2 > 0)
          Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: p.$3, borderRadius: BorderRadius.circular(2))),
            MOSpacing.horizontalSpace4,
            Text('${p.$1} ${(p.$2 / total * 100).toStringAsFixed(0)}%', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          ]),
    ]),
  ]);
}

List<Color> _palette(BuildContext context) => <Color>[
      context.actionBackgroundPrimaryDefault,
      context.surfaceTextPositiveNormal,
      context.surfaceTextNegativeNormal,
      context.surfaceTextNeutralNormal,
      context.actionBackgroundPrimaryDefault.withValues(alpha: 0.55),
      context.surfaceTextPositiveNormal.withValues(alpha: 0.55),
      context.surfaceTextNegativeNormal.withValues(alpha: 0.55),
      context.surfaceTextNeutralNormal.withValues(alpha: 0.55),
    ];

// ---------------------------------------------------------------------------
// Net worth: everything held here plus linked external portfolios and family
// ---------------------------------------------------------------------------

class _Wealth {
  _Wealth({required this.all, this.external, this.family});
  final PortfolioCombinedDashboardResponse all;
  final ExternalPortfolioDashboardResponse? external;
  final FamilyHoldingSummaryResponse? family;
}

/// "What's my net worth?", "my total wealth", "family portfolio".
class NetWorthCard extends StatefulWidget {
  const NetWorthCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['overview', 'external', 'family'];

  @override
  State<NetWorthCard> createState() => _NetWorthCardState();
}

class _NetWorthCardState extends State<NetWorthCard> {
  late String _view = NetWorthCard.views.contains(widget.view) ? widget.view! : 'overview';
  late Future<_Wealth> _future = _load();

  Future<_Wealth> _load() async {
    final repo = MoPortfolioDashBoardRepositoryImpl();
    final all = await repo.getPortfolioOverallTabAPI();
    ExternalPortfolioDashboardResponse? ext;
    FamilyHoldingSummaryResponse? fam;
    try {
      ext = await repo.fetchExternalPortfolioGet();
    } catch (e) {
      debugPrint('GenUI external portfolio failed: $e');
    }
    try {
      fam = await repo.getFamilyHoldingSummaryAPI();
    } catch (e) {
      debugPrint('GenUI family summary failed: $e');
    }
    return _Wealth(all: all, external: ext, family: fam);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Wealth>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Net worth',
          subtitle: 'Holdings with Motilal Oswal, cash, and portfolios linked from elsewhere',
          views: NetWorthCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = _load();
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : switch (_view) {
                      'external' => _external(context, snap.data!),
                      'family' => _family(context, snap.data!),
                      _ => _overview(context, snap.data!),
                    },
        ),
      );

  Widget _overview(BuildContext context, _Wealth w) {
    final s = w.all.summary;
    final a = w.all.moAssets;
    final ext = w.all.externalAssets;
    final colors = _palette(context);
    final parts = <(String, num, Color)>[];
    var i = 0;
    void add(String name, num v) {
      if (v > 0) parts.add((name, v, colors[i++ % colors.length]));
    }
    add('Stocks', a.equity.marketValue.toInt());
    add('Mutual funds', a.mf.marketValue.toInt());
    add('Baskets', a.basket.marketValue.toInt());
    add('US stocks', a.usEquity.marketValue.toInt());
    add('Bonds', a.bonds.marketValue.toInt());
    add('PMS', a.pms.marketValue.toInt());
    add('AIF', a.aif.marketValue.toInt());
    add('Non-tradable', a.nonTradable.marketValue.toInt());
    add('Cash', a.ledger.ledgerBalance.toInt());
    add('External', ext.equity.marketValue.toInt() + ext.mf.marketValue.toInt());
    final other = w.all.otherAssetsSummary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(_rupees(s.netWorth.toInt() != 0 ? s.netWorth : s.currentValue), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextNeutralStrong)),
      Text('Net worth · invested ${_rupees(s.investedValue)} · overall ${_signed(s.overallChange)} (${_bps(s.overallChangePer)}) · today ${_signed(s.daysChange)} (${_bps(s.daysChangePer)})', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace12,
      _stackBar(context, parts),
      MOSpacing.verticalSpace12,
      for (final p in parts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: <Widget>[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: p.$3, borderRadius: BorderRadius.circular(2))),
            MOSpacing.horizontalSpace8,
            Expanded(child: Text(p.$1, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
            Text(_rupees(p.$2), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
          ]),
        ),
      if (s.ledgerBalance.toInt() != 0 || s.usLedger.toInt() != 0) ...<Widget>[
        MOSpacing.verticalSpace8,
        Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
          _kv(context, 'Trading cash', _rupees(s.ledgerBalance)),
          if (s.usLedger.toInt() != 0) _kv(context, 'US wallet', _rupees(s.usLedger)),
          if (other.mtfBorrowing.amount.toInt() != 0) _kv(context, 'MTF borrowing', _rupees(other.mtfBorrowing.amount), color: context.surfaceTextNegativeNormal),
          if (other.dividendEarned.amount.toInt() != 0) _kv(context, 'Dividends earned', _rupees(other.dividendEarned.amount), color: context.surfaceTextPositiveNormal),
        ]),
      ],
      if (w.all.uninvestedAssets.isNotEmpty) _note(context, 'Not yet invested in: ${w.all.uninvestedAssets.map((u) => u.assetName).join(', ')}.'),
    ]);
  }

  Widget _external(BuildContext context, _Wealth w) {
    final e = w.external;
    if (e == null) return _note(context, 'External portfolio data was not available on UAT.');
    final s = e.summary;
    if (s.currentValue.toInt() == 0 && e.assets.equity.marketValue.toInt() == 0 && e.assets.mf.marketValue.toInt() == 0) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('No external portfolios are linked.', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        _note(context, 'Stocks and funds held with other brokers can be linked through the account aggregator flow in the classic Portfolio › External tab (consent screen, not in the AI view).'),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(_rupees(s.currentValue), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextNeutralStrong)),
      Text('Held elsewhere · invested ${_rupees(s.investedValue)} · overall ${_signed(s.overallChange)} · today ${_signed(s.daysChange)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace8,
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
        _kv(context, 'Stocks', _rupees(e.assets.equity.marketValue)),
        _kv(context, 'Mutual funds', _rupees(e.assets.mf.marketValue)),
      ]),
      if (e.topHoldings.scrips.isNotEmpty) ...<Widget>[
        MOSpacing.verticalSpace8,
        Text('Top external holdings', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final h in e.topHoldings.scrips.take(5))
          Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: <Widget>[
            Expanded(child: Text('Scrip ${h.id.scripCode} × ${h.qty}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
            Text(_rupees(h.values.market), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
          ])),
      ],
    ]);
  }

  Widget _family(BuildContext context, _Wealth w) {
    final f = w.family;
    if (f == null || f.memberSummary.isEmpty) return _note(context, 'No family members are mapped to this account on UAT.');
    final total = f.memberSummary.fold<int>(0, (a, m) => a + m.currentValue.toInt());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(_rupees(total), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextNeutralStrong)),
      Text('Family portfolio · ${f.memberSummary.length} members', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace8,
      for (final m in f.memberSummary)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('${m.name}${m.isHOF ? ' · head of family' : ''}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                Text('${(m.totalPercentage / 100).toStringAsFixed(1)}% of family · ${m.assets.map((a) => a.assetsName).join(', ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text(_rupees(m.currentValue), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Text('${_signed(m.overallChange)} · today ${_signed(m.dayPnlValue)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, m.dayPnlValue.toInt()))),
            ])),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// What moved today in my portfolio
// ---------------------------------------------------------------------------

class _Mover {
  _Mover({required this.name, required this.sub, required this.dayChange, required this.dayPct, required this.value, this.holding, this.isin = ''});
  final String isin;
  final String name;
  final String sub;
  final double dayChange; // rupees
  final double dayPct;
  final double value; // rupees
  final EquityHoldingItem? holding;
}

/// "What's dragging my portfolio today?", "today's gainers in my portfolio".
class DayMoversCard extends StatefulWidget {
  const DayMoversCard({super.key, this.view, this.kind});
  final String? view;
  final String? kind; // gainers | losers | all
  static const List<String> views = <String>['list', 'bars'];

  @override
  State<DayMoversCard> createState() => _DayMoversCardState();
}

class _DayMoversCardState extends State<DayMoversCard> {
  late String _view = DayMoversCard.views.contains(widget.view) ? widget.view! : 'list';
  late String _kind = const <String>['gainers', 'losers', 'all'].contains(widget.kind) ? widget.kind! : 'all';
  late Future<List<_Mover>> _future = _load();

  Future<List<_Mover>> _load() async {
    final repo = MoPortfolioDashBoardRepositoryImpl();
    final out = <_Mover>[];
    final eq = await repo.getEquityDetailAPI();
    for (final h in eq.holdings) {
      out.add(_Mover(name: h.tradeSymbol, sub: '${h.totalQuantity} shares', dayChange: h.daysChange, dayPct: h.daysChangePercent, value: h.marketValue, holding: h));
    }
    try {
      final mf = await repo.getMfDetailAPI();
      for (final f in mf.entry) {
        out.add(_Mover(name: f.schemeName, sub: 'Mutual fund', dayChange: f.dayChange.toInt() / 100, dayPct: f.dayChangePer / 100, value: f.marketValue.toInt() / 100, isin: f.isin));
      }
    } catch (e) {
      debugPrint('GenUI MF day change failed: $e');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<_Mover>>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: 'Today in my portfolio',
          views: DayMoversCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = _load();
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, List<_Mover> all) {
    if (all.isEmpty) return _note(context, 'No holdings to report on.');
    final total = all.fold<double>(0, (a, m) => a + m.dayChange);
    final value = all.fold<double>(0, (a, m) => a + m.value);
    final sorted = <_Mover>[...all]..sort((a, b) => b.dayChange.compareTo(a.dayChange));
    final gainers = sorted.where((m) => m.dayChange > 0).toList();
    final losers = sorted.where((m) => m.dayChange < 0).toList().reversed.toList();
    final rows = _kind == 'gainers' ? gainers : _kind == 'losers' ? losers : <_Mover>[...gainers.take(5), ...losers.take(5)];
    final biggest = rows.fold<double>(0, (a, m) => m.dayChange.abs() > a ? m.dayChange.abs() : a);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
        _kv(context, 'Day P&L', '${total < 0 ? '−' : '+'}₹${NumberFormat('#,##,##0', 'en_IN').format(total.abs())} (${_pct(value == 0 ? 0 : total / (value - total) * 100)})', color: _delta(context, total), valueStyle: MOTypography.headingSmall),
        _kv(context, 'Up today', '${gainers.length}', color: context.surfaceTextPositiveNormal),
        _kv(context, 'Down today', '${losers.length}', color: context.surfaceTextNegativeNormal),
      ]),
      MOSpacing.verticalSpace8,
      _chips<String>(context, const <String>['all', 'gainers', 'losers'], _kind, (k) => k == 'all' ? 'Biggest moves' : k[0].toUpperCase() + k.substring(1), (k) => setState(() => _kind = k)),
      MOSpacing.verticalSpace6,
      if (rows.isEmpty) _note(context, 'Nothing moved in that direction today.'),
      for (final m in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _view == 'bars'
              ? Row(children: <Widget>[
                  SizedBox(width: 120, child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(widthFactor: biggest == 0 ? 0 : (m.dayChange.abs() / biggest).clamp(0.02, 1.0), child: Container(height: 14, decoration: BoxDecoration(color: _delta(context, m.dayChange), borderRadius: BorderRadius.circular(3)))),
                    ),
                  ),
                  MOSpacing.horizontalSpace8,
                  SizedBox(width: 90, child: Text('${m.dayChange < 0 ? '−' : '+'}₹${NumberFormat('#,##,##0', 'en_IN').format(m.dayChange.abs())}', textAlign: TextAlign.right, style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, m.dayChange)))),
                ])
              : _row(context, m),
        ),
      _note(context, 'Day change is each holding\'s move since yesterday\'s close, weighted by what you hold. Stocks update live when the feed ticks.'),
    ]);
  }

  Widget _row(BuildContext context, _Mover m) {
    void open() {
      final h = m.holding;
      if (h != null && h.scripId != null) {
        GenUiNav.openStock(GenUiNav.refOf(h.scripId!, h.tradeSymbol, h.companyName));
      } else if (m.isin.isNotEmpty) {
        GenUiNav.openFund(FundRef(isin: m.isin, name: m.name));
      }
    }
    Widget line(double change, double pct) => InkWell(onTap: open, child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Text('${m.sub} · ₹${NumberFormat('#,##,##0', 'en_IN').format(m.value)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
            ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
            Text('${change < 0 ? '−' : '+'}₹${NumberFormat('#,##,##0', 'en_IN').format(change.abs())}', style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, change))),
            Text(_pct(pct), style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, pct))),
          ])));
    final h = m.holding;
    final id = h?.scripId;
    if (h == null || id == null || id.scripCode == 0) return line(m.dayChange, m.dayPct);
    return LivePrice.scrip(
      scrip: id,
      builder: (context, t) {
        if (t == null || t.ltp == 0) return line(m.dayChange, m.dayPct);
        return line(h.totalQuantity * t.change, t.perChange);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Dividends and corporate events
// ---------------------------------------------------------------------------

class _Dividends {
  _Dividends({required this.byCompany, this.byPayout, this.events});
  final DividendByCompanyResponse byCompany;
  final DividendByPayoutResponse? byPayout;
  final UpcomingEventsResponse? events;
}

/// "Any dividends coming?", "how much dividend did I get this year", "bonus or split in my stocks".
class DividendsCard extends StatefulWidget {
  const DividendsCard({super.key, this.view, this.period});
  final String? view;
  final String? period; // this year | last year | all
  static const List<String> views = <String>['upcoming', 'received', 'history'];

  @override
  State<DividendsCard> createState() => _DividendsCardState();
}

class _DividendsCardState extends State<DividendsCard> {
  late String _view = DividendsCard.views.contains(widget.view) ? widget.view! : 'upcoming';
  late String _period = _periodOf(widget.period);
  late Future<_Dividends> _future = _load();
  static const Map<String, String> periods = <String, String>{'fy': 'This FY', 'lastfy': 'Last FY', 'all': 'Last 5 years'};

  static String _periodOf(String? p) {
    final t = (p ?? '').toLowerCase();
    if (t.contains('last')) return 'lastfy';
    if (t.contains('all') || t.contains('5') || t.contains('ever')) return 'all';
    return 'fy';
  }

  (DateTime, DateTime) _range() {
    final now = DateTime.now();
    final fyStart = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
    switch (_period) {
      case 'lastfy':
        return (DateTime(fyStart.year - 1, 4, 1), fyStart.subtract(const Duration(days: 1)));
      case 'all':
        return (DateTime(fyStart.year - 4, 4, 1), now);
    }
    return (fyStart, now);
  }

  Future<_Dividends> _load() async {
    final repo = MoPortfolioDashBoardRepositoryImpl();
    final (from, to) = _range();
    final byCompany = await repo.fetchDividendDataByCompany(startDate: from, endDate: to);
    DividendByPayoutResponse? byPayout;
    UpcomingEventsResponse? events;
    try {
      byPayout = await repo.fetchDividendDataByPayout(startDate: from, endDate: to, moslCode: '');
    } catch (e) {
      debugPrint('GenUI dividend payouts failed: $e');
    }
    try {
      events = await repo.getUpcomingEventsAPI();
    } catch (e) {
      debugPrint('GenUI upcoming events failed: $e');
    }
    return _Dividends(byCompany: byCompany, byPayout: byPayout, events: events);
  }

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<_Dividends>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Dividends & corporate events',
          views: DividendsCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: _reload,
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : switch (_view) {
                      'received' => _received(context, snap.data!),
                      'history' => _history(context, snap.data!),
                      _ => _upcoming(context, snap.data!),
                    },
        ),
      );

  String _eventName(CorpAction a) => switch (a) {
        CorpAction.Dividend => 'Dividend',
        CorpAction.Bonus => 'Bonus',
        CorpAction.Split => 'Split',
        CorpAction.W52High => '52-week high',
        CorpAction.W52Low => '52-week low',
        _ => 'Event',
      };

  Widget _events(BuildContext context, List<UpcomingEventEntry> list) => Column(children: <Widget>[
        for (final e in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing4)),
                child: Text(_eventName(e.corpActionType), style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              ),
              MOSpacing.horizontalSpace8,
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(e.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                  Text('Ex-date ${_date(e.exDate)}${e.recordDate != 0 ? ' · record ${_date(e.recordDate)}' : ''}${e.quantity != 0 ? ' · ${e.quantity} held' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                ]),
              ),
              if (e.amount.toInt() != 0) Text(e.corpActionType == CorpAction.Dividend ? '₹${(e.amount.toInt() / 100).toStringAsFixed(2)}/sh' : _rupees(e.amount), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
            ]),
          ),
      ]);

  Widget _upcoming(BuildContext context, _Dividends d) {
    final ev = d.events;
    if (ev == null) return _note(context, 'The corporate-events service did not respond on UAT.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (ev.upcoming.isEmpty) Text('No dividends, bonuses or splits are announced for your holdings right now.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)) else _events(context, ev.upcoming),
      if (ev.recent.isNotEmpty) ...<Widget>[
        MOSpacing.verticalSpace8,
        Text('Recent', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        _events(context, ev.recent),
      ],
      _note(context, 'Events are matched to what you hold. Dividend amounts are per share; multiply by your quantity for the payout.'),
    ]);
  }

  Widget _received(BuildContext context, _Dividends d) {
    final c = d.byCompany;
    final list = <DividendCompanyEntry>[...c.companies]..sort((a, b) => b.netDividend.toInt().compareTo(a.netDividend.toInt()));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _chips<String>(context, periods.keys.toList(), _period, (k) => periods[k]!, (k) {
        _period = k;
        _reload();
      }),
      MOSpacing.verticalSpace8,
      Text(_rupees(c.totalDividend), style: MOTypography.headingLarge.copyWith(color: context.surfaceTextPositiveNormal)),
      Text('Dividends received · ${periods[_period]} · ${list.length} companies', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace8,
      if (list.isEmpty) _note(context, 'No dividend credits in this period on UAT.'),
      for (final e in list)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: <Widget>[
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(e.scripName, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                Text('Last paid ${_date(e.lastDividendDate)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]),
            ),
            Text(_rupees(e.netDividend), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
          ]),
        ),
    ]);
  }

  Widget _history(BuildContext context, _Dividends d) {
    final p = d.byPayout;
    if (p == null || p.dividendYearList.isEmpty) return _note(context, 'No payout history in this period on UAT.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _chips<String>(context, periods.keys.toList(), _period, (k) => periods[k]!, (k) {
        _period = k;
        _reload();
      }),
      MOSpacing.verticalSpace8,
      for (final y in p.dividendYearList) ...<Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(y.yearName, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
          Text(_rupees(y.yearNetTotal), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
        ]),
        for (final e in y.dividendList.take(12))
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 3, bottom: 3),
            child: Row(children: <Widget>[
              Expanded(child: Text('${e.scripName} · ${e.qty} sh · ${_date(e.dividendDate)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
              Text(_rupees(e.dividendAmount), style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
            ]),
          ),
        if (y.dividendList.length > 12) _note(context, '+ ${y.dividendList.length - 12} more payouts'),
        MOSpacing.verticalSpace6,
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Non-tradable holdings
// ---------------------------------------------------------------------------

/// "Show my non-tradable holdings", "delisted or suspended shares I hold".
class NonTradableCard extends StatefulWidget {
  const NonTradableCard({super.key});

  @override
  State<NonTradableCard> createState() => _NonTradableCardState();
}

class _NonTradableCardState extends State<NonTradableCard> {
  late Future<NonTradableDetailResponse> _future = MoPortfolioDashBoardRepositoryImpl().getNonTradableDetailAPI(loadFromCache: false);

  @override
  Widget build(BuildContext context) => FutureBuilder<NonTradableDetailResponse>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Non-tradable holdings',
          subtitle: 'Suspended, delisted, locked-in or unlisted securities in your demat',
          onRefresh: () => setState(() {
            _future = MoPortfolioDashBoardRepositoryImpl().getNonTradableDetailAPI(loadFromCache: false);
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, NonTradableDetailResponse r) {
    final groups = <(String, List<NonTradableScripEntry>)>[('Stocks', r.equity), ('Mutual funds', r.mf), ('Bonds', r.bonds), ('Others', r.others)];
    final count = groups.fold<int>(0, (a, g) => a + g.$2.length);
    if (count == 0) return Text('You have no non-tradable holdings. Everything in your demat can be sold.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
        _kv(context, 'Current value', _rupees(r.marketValue), valueStyle: MOTypography.headingSmall),
        _kv(context, 'Invested', _rupees(r.investedValue)),
        _kv(context, 'Overall', _signed(r.overallChange), color: _delta(context, r.overallChange.toInt())),
        _kv(context, 'Holdings', '$count'),
      ]),
      MOSpacing.verticalSpace8,
      for (final g in groups)
        if (g.$2.isNotEmpty) ...<Widget>[
          Text(g.$1, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
          for (final e in g.$2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(e.scripName, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text('${e.totalQty} units · ISIN ${e.isin}${e.valuationDate.toInt() != 0 ? ' · valued ${_date(e.valuationDate)}' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                  ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                  Text(_rupees(e.marketValue), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                  Text(_signed(e.marketValue.toInt() - e.investedValue.toInt()), style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, e.marketValue.toInt() - e.investedValue.toInt()))),
                ])),
            ),
          MOSpacing.verticalSpace6,
        ],
      _note(context, 'These cannot be sold on the exchange right now. The value uses the last available valuation.'),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Portfolio risk and diversification (Portfolio Analysis APIs)
// ---------------------------------------------------------------------------

class _Risk {
  _Risk({this.stocks, this.funds});
  final StockAnalysisDashboardResponse? stocks;
  final MfAnalysisDashboardResponse? funds;
}

/// Analysis texts carry inline HTML (<b>…</b>); show them as plain text.
String _plain(String s) => s.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll('&amp;', '&').replaceAll('&nbsp;', ' ').trim();

String _riskLabel(int code) => switch (code) { 0 => 'Well balanced', 1 => 'Moderate risk', 2 => 'High risk', 3 => 'Neutral', _ => 'High risk' };
Color _riskColor(BuildContext context, int code) => switch (code) { 0 => context.surfaceTextPositiveNormal, 3 => context.surfaceTextNeutralNormal, 1 => context.surfaceTextNeutralStrong, _ => context.surfaceTextNegativeNormal };

/// "Is my portfolio too risky?", "am I diversified", "sector concentration", "fund overlap".
class RiskCard extends StatefulWidget {
  const RiskCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['stocks', 'funds'];

  @override
  State<RiskCard> createState() => _RiskCardState();
}

class _RiskCardState extends State<RiskCard> {
  late String _view = RiskCard.views.contains(widget.view) ? widget.view! : 'stocks';
  late Future<_Risk> _future = _load();

  Future<_Risk> _load() async {
    final repo = PortfolioAnalysisRepositoryImpl();
    StockAnalysisDashboardResponse? s;
    MfAnalysisDashboardResponse? m;
    Object? firstError;
    try {
      s = await repo.fetchStocksAnalysisDashboard(AnalysisType.mofsl, null);
    } catch (e) {
      firstError = e;
      debugPrint('GenUI stock analysis failed: $e');
    }
    try {
      m = await repo.fetchMutualFundsAnalysisDashboard(AnalysisType.mofsl, null);
    } catch (e) {
      firstError ??= e;
      debugPrint('GenUI MF analysis failed: $e');
    }
    if (s == null && m == null) throw Exception('Portfolio analysis is not available: ${'$firstError'.replaceFirst('Exception: ', '')}');
    return _Risk(stocks: s, funds: m);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Risk>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Portfolio health check',
          subtitle: 'Concentration, diversification and risk flags from Portfolio Analysis',
          views: RiskCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = _load();
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _view == 'funds'
                      ? _funds(context, snap.data!)
                      : _stocks(context, snap.data!),
        ),
      );

  Widget _flags(BuildContext context, List<PortfolioInsight> list) {
    if (list.isEmpty) return _note(context, 'No risk flags raised. Nothing stands out as concentrated or underperforming.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text('${list.length} thing${list.length == 1 ? '' : 's'} to look at', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNegativeNormal)),
      for (final i in list)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Icon(Icons.flag_outlined, size: 16, color: context.surfaceTextNegativeNormal),
            MOSpacing.horizontalSpace6,
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('${_plain(i.title)}${i.symbol.isNotEmpty ? ' · ${_plain(i.symbol)}' : ''}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                if (i.description.isNotEmpty) Text(_plain(i.description), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                if (i.nudge.isNotEmpty) Text(_plain(i.nudge), style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              ]),
            ),
          ]),
        ),
    ]);
  }

  Widget _category(BuildContext context, String title, int riskType, String message, List<(String, num, num)> items) {
    // items: (label, marketValue paise, allocation bps)
    if (items.isEmpty) return const SizedBox.shrink();
    final colors = _palette(context);
    final sorted = <(String, num, num)>[...items]..sort((a, b) => b.$3.compareTo(a.$3));
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
          Text(_riskLabel(riskType), style: MOTypography.bodyXsmallSemibold.copyWith(color: _riskColor(context, riskType))),
        ]),
        if (message.isNotEmpty) Text(_plain(message), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        MOSpacing.verticalSpace6,
        _stackBar(context, <(String, num, Color)>[for (var i = 0; i < sorted.length; i++) (sorted[i].$1, sorted[i].$3, colors[i % colors.length])]),
        MOSpacing.verticalSpace4,
        for (final it in sorted.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: <Widget>[
              Expanded(child: Text(it.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('${(it.$3 / 100).toStringAsFixed(1)}%  ', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Text(_rupees(it.$2), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
            ]),
          ),
        if (sorted.length > 6) Text('+ ${sorted.length - 6} more', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ]),
    );
  }

  Widget _stocks(BuildContext context, _Risk r) {
    final s = r.stocks;
    if (s == null) return _note(context, 'Stock analysis did not load on UAT; switch to Funds.');
    List<(String, num, num)> items(CategoryDetail c) => <(String, num, num)>[for (final e in c.entry) (e.label, e.marketValue.toInt(), e.allocation)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _flags(context, s.insights.insights),
      const Divider(height: 20),
      _category(context, s.sector.title.isEmpty ? 'Sector exposure' : s.sector.title, s.sector.riskType, s.sector.message, items(s.sector)),
      _category(context, s.marketcap.title.isEmpty ? 'Market cap mix' : s.marketcap.title, s.marketcap.riskType, s.marketcap.message, items(s.marketcap)),
      _category(context, s.stock.title.isEmpty ? 'Stock concentration' : s.stock.title, s.stock.riskType, s.stock.message, items(s.stock)),
      if (s.analysisByMo.details.isNotEmpty) ...<Widget>[
        const Divider(height: 20),
        Text(s.analysisByMo.title.isEmpty ? 'Motilal Oswal\'s view on your stocks' : s.analysisByMo.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        if (s.analysisByMo.description.isNotEmpty) Text(_plain(s.analysisByMo.description), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        for (final d in s.analysisByMo.details.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: <Widget>[
              Expanded(child: Text('${d.holding.tradeSymbol} · ${d.sector}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('${(d.allocationPercent / 100).toStringAsFixed(1)}%  ', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              Text(d.action, style: MOTypography.bodyXsmallSemibold.copyWith(color: d.action.toLowerCase().contains('sell') || d.action.toLowerCase().contains('exit') ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal)),
            ]),
          ),
      ],
      _note(context, 'A single sector or stock above roughly a quarter of the portfolio is usually treated as concentration risk.'),
    ]);
  }

  Widget _funds(BuildContext context, _Risk r) {
    final m = r.funds;
    if (m == null) return _note(context, 'Mutual fund analysis did not load on UAT; switch to Stocks.');
    List<(String, num, num)> items(MfCategoryDetail c) => <(String, num, num)>[for (final e in c.entry) (e.label, e.marketValue.toInt(), e.allocation)];
    final div = m.diversification;
    final under = <FundDetail>[for (final y in m.fundPerformance.yearlyPerformance) ...y.funds.where((f) => f.performanceType == FundPerformanceType.Underperform)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _flags(context, m.insights.insights),
      const Divider(height: 20),
      if (div.details.isNotEmpty) ...<Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(div.title.isEmpty ? 'Fund overlap' : div.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
          Text(_riskLabel(div.riskType), style: MOTypography.bodyXsmallSemibold.copyWith(color: _riskColor(context, div.riskType))),
        ]),
        if (div.nudge.isNotEmpty) Text(_plain(div.nudge), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        for (final d in div.details.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: <Widget>[
              Expanded(child: Text('${d.schemeName1}\n${d.schemeName2}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                Text('${(d.overlapPecentage / 100).toStringAsFixed(0)}% overlap', style: MOTypography.bodySmallSemibold.copyWith(color: d.overlapPecentage >= 5000 ? context.surfaceTextNegativeNormal : context.surfaceTextNeutralStrong)),
                if (d.overlapIntensity.isNotEmpty) Text(d.overlapIntensity, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]),
            ]),
          ),
        const Divider(height: 20),
      ],
      if (under.isNotEmpty) ...<Widget>[
        Text('Funds lagging their category', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNegativeNormal)),
        for (final f in under.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: <Widget>[
              Expanded(child: Text('${f.schemeName} · ${f.subCategory}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('rank ${f.rank}/${f.totalCount} · ${(f.returns / 100).toStringAsFixed(1)}%', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            ]),
          ),
        const Divider(height: 20),
      ],
      _category(context, m.assetclass.title.isEmpty ? 'Asset class split' : m.assetclass.title, m.assetclass.riskType, m.assetclass.nudge, items(m.assetclass)),
      _category(context, m.mfConcentration.title.isEmpty ? 'Fund concentration' : m.mfConcentration.title, m.mfConcentration.riskType, m.mfConcentration.nudge, items(m.mfConcentration)),
      _category(context, m.mfEqAllocation.title.isEmpty ? 'Equity allocation inside funds' : m.mfEqAllocation.title, m.mfEqAllocation.riskType, m.mfEqAllocation.nudge, items(m.mfEqAllocation)),
      if (m.portfolioBreakdown.details.isNotEmpty) ...<Widget>[
        Text(m.portfolioBreakdown.title.isEmpty ? 'Stocks your funds hold in common' : m.portfolioBreakdown.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final b in m.portfolioBreakdown.details.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: <Widget>[
              Expanded(child: Text('${b.scripName} · in ${b.entry.length} fund${b.entry.length == 1 ? '' : 's'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('${(b.totalOverlapPercentage / 100).toStringAsFixed(1)}%', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
            ]),
          ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Tax: realised gains this FY with an indicative tax estimate, and loss-harvesting ideas
// ---------------------------------------------------------------------------

class _TaxData {
  _TaxData({required this.rows, required this.holdings, required this.from, required this.to});
  final List<PnlReportData> rows;
  final List<EquityHoldingItem> holdings;
  final DateTime from;
  final DateTime to;
}

/// "How much tax will I pay this year? Can I save some?"
class TaxCard extends StatefulWidget {
  const TaxCard({super.key, this.view, this.period});
  final String? view;
  final String? period; // this year | last year
  static const List<String> views = <String>['summary', 'save'];

  @override
  State<TaxCard> createState() => _TaxCardState();
}

class _TaxCardState extends State<TaxCard> {
  late String _view = TaxCard.views.contains(widget.view) ? widget.view! : 'summary';
  late bool _lastFy = (widget.period ?? '').toLowerCase().contains('last');
  late Future<_TaxData> _future = _load();

  // Indicative rates for listed equity and equity funds (Budget 2024 onwards).
  static const double stcgRate = 0.20;
  static const double ltcgRate = 0.125;
  static const double ltcgExemption = 125000;

  (DateTime, DateTime) _range() {
    final now = DateTime.now();
    final fyStart = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
    if (_lastFy) return (DateTime(fyStart.year - 1, 4, 1), fyStart.subtract(const Duration(days: 1)));
    return (fyStart, now);
  }

  Future<_TaxData> _load() async {
    final (from, to) = _range();
    final profile = await SecureSharedPreference.getprofile() ?? '{}';
    final id = int.tryParse('${(jsonDecode(profile) as Map<String, dynamic>)['client_id'] ?? ''}') ?? 0;
    List<PnlReportData> rows = const <PnlReportData>[];
    try {
      final r = await PnlReportRepositoryImpl().getOverviewData(
        request: PnlReportOverviewRequest(type: 'allSummaryV1', id: id, fromDate: DateFormat('yyyy-MM-dd').format(from), toDate: DateFormat('yyyy-MM-dd').format(to), isFamily: false),
      );
      rows = r.data;
    } catch (e) {
      // The summary model casts numbers with `as double?`; integer zeros from the API make it throw.
      debugPrint('GenUI tax summary failed: $e');
      rethrow;
    }
    var holdings = const <EquityHoldingItem>[];
    try {
      holdings = (await MoPortfolioDashBoardRepositoryImpl().getEquityDetailAPI()).holdings;
    } catch (e) {
      debugPrint('GenUI tax holdings failed: $e');
    }
    return _TaxData(rows: rows, holdings: holdings, from: from, to: to);
  }

  void _reload() => setState(() {
        _future = _load();
      });

  String _fyLabel() {
    final (from, _) = _range();
    return 'FY ${from.year}-${(from.year + 1) % 100}';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_TaxData>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Tax on my investments',
          subtitle: '${_fyLabel()} · realised gains from the P&L report, indicative tax only',
          views: TaxCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: _reload,
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _view == 'save'
                      ? _save(context, snap.data!)
                      : _summary(context, snap.data!),
        ),
      );

  bool _isEquityLike(PnlReportData d) {
    final t = '${d.assetsType} ${d.displayName}'.toLowerCase();
    return t.contains('eq') || t.contains('stock') || t.contains('mf') || t.contains('mutual');
  }

  bool _isBusiness(PnlReportData d) {
    final t = '${d.assetsType} ${d.displayName}'.toLowerCase();
    return t.contains('fno') || t.contains('f&o') || t.contains('deriv') || t.contains('commod') || t.contains('curr');
  }

  String _inr(num v) => '${v < 0 ? '−' : ''}₹${NumberFormat('#,##,##0', 'en_IN').format(v.abs())}';

  Widget _summary(BuildContext context, _TaxData t) {
    final rows = t.rows;
    double st = 0, lt = 0, spec = 0, intraday = 0, biz = 0, div = 0, stt = 0, debtSt = 0, debtLt = 0;
    for (final d in rows) {
      div += d.dividend;
      stt += d.stt;
      if (_isBusiness(d)) {
        biz += d.gainLoss;
        continue;
      }
      if (_isEquityLike(d)) {
        st += d.shortTermGainLoss + d.equityShortTermPnl;
        lt += d.longTermGainLoss + d.equityLongTermPnl;
        debtSt += d.debtShortTermPnl;
        debtLt += d.debtLongTermPnl;
      } else {
        st += d.shortTermGainLoss;
        lt += d.longTermGainLoss;
      }
      spec += d.speculativeGainLoss;
      intraday += d.intraday;
    }
    final ltTaxable = (lt - ltcgExemption).clamp(0, double.infinity);
    final stTax = st > 0 ? st * stcgRate : 0.0;
    final ltTax = ltTaxable * ltcgRate;
    final est = stTax + ltTax;
    Widget line(String k, double v, {String? note}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: <Widget>[
            Expanded(child: Text(k, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
            if (note != null) Text('$note  ', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
            Text(_inr(v), style: MOTypography.bodySmallSemibold.copyWith(color: _delta(context, v))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _chips<bool>(context, const <bool>[false, true], _lastFy, (b) => b ? 'Last FY' : 'This FY', (b) {
        _lastFy = b;
        _reload();
      }),
      MOSpacing.verticalSpace8,
      if (rows.isEmpty) _note(context, 'No realised trades in ${_fyLabel()} on UAT, so nothing is taxable yet.'),
      Text(_inr(est), style: MOTypography.headingLarge.copyWith(color: est > 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal)),
      Text('Indicative capital-gains tax on equity so far (before cess and surcharge)', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace8,
      line('Short-term gains (held under 1 year)', st, note: '20%'),
      line('Long-term gains (held over 1 year)', lt, note: lt > ltcgExemption ? '12.5% above ₹1.25L' : 'within ₹1.25L exemption'),
      if (debtSt != 0 || debtLt != 0) line('Debt fund gains', debtSt + debtLt, note: 'at your slab'),
      if (intraday != 0 || spec != 0) line('Intraday / speculative', intraday + spec, note: 'at your slab'),
      if (biz != 0) line('F&O, commodity, currency', biz, note: 'business income, at your slab'),
      if (div != 0) line('Dividends received', div, note: 'at your slab'),
      if (stt != 0) line('STT paid', -stt, note: 'not creditable'),
      MOSpacing.verticalSpace8,
      if (rows.isNotEmpty) ...<Widget>[
        Text('By asset', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final d in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: <Widget>[
              Expanded(child: Text(d.displayName.isEmpty ? d.assetsType : d.displayName, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('ST ${_inr(d.shortTermGainLoss)} · LT ${_inr(d.longTermGainLoss)} · total ${_inr(d.gainLoss)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, d.gainLoss))),
            ]),
          ),
      ],
      _note(context, 'Estimate uses current listed-equity rates (20% STCG, 12.5% LTCG above ₹1.25 lakh). Slab-rate items depend on your income. Confirm with your tax advisor; this is not tax advice.'),
    ]);
  }

  Widget _save(BuildContext context, _TaxData t) {
    final rows = t.rows;
    final st = rows.where((d) => !_isBusiness(d)).fold<double>(0, (a, d) => a + d.shortTermGainLoss + d.equityShortTermPnl);
    final lt = rows.where((d) => !_isBusiness(d)).fold<double>(0, (a, d) => a + d.longTermGainLoss + d.equityLongTermPnl);
    final losers = <EquityHoldingItem>[...t.holdings.where((h) => h.overallChange < 0)]..sort((a, b) => a.overallChange.compareTo(b.overallChange));
    final winners = <EquityHoldingItem>[...t.holdings.where((h) => h.overallChange > 0)]..sort((a, b) => b.overallChange.compareTo(a.overallChange));
    final unrealisedLoss = losers.fold<double>(0, (a, h) => a + h.overallChange);
    final headroom = (ltcgExemption - (lt > 0 ? lt : 0)).clamp(0, ltcgExemption);
    final offsetable = st > 0 ? (unrealisedLoss.abs() > st ? st : unrealisedLoss.abs()) : 0.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (st > 0 && losers.isNotEmpty) ...<Widget>[
        Text('Book losses to offset ${_inr(st)} of short-term gains', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        Text('Selling these loss-making holdings before 31 March would offset up to ${_inr(offsetable)} of gains and save about ${_inr(offsetable * stcgRate)} at 20%. You can buy them back later if you still want them.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        for (final h in losers.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: <Widget>[
              Expanded(child: Text('${h.tradeSymbol} · ${h.totalQuantity} sh · avg ₹${h.avgPrice.toStringAsFixed(2)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text(_inr(h.overallChange), style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNegativeNormal)),
            ]),
          ),
        const Divider(height: 20),
      ] else if (st <= 0) ...<Widget>[
        Text('No short-term gains to offset this year.', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
        const Divider(height: 20),
      ],
      if (headroom > 0) ...<Widget>[
        Text('Use the ₹1.25 lakh long-term exemption', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        Text('You have ${_inr(headroom)} of tax-free long-term gains left this year. Selling and re-buying long-held winners up to that amount resets their cost without any tax.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        for (final h in winners.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: <Widget>[
              Expanded(child: Text('${h.tradeSymbol} · ${h.totalQuantity} sh', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
              Text('+${_inr(h.overallChange)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
            ]),
          ),
        _note(context, 'The holdings API does not give buy dates, so check which lots are over a year old before selling.'),
        const Divider(height: 20),
      ],
      Text('ELSS for Section 80C', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
      Text('Up to ₹1.5 lakh in an ELSS fund is deductible under the old regime. Ask "best ELSS funds" to see options.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      _note(context, 'Ideas only, based on your holdings and this year\'s realised P&L. Not tax advice.'),
    ]);
  }
}
