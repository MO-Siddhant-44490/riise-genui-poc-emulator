import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/cards/order_ticket_card.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_research/data/mo_research_explore_repository_impl.dart';
import 'package:mo_research/screens/dashboard/reserch_report_detail/data/report_detail_repository_impl.dart';
import 'package:mo_research/screens/research_revamp/data/research_revamp_repository_impl.dart';
import 'package:mo_research_assistant/research_assistant/data/mo_research_assistant_impl.dart';
import 'package:mo_research_assistant/research_assistant/domain/model/chat_screen/stream_response_model.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/rise_shared_preference.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_index_options/intra_options/domain/repository/option_brain_repository.dart';
import 'package:trader_proto_gen/Recommendation/Advice.pb.dart';
import 'package:trader_proto_gen/Recommendation/ResearchIdeasInterop.pbenum.dart';
import 'package:trader_proto_gen/Recommendation/ResearchIdeasMarket.pbenum.dart';
import 'package:trader_proto_gen/Recommendation/ResearchIdeasReports.pb.dart';
import 'package:trader_proto_gen/Recommendation/ResearchRevamp.pb.dart' as rr;
import 'package:trader_proto_gen/Recommendation/ResearchRevamp.pbenum.dart' as rr;
import 'package:trader_proto_gen/TradingCore/CoreEnums.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// Helpers. Research prices are Int64 paise; percentages are bps.
// ---------------------------------------------------------------------------

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
String _pct(num v) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(1)}%';
String _date(int epochSeconds) => epochSeconds == 0 ? '' : DateFormat('dd MMM').format(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000));
Color _delta(BuildContext context, num v) => v < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal;

Widget _kv(BuildContext context, String k, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(k, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      Text(v, style: MOTypography.bodySmallSemibold.copyWith(color: color ?? context.surfaceTextNeutralStrong)),
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

/// Research bullet summaries arrive as "•" / newline separated text, sometimes with HTML.
List<String> _bullets(String s) => s
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .split(RegExp(r'\n|•|•|\|'))
    .map((e) => e.trim().replaceFirst(RegExp(r'^[-*·]\s*'), ''))
    .where((e) => e.isNotEmpty)
    .toList();

Widget _bulletList(BuildContext context, String text, {int max = 6}) {
  final items = _bullets(text);
  if (items.isEmpty) return const SizedBox.shrink();
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
    for (final b in items.take(max))
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('• ', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          Expanded(child: Text(b, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
        ]),
      ),
  ]);
}

Future<void> _openUrl(BuildContext context, String url) async {
  if (url.isEmpty) return;
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the report.')));
}

Widget _pdfButton(BuildContext context, String url, {String label = 'Open report (PDF)'}) =>
    url.isEmpty ? const SizedBox.shrink() : MOButton(label: label, onPressed: () => _openUrl(context, url), variant: MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small);

String _horizon(ResearchCallHorizon h) => switch (h) {
      ResearchCallHorizon.IntradayHorizon => 'Intraday',
      ResearchCallHorizon.BtstHorizon => 'BTST',
      ResearchCallHorizon.ShortTermHorizon => 'Short term',
      ResearchCallHorizon.PositionalHorizon => 'Positional',
      ResearchCallHorizon.MidTermHorizon => 'Mid term',
      ResearchCallHorizon.LongTermHorizon => 'Long term',
      ResearchCallHorizon.MtfHorizon => 'MTF',
      _ => '',
    };

rr.ResearchSegment _segment(String? s) {
  final t = (s ?? '').toLowerCase();
  if (t.contains('f&o') || t.contains('fno') || t.contains('deriv') || t.contains('option') || t.contains('future')) return rr.ResearchSegment.FnoSegment;
  if (t.contains('commod') || t.contains('mcx') || t.contains('gold') || t.contains('crude')) return rr.ResearchSegment.CommoditySegment;
  return rr.ResearchSegment.EquitySegment;
}

String _segmentName(rr.ResearchSegment s) => switch (s) { rr.ResearchSegment.FnoSegment => 'F&O', rr.ResearchSegment.CommoditySegment => 'Commodity', _ => 'Stocks' };

String _reco(RecommendationTag t) => switch (t) { RecommendationTag.Buy => 'BUY', RecommendationTag.Sell => 'SELL', _ => 'HOLD' };
Color _recoColor(BuildContext context, RecommendationTag t) => switch (t) { RecommendationTag.Buy => context.surfaceTextPositiveNormal, RecommendationTag.Sell => context.surfaceTextNegativeNormal, _ => context.surfaceTextNeutralStrong };

ScripRef _ref(ScripId id, String symbol, String name) => ScripRef(scripCode: '${id.scripCode}', exchange: id.exchange.name, exchangeCode: id.exchange.value, id: id, symbol: symbol, name: name);

// ---------------------------------------------------------------------------
// Research calls: investment picks, trading calls, live and closed calls
// ---------------------------------------------------------------------------

