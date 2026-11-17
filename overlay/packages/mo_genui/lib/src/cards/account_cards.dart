import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_report/pnl_report/data/pnl_report_repository_impl.dart';
import 'package:mo_report/pnl_report/domain/model/pnl_report_overview_summary_model.dart';
import 'package:mo_stock_basket/domain/mo_stock_basket_repository.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/preferences.dart';
import 'package:mosl_security/prefs/rise_shared_preference.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_proto_gen/BasketRevamp/BasketRevampModels.pb.dart' as br;
import 'package:trader_proto_gen/User/UserInfo.pb.dart';
import 'package:trader_proto_gen/User/UserProfileModels.pb.dart';
import 'package:trader_user_login_profile/profile_setting/domain/profile_repository.dart';

/// Account cards: P&L, baskets, profile and settings. Each reads the same
/// repository the classic screen reads.

String _m(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
Widget _sub(BuildContext c, String t) => Text(t, style: MOTypography.bodyXsmallRegular.copyWith(color: c.surfaceTextNeutralStrong));

// --------------------------------------------------------------------- P&L

class PnlCard extends StatefulWidget {
  const PnlCard({super.key, this.period});
  final String? period; // fy | lastfy | 1y | all
  static const List<String> views = <String>['fy', 'lastfy', '1y', 'all'];

  @override
  State<PnlCard> createState() => _PnlCardState();
}

class _PnlCardState extends State<PnlCard> {
  late String _view = PnlCard.views.contains(widget.period) ? widget.period! : 'fy';
  final Map<String, Future<PnlReportOverviewSummaryModel>> _futures = <String, Future<PnlReportOverviewSummaryModel>>{};

  (DateTime, DateTime) _range(String v) {
    final now = DateTime.now();
    final fyStart = DateTime(now.month >= 4 ? now.year : now.year - 1, 4, 1);
    return switch (v) {
      'lastfy' => (DateTime(fyStart.year - 1, 4, 1), DateTime(fyStart.year, 3, 31)),
      '1y' => (now.subtract(const Duration(days: 365)), now),
      'all' => (DateTime(2000, 4, 1), now),
      _ => (fyStart, now),
    };
  }

  Future<PnlReportOverviewSummaryModel> _load(String v) => _futures.putIfAbsent(v, () async {
        // Same request the classic P&L report sends; the client id comes from the stored profile.
        final profile = await SecureSharedPreference.getprofile() ?? '{}';
        final id = int.tryParse('${(jsonDecode(profile) as Map<String, dynamic>)['client_id'] ?? ''}') ?? 0;
        final (from, to) = _range(v);
        return PnlReportRepositoryImpl().getOverviewData(
          request: PnlReportOverviewRequest(type: 'allSummaryV1', id: id, fromDate: DateFormat('yyyy-MM-dd').format(from), toDate: DateFormat('yyyy-MM-dd').format(to), isFamily: false),
        );
      });

  @override
  Widget build(BuildContext context) {
    final (from, to) = _range(_view);
    return CardFrame(
      title: 'Profit & loss',
      subtitle: '${DateFormat('d MMM yy').format(from)} – ${DateFormat('d MMM yy').format(to)}',
      views: PnlCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: () => setState(() => _futures.remove(_view)),
      child: FutureBuilder<PnlReportOverviewSummaryModel>(
        future: _load(_view),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching P&L…');
          final r = snap.data;
          if (snap.hasError || r == null) return CardError(title: "Couldn't load P&L.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _futures.remove(_view)));
          if (r.data.isEmpty) return _sub(context, 'No realised P&L in this period.');
          final total = r.data.fold<double>(0, (a, d) => a + d.gainLoss);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            _sub(context, 'Realised gain / loss'),
            Text(signed(total), style: MOTypography.headingSmall.copyWith(color: deltaColor(context, total))),
            MOSpacing.verticalSpace6,
            for (final d in r.data)
              Padding(
                padding: MOSpacing.paddingVertical4,
                child: Row(children: <Widget>[
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text(d.displayName.isEmpty ? d.assetsType : d.displayName, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                      _sub(context, 'ST ${signed(d.shortTermGainLoss)} · LT ${signed(d.longTermGainLoss)}${d.intraday != 0 ? ' · intraday ${signed(d.intraday)}' : ''}${d.dividend != 0 ? ' · dividend ₹${_m(d.dividend)}' : ''}'),
                    ]),
                  ),
                  Text(signed(d.gainLoss), style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, d.gainLoss))),
                ]),
              ),
            _sub(context, 'Unrealised P&L is on the portfolio card. Charges and STT per the full report.'),
          ]);
        },
      ),
    );
  }
}

