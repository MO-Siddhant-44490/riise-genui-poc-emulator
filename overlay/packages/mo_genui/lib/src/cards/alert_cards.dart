import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/alert_store.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_genui/src/ui/genui_nav.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mo_portfolio_2_0/data/mo_portfolio_dashboard_repository_impl.dart';
import 'package:mo_research/data/mo_research_explore_repository_impl.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_add_fund/helper/add_fund_navigator.dart';
import 'package:trader_core/trader_core.dart';
import 'package:trader_proto_gen/News/NewsResponseModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteOverviewModels.pb.dart';
import 'package:trader_proto_gen/Recommendation/ResearchIdeasDashboard.pb.dart';

// ---------------------------------------------------------------------------------------------
// Alerts. The classic app's price alert is a web page (api/Url/PriceAlert → web view); there is
// no native alert API in the app. These cards keep rules on the device and watch the live feed
// while the AI view is open, and offer the classic page for a server-side alert.
// ---------------------------------------------------------------------------------------------

String _rs(num v) => '₹${NumberFormat('#,##,##0.00', 'en_IN').format(v)}';
String _n(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
TextStyle _h(BuildContext c) => MOTypography.bodySmallSemibold.copyWith(color: c.surfaceTextNeutralNormal);
TextStyle _b(BuildContext c) => MOTypography.bodySmallRegular.copyWith(color: c.surfaceTextNeutralNormal);
TextStyle _sub(BuildContext c) => MOTypography.bodyXsmallRegular.copyWith(color: c.surfaceTextNeutralStrong);
Widget _note(BuildContext c, String t) => Padding(padding: MOSpacing.paddingVertical4, child: Text(t, style: _sub(c)));
String _when(DateTime d) => DateFormat('d MMM, HH:mm').format(d);
String _newId() => 'a${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

Widget _chip(BuildContext c, String label, VoidCallback onTap, {bool negative = false}) => ActionChip(
      label: Text(label, style: MOTypography.labelSmallMediumAbc.copyWith(color: negative ? c.surfaceTextNegativeNormal : c.surfaceTextPrimaryNormal)),
      onPressed: onTap,
      backgroundColor: negative ? c.surfaceBackgroundNeutralFaded : c.surfaceBackgroundPrimaryFaded,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
    );

Widget _status(BuildContext c, AlertRule r) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: r.isTriggered ? c.surfaceBackgroundNeutralFaded : c.surfaceBackgroundPrimaryFaded,
        borderRadius: BorderRadius.circular(MOSpacing.spacing4),
      ),
      child: Text(r.isTriggered ? 'Triggered ${_when(r.triggeredAt!)}' : (r.live ? 'Watching live' : 'Subscribed'), style: MOTypography.bodyXsmallSemibold.copyWith(color: r.isTriggered ? c.surfaceTextPositiveNormal : c.surfaceTextPrimaryNormal)),
    );

/// Opens the classic price-alert web page for a stock (the server-side alert).
Future<void> openClassicAlert(BuildContext context, ScripRef s) async {
  try {
    final info = getIt<UserManager>().getLoginInfo();
    final res = await MoGetQuoteRepositoryImpl().setPriceAlert(clientCode: info.clientCode, scripCode: s.scripCode, exchangeCode: s.scripId.exchange.value);
    if (!context.mounted) return;
    AddFundNavigator.navigateToWebView(context, res.url, 'Set Alert');
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the classic alert page: $e')));
  }
}

Widget _onTrigger(BuildContext context, AlertRule r) {
  if (r.action.isEmpty || r.scrip == null) return const SizedBox.shrink();
  final q = '${r.action == 'sell' ? 'Sell' : 'Buy'} ${r.qty ?? ''} ${r.scrip!.symbol}'.replaceAll('  ', ' ');
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(children: <Widget>[
      Icon(Icons.bolt, size: 16, color: context.surfaceTextPrimaryNormal),
      MOSpacing.horizontalSpace6,
      Expanded(child: Text(r.isTriggered ? 'Order ready: $q' : 'On trigger: $q order opens, ready to place', style: _sub(context))),
      if (r.isTriggered) _chip(context, 'Open order', () => GenUiNav.ask(q)),
    ]),
  );
}