/// "Any stock recommendations?", "intraday calls today", "what did research close recently".
class ResearchCallsCard extends StatefulWidget {
  const ResearchCallsCard({super.key, this.kind, this.segment, this.horizon});
  final String? kind; // investment | trading | live | closed
  final String? segment; // equity | fno | commodity
  final String? horizon; // intraday | btst | short | positional | long
  static const List<String> views = <String>['investment', 'trading', 'live', 'closed'];

  @override
  State<ResearchCallsCard> createState() => _ResearchCallsCardState();
}

class _ResearchCallsCardState extends State<ResearchCallsCard> {
  late String _view = ResearchCallsCard.views.contains(widget.kind) ? widget.kind! : 'investment';
  late rr.ResearchSegment _seg = _segment(widget.segment);
  late ResearchCallHorizon? _hz = _hzOf(widget.horizon);
  late Future<rr.ResearchLandingResponse> _future = _load();

  static ResearchCallHorizon? _hzOf(String? s) {
    final t = (s ?? '').toLowerCase();
    if (t.startsWith('intra')) return ResearchCallHorizon.IntradayHorizon;
    if (t.startsWith('btst')) return ResearchCallHorizon.BtstHorizon;
    if (t.startsWith('short')) return ResearchCallHorizon.ShortTermHorizon;
    if (t.startsWith('pos')) return ResearchCallHorizon.PositionalHorizon;
    if (t.startsWith('long')) return ResearchCallHorizon.LongTermHorizon;
    if (t.startsWith('mid')) return ResearchCallHorizon.MidTermHorizon;
    return null;
  }

  Future<rr.ResearchLandingResponse> _load() => ResearchRevampRepositoryImpl().fetchLanding(_seg, fresh: true);

  void _reload() => setState(() {
        _future = _load();
      });

  List<rr.ResearchCall> _pick(rr.ResearchLandingResponse r) {
    var list = switch (_view) {
      'trading' => r.tradingPicks.isNotEmpty ? r.tradingPicks : r.liveCalls.where((c) => c.callHorizon != ResearchCallHorizon.LongTermHorizon).toList(),
      'live' => r.liveCalls.isNotEmpty ? r.liveCalls : <rr.ResearchCall>[...r.investmentPicks, ...r.tradingPicks],
      'closed' => r.closedCalls,
      _ => r.investmentPicks.isNotEmpty ? r.investmentPicks : r.picks,
    };
    if (_hz != null) list = list.where((c) => c.callHorizon == _hz).toList();
    return list;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<rr.ResearchLandingResponse>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: 'Research calls · ${_segmentName(_seg)}',
          subtitle: 'Motilal Oswal research desk picks',
          views: ResearchCallsCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: _reload,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            _chips<rr.ResearchSegment>(context, rr.ResearchSegment.values, _seg, _segmentName, (s) {
              _seg = s;
              _reload();
            }),
            MOSpacing.verticalSpace6,
            if (snap.hasError) _error(context, snap.error!) else if (!snap.hasData) _loading() else _body(context, snap.data!),
          ]),
        ),
      );

  Widget _body(BuildContext context, rr.ResearchLandingResponse r) {
    final list = _pick(r);
    final horizons = <ResearchCallHorizon?>{null, ...list.map((c) => c.callHorizon).where((h) => h != ResearchCallHorizon.UnclassifiedHorizon)}.toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (horizons.length > 2)
        _chips<ResearchCallHorizon?>(context, horizons, _hz, (h) => h == null ? 'All' : _horizon(h), (h) => setState(() => _hz = h)),
      if (r.hero.callsToday.isNotEmpty && _view != 'closed') _note(context, '${r.hero.callsToday.length + r.hero.moreCallsTodayCount} calls published today.'),
      if (list.isEmpty)
        Padding(padding: MOSpacing.paddingVertical8, child: Text('No ${_view == 'closed' ? 'recently closed' : 'open $_view'} calls for ${_segmentName(_seg)} on UAT right now.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
      for (final c in list.take(12)) _CallRow(key: ValueKey<int>(c.callId), call: c, closed: _view == 'closed'),
      _note(context, 'Research calls are Motilal Oswal\'s own recommendations, shown as published. Tap a call for the reasoning and to trade it.'),
    ]);
  }
}

class _CallRow extends StatefulWidget {
  const _CallRow({super.key, required this.call, required this.closed});
  final rr.ResearchCall call;
  final bool closed;

  @override
  State<_CallRow> createState() => _CallRowState();
}

class _CallRowState extends State<_CallRow> {
  bool _open = false;
  bool _trade = false;
  Future<rr.ResearchCallDetailsResponse>? _detail;