// ----------------------------------------------------------------- baskets

class BasketsCard extends StatefulWidget {
  const BasketsCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['mine', 'explore'];

  @override
  State<BasketsCard> createState() => _BasketsCardState();
}

class _BasketsCardState extends State<BasketsCard> {
  late String _view = BasketsCard.views.contains(widget.view) ? widget.view! : 'mine';
  Future<br.DashboardResponse>? _future;
  int? _open;
  Future<dynamic>? _detail;

  @override
  Widget build(BuildContext context) => CardFrame(
        title: _view == 'mine' ? 'My baskets' : 'Explore baskets',
        views: BasketsCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() => _future = null),
        child: FutureBuilder<br.DashboardResponse>(
          future: _future ??= getIt<MoStockBasketRepository>().loadStockBasketData(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching baskets…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load baskets.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _future = null));
            final val = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
            if (_view == 'mine') {
              final s = r.overallSummary;
              if (s.basketCount == 0) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[_sub(context, 'You have no basket investments yet.'), TextButton(onPressed: () => setState(() => _view = 'explore'), child: const Text('Explore baskets'))]);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                _sub(context, '${s.basketCount} baskets · current value'),
                Text('₹${_m(s.marketValue)}', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
                Text('${signed(s.overallPnl)} (${pct(s.overallPnlPer)}) overall · today ${signed(s.dayPnl)}', style: MOTypography.bodyXsmallSemibold.copyWith(color: deltaColor(context, s.overallPnl))),
                _sub(context, 'Invested ₹${_m(s.investedValue)}'),
                if (r.repairRebalanceDetails.isNotEmpty) ...<Widget>[MOSpacing.verticalSpace6, for (final e in r.repairRebalanceDetails) _sub(context, '${e.basketName}: ${e.action.name} due')],
              ]);
            }
            final list = <br.BasketInfoV4>[...r.recommendedBaskets, ...r.trending, ...r.all].fold<Map<int, br.BasketInfoV4>>(<int, br.BasketInfoV4>{}, (m, b) => m..putIfAbsent(b.basketId, () => b)).values.take(10).toList();
            if (list.isEmpty) return _sub(context, 'No baskets available.');
            return Column(children: <Widget>[
              for (final b in list) ...<Widget>[
                InkWell(
                  onTap: () => setState(() {
                    _open = _open == b.basketId ? null : b.basketId;
                    _detail = _open == null ? null : getIt<MoStockBasketRepository>().fetchBasketDetailsData(b.basketId);
                  }),
                  child: Padding(
                    padding: MOSpacing.paddingVertical6,
                    child: Row(children: <Widget>[
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text(b.name, style: val),
                          _sub(context, '${b.analyst.isEmpty ? '' : '${b.analyst} · '}${b.scripCount} stocks · min ₹${_m(b.minInvestmentAmt)}'),
                        ]),
                      ),
                      Text('${signed(b.returnTillDate)}%', style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, b.returnTillDate))),
                      Icon(_open == b.basketId ? Icons.expand_less : Icons.expand_more, size: 18, color: context.surfaceIconNeutralNormal),
                    ]),
                  ),
                ),
                if (_open == b.basketId)
                  FutureBuilder<dynamic>(
                    future: _detail,
                    builder: (context, ds) {
                      if (ds.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching constituents…');
                      final d = ds.data;
                      if (d == null) return _sub(context, 'No details.');
                      final cons = (d.constituents as List<dynamic>);
                      return Padding(
                        padding: EdgeInsets.only(left: MOSpacing.spacing12, bottom: MOSpacing.spacing6),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          if (b.description.isNotEmpty) _sub(context, b.description),
                          for (final c in cons.take(12)) _sub(context, '${c.scripQuote.tradeSymbol} · ${(c.weightage as double).toStringAsFixed(1)}%'),
                          _sub(context, 'Investing in a basket goes through the basket order flow, which is not in the AI view yet.'),
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

// ----------------------------------------------------------------- profile

class ProfileCard extends StatefulWidget {
  const ProfileCard({super.key});

  @override
  State<ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<ProfileCard> {
  Future<UserProfileDataV3>? _future;

  String _mask(String v, {int keep = 4}) => v.length <= keep ? v : '${'•' * (v.length - keep)}${v.substring(v.length - keep)}';
  String _maskEmail(String e) {
    final at = e.indexOf('@');
    if (at <= 1) return e;
    return '${e[0]}${'•' * (at - 1)}${e.substring(at)}';
  }

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'My profile & plan',
        onRefresh: () => setState(() => _future = null),
        child: FutureBuilder<UserProfileDataV3>(
          future: _future ??= getIt<ProfileRepo>().getProfileData(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final p = snap.data;
            if (snap.hasError || p == null) return CardError(title: "Couldn't load your profile.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _future = null));
            final rows = <MapEntry<String, String>>[
              MapEntry('Client code', Preferences.getClientId()),
              if (p.personal.emailId.isNotEmpty) MapEntry('Email', _maskEmail(p.personal.emailId)),
              if (p.personal.mobileNo.isNotEmpty) MapEntry('Mobile', _mask(p.personal.mobileNo)),
              if (p.personal.panNumber.isNotEmpty) MapEntry('PAN', _mask(p.personal.panNumber)),
              if (p.trading.segment.isNotEmpty) MapEntry('Segments', p.trading.segment),
              if (p.trading.dpId.isNotEmpty) MapEntry('Demat (${p.trading.depositoryName})', _mask(p.trading.dpId)),
              if (p.trading.ddpi.isNotEmpty) MapEntry('DDPI', p.trading.ddpi),
              for (final b in p.bank) MapEntry('${b.bankName}${b.isPrimary.toLowerCase() == 'y' || b.isPrimary.toLowerCase() == 'true' ? ' (primary)' : ''}', _mask(b.accountNumber)),
              for (final n in p.nomineeDetails) MapEntry('Nominee', '${n.nomineeName} · ${n.relationship} · ${n.nomineePer}%'),
              if (p.nomineeDetails.isEmpty && p.trading.firstNominee.isNotEmpty) MapEntry('Nominee', p.trading.firstNominee),
            ];
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              for (final r in rows)
                Padding(
                  padding: MOSpacing.paddingVertical4,
                  child: Row(children: <Widget>[Expanded(child: Text(r.key, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))), Flexible(child: Text(r.value, textAlign: TextAlign.end, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)))]),
                ),
              MOSpacing.verticalSpace6,
              _sub(context, 'Brokerage plan: ask "charges to buy <stock>" to see your plan\'s rates. The app has no separate plan API. Editing contact, bank or nominee details uses the e-modification web journey, not hosted here yet.'),
            ]);
          },
        ),
      );
}

// ---------------------------------------------------------------- settings

/// The API-backed account settings (same `UserSettings` the classic Settings
/// screen saves through `ProfileRepo.saveSettings`). Theme and biometrics are
/// device-local in the classic app and are not exposed here.
class SettingsCard extends StatefulWidget {
  const SettingsCard({super.key});

  @override
  State<SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<SettingsCard> {
  late UserSettings _s = Preferences.userConfigPref.get().settings.deepCopy();
  bool _saving = false;
  String _status = '';

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = 'Saving…';
    });
    try {
      final res = await getIt<ProfileRepo>().saveSettings(_s);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _status = res.fold((e) => 'Not saved: ${e.message}', (m) => m.message.isEmpty ? 'Saved.' : m.message);
      });
    } catch (e) {
      if (mounted) setState(() {
        _saving = false;
        _status = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget toggle(String label, bool value, void Function(bool) set) => SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          title: Text(label, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          value: value,
          onChanged: (v) => setState(() => set(v)),
        );
    return CardFrame(
      title: 'Settings',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        _sub(context, 'Orders'),
        toggle('Best price execution (NSE/BSE)', _s.bestPriceExecution, (v) => _s.bestPriceExecution = v),
        toggle('Retain order quantity', _s.isRetainOrderQty, (v) => _s.isRetainOrderQty = v),
        toggle('Short-sell alert', _s.isShortSellAlert, (v) => _s.isShortSellAlert = v),
        _sub(context, 'Notifications'),
        toggle('Trade notifications', _s.tradeNotification, (v) => _s.tradeNotification = v),
        toggle('Alerts on holdings (DP)', _s.dpAlerts, (v) => _s.dpAlerts = v),
        toggle('WhatsApp updates', _s.isWhatsappConsent, (v) => _s.isWhatsappConsent = v),
        if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: _sub(context, _status)),
        MOSpacing.verticalSpace6,
        MOButton(label: 'Save settings', onPressed: _saving ? null : _save, isLoading: _saving, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small),
        MOSpacing.verticalSpace6,
        _sub(context, 'Theme, biometric login and mPIN are device settings in the classic app and are not changed from here.'),
      ]),
    );
  }
}