// ============================================================================================
// Price alert on a stock
// ============================================================================================

/// "Alert me when Yes Bank crosses ₹22": a rule watched on the live feed, with the distance to go.
class PriceAlertCard extends StatefulWidget {
  const PriceAlertCard({super.key, required this.scrip, this.condition, this.price, this.action, this.qty});
  final ScripRef scrip;
  final String? condition;
  final num? price;
  final String? action;
  final num? qty;

  @override
  State<PriceAlertCard> createState() => _PriceAlertCardState();
}

class _PriceAlertCardState extends State<PriceAlertCard> {
  AlertRule? _rule;

  @override
  void initState() {
    super.initState();
    if (widget.price != null && widget.price! > 0) {
      final cond = (widget.condition ?? '').toLowerCase().contains('below') || (widget.condition ?? '').toLowerCase().contains('under') || (widget.condition ?? '').toLowerCase().contains('fall') ? 'below' : 'above';
      _rule = AlertStore.upsert(AlertRule(
        id: _newId(),
        kind: 'price',
        scrip: widget.scrip,
        condition: cond,
        price: widget.price!.toDouble(),
        action: (widget.action ?? '').toLowerCase(),
        qty: widget.qty?.toInt(),
      ));
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<AlertRule>>(
        valueListenable: AlertStore.rules,
        builder: (context, rules, _) {
          final r = _rule == null ? null : AlertStore.byId(_rule!.id);
          return CardFrame(
            live: true,
            title: r == null ? 'Price alert · ${widget.scrip.symbol}' : r.title,
            subtitle: r == null ? 'Tell me the price, e.g. "alert me when ${widget.scrip.symbol} crosses ₹100"' : 'Watched on the live feed while RIISE is open',
            child: r == null
                ? _note(context, 'No price given, so nothing was set.')
                : LivePrice.scrip(
                    scrip: widget.scrip.scripId,
                    builder: (context, t) {
                      final ltp = (t?.ltp ?? 0) == 0 ? (r.lastPrice ?? 0) : t!.ltp;
                      final dist = ltp == 0 ? null : (r.price! - ltp) / ltp * 100;
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Row(children: <Widget>[
                          Expanded(child: Text(ltp == 0 ? 'Waiting for a price…' : 'Now ${_rs(ltp)}${dist == null ? '' : ' · ${dist.abs().toStringAsFixed(1)}% ${dist >= 0 ? 'below' : 'above'} the trigger'}', style: _b(context))),
                          _status(context, r),
                        ]),
                        if (r.isTriggered) ...<Widget>[
                          MOSpacing.verticalSpace4,
                          Text(r.note, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
                        ],
                        _onTrigger(context, r),
                        MOSpacing.verticalSpace8,
                        Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
                          _chip(context, 'Also set on the server (classic)', () => openClassicAlert(context, widget.scrip)),
                          _chip(context, 'My alerts', () => GenUiNav.ask('Show my alerts')),
                          _chip(context, 'Remove', () => AlertStore.remove(r.id), negative: true),
                        ]),
                        _note(context, 'Device alerts fire while RIISE is open. The classic page sets one that the server watches and pushes.'),
                      ]);
                    },
                  ),
          );
        },
      );
}

// ============================================================================================
// Smart alert on a group of stocks, with a prepared order
// ============================================================================================

/// "Alert me if any of my bank stocks falls 5% in a day. If HDFC Bank goes below ₹1,850, get a
/// buy order ready for 5 more." → a group rule plus an optional price rule with an order.
class SmartAlertCard extends StatefulWidget {
  const SmartAlertCard({super.key, this.group, this.scrips = const <ScripRef>[], this.pct, this.direction, this.orderScrip, this.orderPrice, this.orderCondition, this.action, this.qty});
  final String? group;
  final List<ScripRef> scrips;
  final num? pct;
  final String? direction;
  final ScripRef? orderScrip;
  final num? orderPrice;
  final String? orderCondition;
  final String? action;
  final num? qty;

  @override
  State<SmartAlertCard> createState() => _SmartAlertCardState();
}

class _SmartAlertCardState extends State<SmartAlertCard> {
  Future<(AlertRule?, AlertRule?)>? _future;