  @override
  Widget build(BuildContext context) {
    final c = widget.call;
    final buy = c.action == OrderAction.Buy;
    final entry = c.entryPrice.toInt() / 100;
    final target = c.targetPrice.toInt() / 100;
    final sl = c.stopLoss.toInt() / 100;
    final potential = c.potentialReturnPct.toInt() / 100;
    final ret = c.returnPct.toInt() / 100;
    final tag = <String>[if (c.isIntraday) 'Intraday' else if (_horizon(c.callHorizon).isNotEmpty) _horizon(c.callHorizon), if (c.isMtf) 'MTF', if (c.isBtst) 'BTST', if (c.isHighPotential) 'High potential', if (c.instrument != rr.ResearchInstrument.CashInstrument) c.instrument.name.replaceAll('Instrument', '')].join(' · ');
    return Column(children: <Widget>[
      InkWell(
        onTap: () => setState(() {
          _open = !_open;
          if (_open && !widget.closed) _detail ??= ResearchRevampRepositoryImpl().fetchCallDetails(scripCode: c.scrip.scripCode, exchange: c.scrip.exchange.value, callId: c.callId);
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LivePrice.scrip(
            scrip: c.scrip,
            builder: (context, t) {
              final ltp = (t?.ltp ?? 0) != 0 ? t!.ltp : c.ltp.toInt() / 100;
              final progress = entry == 0 || target == entry ? null : ((ltp - entry) / (target - entry)).clamp(-1.0, 1.0);
              final narrow = CardLayout.narrowOf(context);
              final badge = Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: (buy ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(MOSpacing.spacing4)),
                child: Text(buy ? 'BUY' : 'SELL', style: MOTypography.bodyXsmallSemibold.copyWith(color: buy ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal)),
              );
              final name = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                GestureDetector(
                  onTap: () => GenUiNav.openStock(_ref(c.scrip, c.symbol, c.companyName)),
                  child: Text(c.symbol.isNotEmpty ? c.symbol : (c.companyName.isNotEmpty ? c.companyName : c.displayName), maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPrimaryNormal, decoration: TextDecoration.underline)),
                ),
                Text('${c.companyName.isNotEmpty && c.companyName != c.symbol ? '${c.companyName} · ' : ''}$tag${tag.isEmpty ? '' : ' · '}${_date(c.publishedAt)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]);
              final price = Text(ltp == 0 ? '—' : '₹${_money(ltp)}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong));
              final outcome = Text(widget.closed ? '${_pct(ret)} ${c.outcome == rr.ResearchCallOutcome.ProfitBooked ? 'profit' : c.outcome == rr.ResearchCallOutcome.LossBooked ? 'loss' : 'closed'}' : 'target ${_pct(potential)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: widget.closed ? _delta(context, ret) : context.surfaceTextPositiveNormal));
              final entryT = Text('Entry ₹${_money(entry)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal));
              final targetT = Text('Target ₹${_money(target)}', textAlign: narrow ? TextAlign.left : TextAlign.center, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextPositiveNormal));
              final slT = Text(widget.closed ? 'Exit ₹${_money(c.exitPrice.toInt() / 100)}' : sl == 0 ? '' : 'SL ₹${_money(sl)}', textAlign: narrow ? TextAlign.left : TextAlign.right, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNegativeNormal));
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                // Half-width slot: badge + name on one line, price and target on the next, levels wrapped.
                if (narrow) ...<Widget>[
                  Row(children: <Widget>[badge, MOSpacing.horizontalSpace8, Expanded(child: name)]),
                  MOSpacing.verticalSpace2,
                  Row(children: <Widget>[price, MOSpacing.horizontalSpace8, outcome]),
                  MOSpacing.verticalSpace2,
                  Wrap(spacing: MOSpacing.spacing8, runSpacing: MOSpacing.spacing2, children: <Widget>[entryT, targetT, slT]),
                ] else ...<Widget>[
                  Row(children: <Widget>[
                    badge,
                    MOSpacing.horizontalSpace8,
                    Expanded(child: name),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[price, outcome]),
                  ]),
                  MOSpacing.verticalSpace4,
                  Row(children: <Widget>[Expanded(child: entryT), Expanded(child: targetT), Expanded(child: slT)]),
                ],
                if (!widget.closed && progress != null) ...<Widget>[
                  MOSpacing.verticalSpace4,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(value: progress < 0 ? 0 : progress, minHeight: 4, backgroundColor: context.surfaceBackgroundNeutralFaded, color: progress < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal),
                  ),
                ],
              ]);
            },
          ),
        ),
      ),
      if (_open) ...<Widget>[
        if (!widget.closed && _detail != null)
          FutureBuilder<rr.ResearchCallDetailsResponse>(
            future: _detail,
            builder: (context, snap) {
              if (!snap.hasData) return snap.hasError ? _note(context, 'Call details were not available.') : _loading();
              final d = snap.data!.liveCalls.cast<rr.ResearchCallDetail?>().firstWhere((x) => x!.callId == c.callId, orElse: () => snap.data!.liveCalls.isEmpty ? null : snap.data!.liveCalls.first);
              if (d == null) return _note(context, 'No reasoning published for this call.');
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                if (d.bulletSummary.isNotEmpty) ...<Widget>[Text('Why', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)), _bulletList(context, d.bulletSummary)],
                MOSpacing.verticalSpace6,
                Wrap(spacing: MOSpacing.spacing8, runSpacing: MOSpacing.spacing6, children: <Widget>[
                  _pdfButton(context, d.pdfDownloadUrl),
                  MOButton(label: _trade ? 'Hide ticket' : '${buy ? 'Buy' : 'Sell'} as per call', onPressed: () => setState(() => _trade = !_trade), variant: MOButtonVariant.primary, color: buy ? MOButtonColor.primary : MOButtonColor.negative, size: MOButtonSize.small),
                ]),
              ]);
            },
          )
        else if (!widget.closed)
          MOButton(label: _trade ? 'Hide ticket' : '${buy ? 'Buy' : 'Sell'} as per call', onPressed: () => setState(() => _trade = !_trade), variant: MOButtonVariant.primary, color: buy ? MOButtonColor.primary : MOButtonColor.negative, size: MOButtonSize.small),
        if (_trade)
          OrderTicketCard(
            key: ValueKey<String>('call-${c.callId}'),
            ref: _ref(c.scrip, c.symbol, c.companyName.isNotEmpty ? c.companyName : c.displayName),
            side: buy ? 'buy' : 'sell',
            qty: c.lotSize > 0 ? c.lotSize : null,
            product: c.isIntraday ? 'intraday' : c.isMtf ? 'mtf' : null,
          ),
        MOSpacing.verticalSpace6,
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Research reports: company reports, market/sector reports, today's outlook
// ---------------------------------------------------------------------------

class _Reports {
  _Reports({this.company = const <ResearchCompanyReport>[], this.other = const <OtherReport>[], this.outlook = const <rr.OutlookCard>[], this.detail, this.askAssistant});
  final List<ResearchCompanyReport> company;
  final List<OtherReport> other;
  final List<rr.OutlookCard> outlook;
  final ResearchCompanyReportDetails? detail;
  /// When no published report exists, hand the question to the Research Assistant.
  final String? askAssistant;
}

/// "Show research reports", "research report on JSL", "explain the latest research report", "market outlook".
class ResearchReportsCard extends StatefulWidget {
  const ResearchReportsCard({super.key, this.ref, this.view});
  final ScripRef? ref;
  final String? view;
  static const List<String> views = <String>['company', 'market', 'outlook'];

  @override
  State<ResearchReportsCard> createState() => _ResearchReportsCardState();
}

class _ResearchReportsCardState extends State<ResearchReportsCard> {
  late String _view = ResearchReportsCard.views.contains(widget.view) ? widget.view! : 'company';
  late Future<_Reports> _future = _load();

  Future<_Reports> _load() async {
    final reports = ReportDetailRepositoryImpl();
    if (widget.ref != null && _view == 'company') {
      // One company: search the research index for its latest report and expand it.
      final explore = MoResearchExploreRepositoryImpl();
      final sr = await explore.searchScrip(widget.ref!.symbol);
      final mine = sr.reports.where((r) => r.tradeSymbol.toUpperCase() == widget.ref!.symbol.toUpperCase() || r.scripCode == int.tryParse(widget.ref!.scripCode)).toList()..sort((a, b) => b.reportDate.compareTo(a.reportDate));
      if (mine.isEmpty) return _Reports(askAssistant: 'Give me a research snapshot of ${widget.ref!.name.isNotEmpty ? widget.ref!.name : widget.ref!.symbol}');
      ResearchCompanyReportDetails? detail;
      try {
        detail = await explore.fetchSingleCompanyReport(mine.first.id, mine.first.tradeSymbol);
      } catch (e) {
        debugPrint('GenUI report detail failed: $e');
      }
      return _Reports(
        company: <ResearchCompanyReport>[
          for (final r in mine.take(5))
            ResearchCompanyReport(id: r.id, scripCode: r.scripCode, exchangeCode: r.exchangeCode, tradeSymbol: r.tradeSymbol, scripName: r.scripName, sector: r.sector, lastTradedPrice: r.lastTradedPrice, targetPrice: r.targetPrice, updatedTimestamp: r.reportDate, logoUrl: r.logoUrl, recommendation: r.recommendation, deeplinkUrl: r.deeplinkUrl),
        ],
        detail: detail,
      );
    }
    switch (_view) {
      case 'market':
        final a = await reports.fetchReportDetailList(0, 1, 10, 1); // market analysis
        List<OtherReport> extra = const <OtherReport>[];
        try {
          extra = (await reports.fetchReportDetailList(0, 2, 10, 1)).otherReports; // sector updates
        } catch (_) {}
        final merged = <OtherReport>[...a.otherReports, ...extra]..sort((x, y) => y.timestamp.compareTo(x.timestamp));
        if (merged.isEmpty) return _Reports(askAssistant: 'Summarise the latest Motilal Oswal market analysis and sector views');
        return _Reports(other: merged);
      case 'outlook':
        final landing = await ResearchRevampRepositoryImpl().fetchLanding(rr.ResearchSegment.EquitySegment);
        var cards = landing.hero.outlookCards;
        if (cards.isEmpty) {
          var o = (await reports.fetchReportDetailList(0, 4, 5, 1)).otherReports; // outlook reports
          if (o.isEmpty) o = (await reports.fetchReportDetailList(0, 1, 5, 1)).otherReports; // else latest market analysis
          if (o.isEmpty) return _Reports(askAssistant: 'What is the market outlook for today according to Motilal Oswal research?');
          return _Reports(other: o);
        }
        return _Reports(outlook: cards);
      default:
        final r = await reports.fetchReportDetailList(0, 0, 12, 1);
        return _Reports(company: r.companyReport);
    }
  }

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<_Reports>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: widget.ref != null && _view == 'company' ? '${widget.ref!.symbol} research' : 'Research reports',
          subtitle: 'Motilal Oswal Research',
          views: ResearchReportsCard.views,
          view: _view,
          onViewChanged: (v) {
            _view = v;
            _reload();
          },
          onRefresh: _reload,
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _body(context, snap.data!),
        ),
      );

  Widget _body(BuildContext context, _Reports r) {
    if (r.askAssistant != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        _note(context, widget.ref != null ? 'No published research report for ${widget.ref!.symbol} on UAT, so here is the Research Assistant\'s view.' : 'No published reports in this section on UAT, so here is the Research Assistant\'s view.'),
        ResearchAssistantCard(question: r.askAssistant!),
      ]);
    }
    if (r.detail != null) return _companyDetail(context, r);
    if (widget.ref != null && r.company.isNotEmpty && r.company.first.targetPrice == 0 && r.company.first.bulletSummary.isEmpty) {
      // The index knows a report exists but UAT has no body for it.
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        for (final c in r.company) _CompanyReportTile(report: c),
        _note(context, 'The report body is not available on UAT; asking the Research Assistant instead.'),
        ResearchAssistantCard(question: 'Give me a research snapshot of ${widget.ref!.name.isNotEmpty ? widget.ref!.name : widget.ref!.symbol}'),
      ]);
    }
    if (r.outlook.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        for (final o in r.outlook)
          Padding(
            padding: MOSpacing.paddingVertical6,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(o.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              if (o.publishedAt != 0) Text(_date(o.publishedAt), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              _bulletList(context, o.bulletSummary, max: 8),
              MOSpacing.verticalSpace6,
              _pdfButton(context, o.pdfDownloadUrl),
            ]),
          ),
      ]);
    }
    if (r.other.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        for (final o in r.other.take(8)) _OtherReportTile(report: o),
      ]);
    }
    if (r.company.isEmpty) return _note(context, 'No reports in this section on UAT.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      for (final c in r.company) _CompanyReportTile(report: c),
    ]);
  }

  Widget _companyDetail(BuildContext context, _Reports r) {
    final d = r.detail!;
    final upside = d.lastTradedPrice == 0 ? 0.0 : (d.targetPrice - d.lastTradedPrice) / d.lastTradedPrice * 100;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Row(children: <Widget>[
        Expanded(child: Text(d.scripName.isNotEmpty ? d.scripName : d.tradeSymbol, style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
        Text(_reco(d.recommendation), style: MOTypography.bodySmallSemibold.copyWith(color: _recoColor(context, d.recommendation))),
      ]),
      Text('${d.sector}${d.reportDate != 0 ? ' · ${_date(d.reportDate)}' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      MOSpacing.verticalSpace8,
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
        _kv(context, 'Target', '₹${_money(d.targetPrice)}'),
        _kv(context, 'Price at report', '₹${_money(d.lastTradedPrice)}'),
        _kv(context, 'Upside', _pct(upside), color: _delta(context, upside)),
      ]),
      MOSpacing.verticalSpace8,
      Text('Key points', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
      _bulletList(context, d.bulletSummary, max: 10),
      MOSpacing.verticalSpace8,
      Wrap(spacing: MOSpacing.spacing8, children: <Widget>[
        _pdfButton(context, d.pdfDownloadUrl),
        if (d.audioUrl.isNotEmpty) MOButton(label: 'Listen', onPressed: () => _openUrl(context, d.audioUrl), variant: MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small),
      ]),
      if (r.company.length > 1) ...<Widget>[
        MOSpacing.verticalSpace8,
        Text('Earlier reports', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
        for (final c in r.company.skip(1)) Text('${_date(c.updatedTimestamp)} · ${_reco(c.recommendation)} · target ₹${_money(c.targetPrice)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ],
    ]);
  }
}

class _CompanyReportTile extends StatefulWidget {
  const _CompanyReportTile({required this.report});
  final ResearchCompanyReport report;

  @override
  State<_CompanyReportTile> createState() => _CompanyReportTileState();
}

class _CompanyReportTileState extends State<_CompanyReportTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.report;
    final upside = c.lastTradedPrice == 0 ? 0.0 : (c.targetPrice - c.lastTradedPrice) / c.lastTradedPrice * 100;
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(c.scripName.isNotEmpty ? c.scripName : c.tradeSymbol, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                Text('${c.sector}${c.updatedTimestamp != 0 ? ' · ${_date(c.updatedTimestamp)}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text(_reco(c.recommendation), style: MOTypography.bodySmallSemibold.copyWith(color: _recoColor(context, c.recommendation))),
              Text('Target ₹${_money(c.targetPrice)} (${_pct(upside)})', style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, upside))),
            ])),
          if (_open) ...<Widget>[
            _bulletList(context, c.bulletSummary, max: 8),
            MOSpacing.verticalSpace6,
            _pdfButton(context, c.pdfDownloadUrl),
          ],
        ]),
      ),
    );
  }
}