  Future<List<ScripRef>> _members() async {
    if (widget.scrips.isNotEmpty) return widget.scrips;
    final g = (widget.group ?? 'holdings').toLowerCase();
    final holdings = (await MoPortfolioDashBoardRepositoryImpl().getEquityDetailAPI(loadFromCache: false)).holdings;
    final all = <ScripRef>[for (final h in holdings) if (h.scripId != null && h.scripId!.scripCode != 0) GenUiNav.refOf(h.scripId!, h.tradeSymbol, h.companyName)];
    bool bank(ScripRef s) => RegExp(r'bank|finan|fin\b|nbfc|capital|insur', caseSensitive: false).hasMatch('${s.symbol} ${s.name}');
    bool it(ScripRef s) => RegExp(r'infy|tcs|wipro|hcl|tech|info|soft|digital', caseSensitive: false).hasMatch('${s.symbol} ${s.name}');
    if (g.contains('bank') || g.contains('financ')) return all.where(bank).toList();
    if (g.contains(' it') || g.startsWith('it') || g.contains('tech')) return all.where(it).toList();
    return all;
  }

  Future<(AlertRule?, AlertRule?)> _create() async {
    final members = await _members();
    AlertRule? groupRule;
    // The model may write the fall as a negative number ("-5"); the sign is the direction.
    if (widget.pct != null && widget.pct != 0 && members.isNotEmpty) {
      final dir = (widget.direction ?? '').toLowerCase();
      groupRule = AlertStore.upsert(AlertRule(
        id: _newId(),
        kind: 'smart',
        scrips: members,
        group: (widget.group ?? '').isEmpty ? 'my holdings' : widget.group!,
        condition: dir.contains('rise') || dir.contains('up') || dir.contains('gain') || (dir.isEmpty && widget.pct! > 0) ? 'rises' : 'falls',
        pct: widget.pct!.abs().toDouble(),
      ));
    }
    AlertRule? orderRule;
    if (widget.orderScrip != null && widget.orderPrice != null && widget.orderPrice! > 0) {
      final c = (widget.orderCondition ?? '').toLowerCase();
      orderRule = AlertStore.upsert(AlertRule(
        id: _newId(),
        kind: 'price',
        scrip: widget.orderScrip,
        condition: c.contains('above') || c.contains('cross') || c.contains('over') ? 'above' : 'below',
        price: widget.orderPrice!.toDouble(),
        action: (widget.action ?? 'buy').toLowerCase(),
        qty: widget.qty?.toInt(),
      ));
    }
    return (groupRule, orderRule);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(AlertRule?, AlertRule?)>(
        future: _future ??= _create(),
        builder: (context, snap) => ValueListenableBuilder<List<AlertRule>>(
          valueListenable: AlertStore.rules,
          builder: (context, rules, _) {
            final g = snap.data?.$1 == null ? null : AlertStore.byId(snap.data!.$1!.id);
            final o = snap.data?.$2 == null ? null : AlertStore.byId(snap.data!.$2!.id);
            return CardFrame(
              live: true,
              title: 'Smart alert',
              subtitle: g == null && o == null ? 'Say what to watch, e.g. "alert me if any of my bank stocks falls 5% in a day"' : 'Rules watched on the live feed while RIISE is open',
              child: snap.hasError
                  ? Text('${snap.error}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal))
                  : snap.connectionState != ConnectionState.done
                      ? const CardLoading(text: 'Resolving the group…')
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          if (g == null && o == null) _note(context, 'Nothing was set: I need a percentage for the group, or a price for the order.'),
                          if (g != null) ...<Widget>[
                            Row(children: <Widget>[Expanded(child: Text(g.title, style: _h(context))), _status(context, g)]),
                            if (g.isTriggered) Text(g.note, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
                            MOSpacing.verticalSpace4,
                            for (final s in g.scrips.take(8))
                              LivePrice.scrip(
                                scrip: s.scripId,
                                builder: (context, t) => AdaptiveRow(
                                  leading: Text(s.symbol, style: _b(context)),
                                  trailing: Text(
                                    t == null || t.ltp == 0 ? '—' : '${_rs(t.ltp)} · ${t.perChange < 0 ? '' : '+'}${t.perChange.toStringAsFixed(2)}% today',
                                    style: MOTypography.bodyXsmallSemibold.copyWith(color: t == null ? context.surfaceTextNeutralStrong : (t.perChange < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal)),
                                  ),
                                ),
                              ),
                            if (g.scrips.length > 8) _note(context, '… and ${g.scrips.length - 8} more'),
                            Wrap(spacing: 8, children: <Widget>[_chip(context, 'Remove group alert', () => AlertStore.remove(g.id), negative: true)]),
                          ],
                          if (g != null && o != null) const Divider(height: 20),
                          if (o != null) ...<Widget>[
                            Row(children: <Widget>[Expanded(child: Text(o.title, style: _h(context))), _status(context, o)]),
                            LivePrice.scrip(
                              scrip: o.scrip!.scripId,
                              builder: (context, t) => Text(t == null || t.ltp == 0 ? 'Waiting for a price…' : 'Now ${_rs(t.ltp)} · trigger ${_rs(o.price!)}', style: _sub(context)),
                            ),
                            if (o.isTriggered) Text(o.note, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
                            _onTrigger(context, o),
                            MOSpacing.verticalSpace4,
                            Wrap(spacing: 8, children: <Widget>[
                              _chip(context, 'Also set on the server (classic)', () => openClassicAlert(context, o.scrip!)),
                              _chip(context, 'Remove', () => AlertStore.remove(o.id), negative: true),
                            ]),
                          ],
                          _note(context, 'The order is prepared, never placed by itself: when the rule fires, the ticket opens with these details for you to confirm.'),
                        ]),
            );
          },
        ),
      );
}

// ============================================================================================
// Results alert and research-report subscription
// ============================================================================================

/// "Email me when HDFC Bank posts results": a subscription on the device, checked against the
/// stock's news feed. Email delivery needs a backend the POC does not have, and the card says so.
class ResultsAlertCard extends StatefulWidget {
  const ResultsAlertCard({super.key, required this.scrip, this.email = true});
  final ScripRef scrip;
  final bool email;

  @override
  State<ResultsAlertCard> createState() => _ResultsAlertCardState();
}

class _ResultsAlertCardState extends State<ResultsAlertCard> {
  late final AlertRule _rule = AlertStore.upsert(AlertRule(id: _newId(), kind: 'results', scrip: widget.scrip, email: widget.email));
  Future<List<NewsEntry>>? _future;

  Future<List<NewsEntry>> _load() async {
    final QuoteOverviewResponse o = await MoGetQuoteRepositoryImpl().fetchQuoteOverviewData(symbol: widget.scrip.symbol.replaceAll('&', '%26'), sections: <String>['News']);
    final items = o.news.news.where((n) => RegExp(r'result|quarter|\bQ[1-4]\b|profit|revenue|earnings', caseSensitive: false).hasMatch('${n.title} ${n.description}')).toList();
    final r = AlertStore.byId(_rule.id);
    if (r != null && !r.isTriggered && items.isNotEmpty) {
      final latest = items.first;
      final ts = latest.newsDateTime > 100000000000 ? latest.newsDateTime : latest.newsDateTime * 1000;
      if (ts > 0 && DateTime.fromMillisecondsSinceEpoch(ts).isAfter(r.createdAt.subtract(const Duration(days: 1)))) {
        AlertEngine.fire(r, latest.title);
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<NewsEntry>>(
        future: _future ??= _load(),
        builder: (context, snap) => ValueListenableBuilder<List<AlertRule>>(
          valueListenable: AlertStore.rules,
          builder: (context, rules, _) {
            final r = AlertStore.byId(_rule.id);
            return CardFrame(
              title: 'Results alert · ${widget.scrip.symbol}',
              subtitle: widget.email ? 'You asked for an email when results are posted' : 'You asked to be told when results are posted',
              onRefresh: () => setState(() => _future = null),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                if (r != null) Row(children: <Widget>[Expanded(child: Text(r.title, style: _h(context))), _status(context, r)]),
                if (r?.isTriggered == true) Text(r!.note, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPositiveNormal)),
                MOSpacing.verticalSpace6,
                if (snap.connectionState != ConnectionState.done)
                  const CardLoading(text: 'Checking the latest results news…')
                else if (snap.hasError)
                  _note(context, 'Could not read the news feed: ${snap.error}')
                else if (snap.data!.isEmpty)
                  _note(context, 'No results news for ${widget.scrip.symbol} on the feed yet. I will mark this alert when one appears.')
                else ...<Widget>[
                  Text('Latest results news', style: _h(context)),
                  for (final n in snap.data!.take(3))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: _b(context)),
                        if (n.newsDateTime != 0) Text(DateFormat('d MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(n.newsDateTime > 100000000000 ? n.newsDateTime : n.newsDateTime * 1000)), style: _sub(context)),
                      ]),
                    ),
                ],
                MOSpacing.verticalSpace6,
                Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
                  _chip(context, 'Financials', () => GenUiNav.openStock(widget.scrip, view: 'financials')),
                  _chip(context, 'My alerts', () => GenUiNav.ask('Show my alerts')),
                  if (r != null) _chip(context, 'Remove', () => AlertStore.remove(r.id), negative: true),
                ]),
                _note(context, widget.email ? 'Email delivery needs the alert service that is not part of this POC; the subscription is recorded here and shows in the AI view.' : 'Recorded on this device; you will see it in the AI view.'),
              ]),
            );
          },
        ),
      );
}

/// "Mail me research reports on Infosys and TCS as soon as they're out": one subscription per
/// stock, with the latest report the desk has published on each.
class ReportSubCard extends StatefulWidget {
  const ReportSubCard({super.key, required this.scrips, this.email = true});
  final List<ScripRef> scrips;
  final bool email;

  @override
  State<ReportSubCard> createState() => _ReportSubCardState();
}

class _ReportSubCardState extends State<ReportSubCard> {
  late final AlertRule? _rule = widget.scrips.isEmpty ? null : AlertStore.upsert(AlertRule(id: _newId(), kind: 'report', scrips: widget.scrips, email: widget.email));
  Future<Map<String, ResearchReportSearchData?>>? _future;

  Future<Map<String, ResearchReportSearchData?>> _load() async {
    final out = <String, ResearchReportSearchData?>{};
    final explore = MoResearchExploreRepositoryImpl();
    for (final s in widget.scrips) {
      try {
        final sr = await explore.searchScrip(s.symbol);
        final mine = sr.reports.where((r) => r.tradeSymbol.toUpperCase() == s.symbol.toUpperCase() || r.scripCode == int.tryParse(s.scripCode)).toList()..sort((a, b) => b.reportDate.compareTo(a.reportDate));
        out[s.symbol] = mine.isEmpty ? null : mine.first;
      } catch (e) {
        debugPrint('GenUI report sub: $e');
        out[s.symbol] = null;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, ResearchReportSearchData?>>(
        future: _future ??= _load(),
        builder: (context, snap) => ValueListenableBuilder<List<AlertRule>>(
          valueListenable: AlertStore.rules,
          builder: (context, rules, _) {
            final r = _rule == null ? null : AlertStore.byId(_rule!.id);
            return CardFrame(
              title: 'Research reports · ${widget.scrips.map((s) => s.symbol).join(', ')}',
              subtitle: widget.scrips.isEmpty ? 'Name the stocks, e.g. "mail me research reports on Infosys and TCS"' : (widget.email ? 'You asked for new reports by email' : 'You asked to be told about new reports'),
              onRefresh: () => setState(() => _future = null),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                if (r != null) Row(children: <Widget>[Expanded(child: Text(r.title, style: _h(context))), _status(context, r)]),
                MOSpacing.verticalSpace6,
                if (widget.scrips.isEmpty)
                  _note(context, 'No stocks given, so nothing was subscribed.')
                else if (snap.connectionState != ConnectionState.done)
                  const CardLoading(text: 'Finding the latest reports…')
                else ...<Widget>[
                  Text('Latest from the desk', style: _h(context)),
                  for (final s in widget.scrips)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: AdaptiveRow(
                        leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text(s.symbol, style: _b(context)),
                          Text(
                            snap.data?[s.symbol] == null ? 'No report on the research index yet' : '${snap.data![s.symbol]!.title}${snap.data![s.symbol]!.recommendation.name == 'Hold' ? '' : ' · ${snap.data![s.symbol]!.recommendation.name}'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: _sub(context),
                          ),
                        ]),
                        trailing: Text(snap.data?[s.symbol] == null || snap.data![s.symbol]!.reportDate == 0 ? '' : DateFormat('d MMM yy').format(DateTime.fromMillisecondsSinceEpoch(snap.data![s.symbol]!.reportDate * 1000)), style: _sub(context)),
                        end: InkWell(onTap: () => GenUiNav.ask('Research report on ${s.symbol}'), child: Icon(Icons.chevron_right, size: 18, color: context.surfaceIconNeutralNormal)),
                      ),
                    ),
                ],
                MOSpacing.verticalSpace6,
                Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
                  _chip(context, 'My alerts', () => GenUiNav.ask('Show my alerts')),
                  if (r != null) _chip(context, 'Remove', () => AlertStore.remove(r.id), negative: true),
                ]),
                _note(context, widget.email ? 'Email delivery needs the report-subscription service that is not part of this POC; the subscription is recorded here, and the AI view raises a research alert when the desk publishes on a stock you follow.' : 'Recorded on this device.'),
              ]),
            );
          },
        ),
      );
}