class _OtherReportTile extends StatefulWidget {
  const _OtherReportTile({required this.report});
  final OtherReport report;

  @override
  State<_OtherReportTile> createState() => _OtherReportTileState();
}

class _OtherReportTileState extends State<_OtherReportTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.report;
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(o.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
          Text('${_date(o.timestamp)}${o.summary.isNotEmpty ? ' · ${o.summary}' : ''}', maxLines: _open ? 6 : 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          if (_open) ...<Widget>[
            _bulletList(context, o.bulletSummary, max: 8),
            if (o.stocksInFocus.isNotEmpty) ...<Widget>[
              MOSpacing.verticalSpace6,
              Text('Stocks in focus', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Wrap(spacing: MOSpacing.spacing6, runSpacing: MOSpacing.spacing4, children: <Widget>[
                for (final s in o.stocksInFocus.take(8))
                  Chip(label: Text('${s.tradeSymbol} ${s.ltpChangePer == 0 ? '' : _pct(s.ltpChangePer)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: _delta(context, s.ltpChangePer))), visualDensity: VisualDensity.compact),
              ]),
            ],
            MOSpacing.verticalSpace6,
            _pdfButton(context, o.pdfDownloadUrl),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ready-to-invest portfolios and research experts (from the research landing)
// ---------------------------------------------------------------------------

/// "Show ready-made stock portfolios", "research baskets".
class ReadyPortfoliosCard extends StatefulWidget {
  const ReadyPortfoliosCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['stocks', 'experts', 'funds'];

  @override
  State<ReadyPortfoliosCard> createState() => _ReadyPortfoliosCardState();
}

class _ReadyPortfoliosCardState extends State<ReadyPortfoliosCard> {
  late String _view = ReadyPortfoliosCard.views.contains(widget.view) ? widget.view! : 'stocks';
  late Future<rr.ResearchLandingResponse> _future = ResearchRevampRepositoryImpl().fetchLanding(rr.ResearchSegment.EquitySegment);

  @override
  Widget build(BuildContext context) => FutureBuilder<rr.ResearchLandingResponse>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Ready-to-invest portfolios',
          subtitle: 'Research-built baskets you can buy in one go',
          views: ReadyPortfoliosCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = ResearchRevampRepositoryImpl().fetchLanding(rr.ResearchSegment.EquitySegment, fresh: true);
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _body(context, snap.data!.portfolioBaskets),
        ),
      );

  Widget _body(BuildContext context, rr.PortfolioBaskets b) {
    switch (_view) {
      case 'experts':
        if (b.expertBaskets.isEmpty) return _note(context, 'No expert baskets are listed on UAT.');
        return Column(children: <Widget>[
          for (final e in b.expertBaskets)
            _tile(context, e.name, '${e.raManager.isNotEmpty ? 'by ${e.raManager} · ' : ''}${e.horizon}', e.minInvestmentAmount.toInt() == 0 ? '' : 'Min ₹${_money(e.minInvestmentAmount.toInt() / 100)}', null),
        ]);
      case 'funds':
        if (b.mfBaskets.isEmpty) return _note(context, 'No fund baskets are listed on UAT.');
        return Column(children: <Widget>[
          for (final m in b.mfBaskets)
            _tile(context, m.name, '${m.risk} risk · ${m.equityPercentage}% equity · ${m.debtPercentage}% debt', 'Min SIP ₹${_money(m.minSip.toInt() / 100)}', m.threeYearReturns == 0 ? null : (_pct(m.threeYearReturns / 100), '3Y')),
        ]);
    }
    if (b.equityBaskets.isEmpty) return _note(context, 'No research stock baskets are listed on UAT. Say "stock baskets" for the Baskets catalogue.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      for (final e in b.equityBaskets)
        _tile(context, e.name, '${e.analyst.isNotEmpty ? 'by ${e.analyst} · ' : ''}${e.volatility.name.replaceAll('Volatility', '')} volatility${e.description.isNotEmpty ? '\n${e.description}' : ''}', 'Min ₹${_money(e.minInvestmentAmt.toInt() / 100)}', (_pct(e.returnTillDate.toInt() / 100), 'since reco')),
      _note(context, 'To invest in one of these, say "invest in <basket name>" and the Baskets card takes over.'),
    ]);
  }

  Widget _tile(BuildContext context, String title, String sub, String min, (String, String)? ret) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              Text(sub, maxLines: 3, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              if (min.isNotEmpty) Text(min, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            ]),
          ),
          if (ret != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text(ret.$1, style: MOTypography.bodySmallSemibold.copyWith(color: ret.$1.startsWith('−') ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal)),
              Text(ret.$2, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
            ]),
        ]),
      );
}

/// "Who are the research experts?"
class ResearchExpertsCard extends StatefulWidget {
  const ResearchExpertsCard({super.key});

  @override
  State<ResearchExpertsCard> createState() => _ResearchExpertsCardState();
}

class _ResearchExpertsCardState extends State<ResearchExpertsCard> {
  late Future<rr.ResearchLandingResponse> _future = ResearchRevampRepositoryImpl().fetchLanding(rr.ResearchSegment.EquitySegment);

  @override
  Widget build(BuildContext context) => FutureBuilder<rr.ResearchLandingResponse>(
        future: _future,
        builder: (context, snap) => CardFrame(
          title: 'Research experts',
          subtitle: 'The Motilal Oswal desk behind the calls and reports',
          onRefresh: () => setState(() {
            _future = ResearchRevampRepositoryImpl().fetchLanding(rr.ResearchSegment.EquitySegment, fresh: true);
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : snap.data!.researchExperts.isEmpty
                      ? _note(context, 'No experts are listed on UAT.')
                      : Column(children: <Widget>[
                          for (final e in snap.data!.researchExperts)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: <Widget>[
                                CircleAvatar(radius: 20, backgroundColor: context.surfaceBackgroundNeutralFaded, foregroundImage: e.imageUrl.isEmpty ? null : NetworkImage(e.imageUrl), child: Text(e.name.isEmpty ? '?' : e.name[0], style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
                                MOSpacing.horizontalSpace12,
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                    Text(e.name, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                                    Text('${e.specialization}${e.experienceYears > 0 ? ' · ${e.experienceYears} yrs experience' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                                  ]),
                                ),
                              ]),
                            ),
                        ]),
        ),
      );
}

// ---------------------------------------------------------------------------
// Research Assistant: streamed answer from Motilal Oswal's research LLM
// ---------------------------------------------------------------------------

/// "Give me a research snapshot of JSL", "what does research say about IT sector".
class ResearchAssistantCard extends StatefulWidget {
  const ResearchAssistantCard({super.key, required this.question});
  final String question;

  @override
  State<ResearchAssistantCard> createState() => _ResearchAssistantCardState();
}

class _ResearchAssistantCardState extends State<ResearchAssistantCard> {
  final MoResearchAssistantImpl _repo = MoResearchAssistantImpl();
  String _status = '';
  final List<String> _sections = <String>[];
  List<String> _followUps = <String>[];
  String? _sessionId;
  String? _err;
  bool _done = false;
  StreamSubscription<StreamChatResponse>? _sub;
  late String _question = widget.question;

  @override
  void initState() {
    super.initState();
    _ask(_question);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _ask(String q) async {
    await _sub?.cancel();
    setState(() {
      _question = q;
      _status = '';
      _sections.clear();
      _followUps = <String>[];
      _err = null;
      _done = false;
    });
    try {
      if (_sessionId == null) {
        final profile = await SecureSharedPreference.getprofile() ?? '{}';
        final clientId = '${(jsonDecode(profile) as Map<String, dynamic>)['client_id'] ?? ''}';
        final s = await _repo.startSession(clientId);
        _sessionId = s.data?.sessionId ?? '';
      }
      final req = StreamChatRequest(text: q, sessionId: _sessionId ?? '', requestId: DateTime.now().millisecondsSinceEpoch.toString());
      _sub = _repo.getStreamChatResponse(sessionId: _sessionId, request: req).listen((r) {
        if (!mounted) return;
        setState(() {
          if ((r.data?.sessionId ?? '').isNotEmpty) _sessionId = r.data!.sessionId;
          final secs = r.data?.msg?.sections ?? const [];
          if (r.isFinalResponse) {
            if (secs.isNotEmpty) {
              _sections
                ..clear()
                ..addAll(secs.map((s) => '${(s.title ?? '').isNotEmpty ? '${s.title}\n' : ''}${s.content ?? ''}').where((t) => t.trim().isNotEmpty));
            }
            _followUps = r.data?.followUps.map((f) => '$f').toList() ?? <String>[];
            _done = true;
          } else if (r.isStreamingChunk) {
            final chunk = secs.isNotEmpty ? secs.map((s) => s.content ?? '').join() : r.message;
            if (chunk.trim().isNotEmpty && chunk != 'chunk') _status = chunk.trim();
          } else if (r.status.toLowerCase().contains('error') || r.code >= 400) {
            _err = r.message.isEmpty ? 'The assistant returned an error.' : r.message;
            _done = true;
          }
        });
      }, onError: (Object e) {
        if (mounted) setState(() {
          _err = '$e'.replaceFirst('Exception: ', '');
          _done = true;
        });
      }, onDone: () {
        if (mounted) setState(() => _done = true);
      });
    } catch (e) {
      if (mounted) setState(() {
        _err = '$e'.replaceFirst('Exception: ', '');
        _done = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _sections.join('\n\n');
    return CardFrame(
      title: 'Research Assistant',
      subtitle: _question,
      tag: 'MO Research AI',
      onRefresh: () => _ask(_question),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        if (_err != null)
          _error(context, _err!)
        else if (!_done)
          Row(children: <Widget>[
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            MOSpacing.horizontalSpace8,
            Expanded(child: Text(_status.isEmpty ? 'Reading Motilal Oswal research…' : _status.replaceAll(RegExp(r'\.{3,}$'), '…'), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
          ])
        else if (text.isEmpty)
          _note(context, 'The assistant returned nothing for this question.'),
        if (text.isNotEmpty)
          MarkdownBody(
            data: text,
            selectable: true,
            onTapLink: (_, href, __) => _openUrl(context, href ?? ''),
            styleSheet: MarkdownStyleSheet(
              p: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong),
              h1: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralStrong),
              h2: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralStrong),
              h3: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong),
              strong: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong),
              listBullet: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong),
              tableBody: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong),
              tableHead: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong),
              tableBorder: TableBorder.all(color: context.surfaceBackgroundNeutralFaded),
              tableColumnWidth: const IntrinsicColumnWidth(),
              blockquote: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal),
              horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: context.surfaceBackgroundNeutralFaded))),
            ),
          ),
        if (_followUps.isNotEmpty) ...<Widget>[
          MOSpacing.verticalSpace8,
          Wrap(spacing: MOSpacing.spacing6, runSpacing: MOSpacing.spacing4, children: <Widget>[
            for (final f in _followUps.take(4)) ActionChip(label: Text(f, style: MOTypography.bodyXsmallSemibold), onPressed: () => _ask(f)),
          ]),
        ],
        _note(context, 'Answered by Motilal Oswal\'s Research Assistant from published research. Not personalised advice.'),
      ]),
    );
  }

}