// ============================================================================================
// My alerts
// ============================================================================================

/// Every rule on the device, with its state and a way to drop it.
class AlertsCard extends StatelessWidget {
  const AlertsCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['all', 'price', 'smart', 'results', 'reports'];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<AlertRule>>(
        valueListenable: AlertStore.rules,
        builder: (context, rules, _) {
          final v = views.contains(view) ? view! : 'all';
          final list = rules.where((r) => v == 'all' || r.kind == (v == 'reports' ? 'report' : v)).toList().reversed.toList();
          return _AlertsBody(view: v, rules: list);
        },
      );
}

class _AlertsBody extends StatefulWidget {
  const _AlertsBody({required this.view, required this.rules});
  final String view;
  final List<AlertRule> rules;

  @override
  State<_AlertsBody> createState() => _AlertsBodyState();
}

class _AlertsBodyState extends State<_AlertsBody> {
  late String _view = widget.view;

  @override
  Widget build(BuildContext context) {
    final rules = _view == widget.view ? widget.rules : AlertStore.rules.value.where((r) => _view == 'all' || r.kind == (_view == 'reports' ? 'report' : _view)).toList().reversed.toList();
    final fired = rules.where((r) => r.isTriggered).length;
    return CardFrame(
      live: rules.any((r) => r.live && !r.isTriggered),
      title: 'My alerts',
      subtitle: rules.isEmpty ? 'Nothing set yet' : '${rules.length} alert${rules.length == 1 ? '' : 's'}${fired == 0 ? '' : ' · $fired triggered'}',
      views: AlertsCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      child: rules.isEmpty
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Set one by asking, for example:', style: _b(context)),
              MOSpacing.verticalSpace6,
              Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                for (final q in const <String>['Alert me when Yes Bank crosses ₹22', 'Alert me if any of my bank stocks falls 5% in a day', 'Email me when HDFC Bank posts results', 'Mail me research reports on Infosys and TCS'])
                  _chip(context, q, () => GenUiNav.ask(q)),
              ]),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              for (final r in rules)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    AdaptiveRow(
                      leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text(r.title, style: _h(context)),
                        Text(r.isTriggered && r.note.isNotEmpty ? r.note : 'Set ${_when(r.createdAt)}${r.lastPrice == null ? '' : ' · last ${_rs(r.lastPrice!)}'}', maxLines: 2, overflow: TextOverflow.ellipsis, style: _sub(context)),
                      ]),
                      trailing: _status(context, r),
                      end: InkWell(onTap: () => AlertStore.remove(r.id), child: Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.close, size: 16, color: context.surfaceIconNeutralNormal))),
                    ),
                    _onTrigger(context, r),
                  ]),
                ),
              MOSpacing.verticalSpace6,
              Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
                _chip(context, 'Clear all', AlertStore.clear, negative: true),
              ]),
              _note(context, 'Price and group alerts are watched on the live feed while RIISE is open. For server-side alerts, open the classic alert page from a price alert.'),
            ]),
    );
  }
}