// ---------------------------------------------------------------------------
// Option Brain (Trading Guide Signals): research option strategies with legs
// ---------------------------------------------------------------------------

/// "Show Option Brain", "trading guide signals", "option strategy calls from research".
class OptionBrainCard extends StatefulWidget {
  const OptionBrainCard({super.key});

  @override
  State<OptionBrainCard> createState() => _OptionBrainCardState();
}

class _OptionBrainCardState extends State<OptionBrainCard> {
  late Future<AdviceResponse?> _future = getIt<OptionBrainRepository>().fetchOptionBrainData();

  @override
  Widget build(BuildContext context) => FutureBuilder<AdviceResponse?>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: 'Option Brain',
          subtitle: 'Trading Guide Signals: research option strategies',
          onRefresh: () => setState(() {
            _future = getIt<OptionBrainRepository>().fetchOptionBrainData();
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _body(context, snap.data),
        ),
      );

  Widget _body(BuildContext context, AdviceResponse? a) {
    if (a == null || (a.strategyEntry.isEmpty && a.entry.isEmpty)) {
      return _note(context, (a?.optionBrainMessage.isNotEmpty ?? false) ? a!.optionBrainMessage : 'No Option Brain strategies are live on UAT right now.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (a.optionBrainMessage.isNotEmpty) _note(context, a.optionBrainMessage),
      for (final s in a.strategyEntry.take(8))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[
              Expanded(child: Text('${s.tradeSymbol} · ${s.callType}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
              if (s.exitDate.toInt() != 0) Text('till ${_date(s.exitDate.toInt())}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
            ]),
            for (final leg in <StrategyLegInfo>[s.leg1, s.leg2, s.leg3, s.leg4])
              if (leg.scripName.isNotEmpty)
                Text('${leg.action == OrderAction.Buy ? 'Buy' : 'Sell'} ${leg.scripName}', style: MOTypography.bodyXsmallRegular.copyWith(color: leg.action == OrderAction.Buy ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal)),
            MOSpacing.verticalSpace4,
            Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing4, children: <Widget>[
              if (s.targetEntry != 0) _kv(context, 'Entry', '₹${_money(s.targetEntry)}'),
              if (s.targetExit != 0) _kv(context, 'Target', '₹${_money(s.targetExit)}', color: context.surfaceTextPositiveNormal),
              if (s.stopLoss != 0) _kv(context, 'Stop loss', '₹${_money(s.stopLoss)}', color: context.surfaceTextNegativeNormal),
              if (s.mpp != 0) _kv(context, 'Max profit potential', '₹${_money(s.mpp)}'),
            ]),
          ]),
        ),
      for (final e in a.entry.take(8))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('${e.action == OrderAction.Buy ? 'BUY' : 'SELL'} ${e.tradeSymbol}', style: MOTypography.bodySmallSemibold.copyWith(color: e.action == OrderAction.Buy ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal)),
                Text('${e.callType} · ${_date(e.recoDate)}${e.lotSize > 0 ? ' · lot ${e.lotSize}' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              Text('Entry ₹${_money(e.recoPrice)} · target ₹${_money(e.targetPrice)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
              if (e.stopLoss != 0) Text('SL ₹${_money(e.stopLoss)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNegativeNormal)),
            ])),
        ),
      if (a.disclaimer.isNotEmpty) _note(context, a.disclaimer),
      _note(context, 'Multi-leg strategies are placed from Option Brain in the classic app.'),
    ]);
  }
}
