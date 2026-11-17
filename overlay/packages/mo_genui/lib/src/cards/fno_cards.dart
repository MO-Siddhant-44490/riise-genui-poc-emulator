import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_explore_fno/data/fno_repository_impl.dart' as fno;
import 'package:mo_genui/src/cards/order_ticket_card.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/entities/stock_resolver.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_get_quote/data/mo_get_quote_repository_impl.dart';
import 'package:mo_option_chain/data/option_chain_repository_impl.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_index_options/option_store/data/option_store_repository_impl.dart';
import 'package:trader_orders/order_position/domain/net_position_repository.dart';
import 'package:trader_proto_gen/Explore/ExploreModels.pb.dart';
import 'package:trader_proto_gen/Home/HomeModelsV2.pb.dart';
import 'package:trader_proto_gen/Options/OptionsCore.pbenum.dart';
import 'package:trader_proto_gen/Options/OptionsData.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteDashboardModels.pb.dart';
import 'package:trader_proto_gen/Quote/QuoteDetailModels.pb.dart';
import 'package:trader_proto_gen/Recommendation/IndexAdvice.pb.dart';
import 'package:trader_proto_gen/Reports/NetPositions.pb.dart';
import 'package:trader_proto_gen/TradingCore/CoreEnums.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:trader_trading_core/expiry_date.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
String _int(num v) => NumberFormat('#,##,##0', 'en_IN').format(v);
String _signed(num v, {int dp = 2}) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(dp)}';

/// Lakh/crore style compact numbers for OI and volume.
String _compact(num v) {
  final a = v.abs();
  final s = v < 0 ? '−' : '';
  if (a >= 1e7) return '$s${(a / 1e7).toStringAsFixed(2)} Cr';
  if (a >= 1e5) return '$s${(a / 1e5).toStringAsFixed(2)} L';
  if (a >= 1e3) return '$s${(a / 1e3).toStringAsFixed(1)} K';
  return '$s${a.toStringAsFixed(0)}';
}

String _expiryLabel(int secondsFrom1980) => DateFormat('dd MMM yy').format(ExpiryDate.init(secondsFrom1980).date);
DateTime _expiryDate(int secondsFrom1980) => ExpiryDate.init(secondsFrom1980).date;

/// The index ids the F&O APIs use, keyed by the ways people say them.
String? _indexId(String? text) {
  final t = (text ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (t.isEmpty) return 'NIFTY';
  if (t.contains('banknifty') || t.contains('bank')) return 'BANKNIFTY';
  if (t.contains('finnifty') || t.contains('fin')) return 'FINNIFTY';
  if (t.contains('midcp') || t.contains('midcap')) return 'MIDCPNIFTY';
  if (t.contains('sensex')) return 'SENSEX';
  if (t.contains('bankex')) return 'BANKEX';
  if (t == 'nifty' || t == 'nifty50' || t == 'index' || t == 'market') return 'NIFTY';
  return null;
}

/// The option-chain dashboard API identifies an index by its display name,
/// while Explore OI and the chain-by-expiry API use the short id.
const Map<String, String> _indexDisplayName = <String, String>{
  'NIFTY': 'NIFTY 50',
  'BANKNIFTY': 'NIFTY BANK',
  'FINNIFTY': 'NIFTY FIN SERVICE',
  'MIDCPNIFTY': 'NIFTY MID SELECT',
  'SENSEX': 'SENSEX',
  'BANKEX': 'BANKEX',
};

/// Symbol form the chain-by-expiry API expects (same mapping as the classic screen).
String _chainSymbol(String symbol) {
  switch (symbol) {
    case 'NIFTY 50':
      return 'NIFTY';
    case 'NIFTY BANK':
      return 'BANKNIFTY';
    case 'NIFTY FIN SERVICE':
      return 'FINNIFTY';
    case 'NIFTY MID SELECT':
      return 'MIDCPNIFTY';
    case 'SENSEX':
      return 'BSX';
  }
  return symbol.replaceAll('&', '%26');
}

ScripRef _fnoRef(ScripId id, String symbol, String name) => ScripRef(
      scripCode: '${id.scripCode}',
      exchange: id.exchange.name,
      exchangeCode: id.exchange.value,
      id: id,
      symbol: symbol,
      name: name,
    );

Color _pnlColor(BuildContext context, num v) => v < 0 ? context.surfaceTextNegativeNormal : context.surfaceTextPositiveNormal;

Widget _kv(BuildContext context, String k, String v, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(k, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      Text(v, style: MOTypography.bodySmallSemibold.copyWith(color: color ?? context.surfaceTextNeutralStrong)),
    ]);

Widget _error(BuildContext context, Object e) => Padding(
      padding: MOSpacing.paddingVertical8,
      child: Text('$e'.replaceFirst('Exception: ', ''), style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal)),
    );

Widget _loading() => const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))));

Widget _chips<T>(BuildContext context, List<T> items, T selected, String Function(T) label, ValueChanged<T> onPick) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: <Widget>[
        for (final it in items) ...<Widget>[
          ChoiceChip(label: Text(label(it), style: MOTypography.bodyXsmallSemibold), selected: it == selected, onSelected: (_) => onPick(it)),
          MOSpacing.horizontalSpace6,
        ],
      ]),
    );

// ---------------------------------------------------------------------------
// Option chain
// ---------------------------------------------------------------------------

class _Oi {
  int ce = 0, pe = 0, cePrev = 0, pePrev = 0;
}

class _Chain {
  _Chain({required this.dashboard, required this.expiry, required this.chain, required this.oi, this.ref, this.indexId});
  final OptionChainDashboard dashboard;
  final ExpiryInfo expiry;
  final OptionChainResponseV2 chain;
  final Map<int, _Oi> oi; // keyed by strike in paise-free whole units
  final ScripRef? ref;
  final String? indexId;

  int get foExchange => dashboard.exchange == Exchange.BSE ? Exchange.BSE_FO.value : Exchange.NSE_FO.value;
  double get spot => dashboard.spot.currentPrice;
  List<OptionChainResponseV2_ScripEntryV2> get sorted => <OptionChainResponseV2_ScripEntryV2>[...chain.scrips]..sort((a, b) => a.strikePrice.compareTo(b.strikePrice));
  /// Id the broadcast uses for the underlying index.
  String get indexBroadcastId => dashboard.spot.indexSpot.isNotEmpty ? dashboard.spot.indexSpot : (_indexDisplayName[indexId] ?? indexId ?? '');
  int get atm {
    if (chain.scrips.isEmpty) return 0;
    var best = chain.scrips.first.strikePrice;
    for (final s in chain.scrips) {
      if ((s.strikePrice - spot).abs() < (best - spot).abs()) best = s.strikePrice;
    }
    return best.round();
  }
}

/// "Show me the Nifty option chain", "Bank Nifty OI", "Reliance options".
/// Chain skeleton from the quote option-chain API (strikes and CE/PE scrip
/// codes, greeks, PCR, max pain, VIX), OI by strike from Explore, prices live.
class OptionChainCard extends StatefulWidget {
  const OptionChainCard({super.key, this.underlying, this.expiry, this.view, this.strikes, this.strike, this.optionType, this.side});
  final String? underlying;
  final String? expiry;
  final String? view;
  final int? strikes;
  /// "Buy a Nifty 25000 call": open that strike's ticket straight away.
  final double? strike;
  final String? optionType; // call | put
  final String? side; // buy | sell
  static const List<String> views = <String>['chain', 'oi', 'greeks'];

  @override
  State<OptionChainCard> createState() => _OptionChainCardState();
}

class _OptionChainCardState extends State<OptionChainCard> {
  late String _view = OptionChainCard.views.contains(widget.view) ? widget.view! : 'chain';
  late Future<_Chain> _future = _load();
  int? _expirySeconds;
  int get _top => (widget.strikes ?? 8).clamp(3, 15);

  Future<_Chain> _load() async {
    final repo = OptionChainRepositoryImpl();
    final text = (widget.underlying ?? '').trim();
    final idx = _indexId(text);
    OptionChainDashboard? d;
    ScripRef? ref;
    if (idx != null) {
      d = await repo.fetchQuoteOptionChainDashboardData(idx == 'SENSEX' || idx == 'BANKEX' ? Exchange.BSE.value : Exchange.NSE.value, 0, _top, indexId: _indexDisplayName[idx] ?? idx);
    } else {
      ref = await StockResolver.instance!.resolve(text);
      if (ref == null) throw Exception('Could not find "$text" in search.');
      d = await repo.fetchQuoteOptionChainDashboardData(ref.exchangeCode ?? Exchange.NSE.value, int.tryParse(ref.scripCode) ?? 0, _top);
    }
    if (d == null || d.expiry.isEmpty) throw Exception('No option expiries came back for ${idx ?? ref?.symbol}. It may not be an F&O scrip.');
    final exp = _pickExpiry(d.expiry);
    final fo = d.exchange == Exchange.BSE ? Exchange.BSE_FO.value : Exchange.NSE_FO.value;
    final chain = await repo.fetchQuoteOptionChainData(_chainSymbol(d.symbol), DateFormat('dd-MM-yyyy').format(_expiryDate(exp.expirySeconds)), _top, exchangeCode: fo);
    if (chain == null || chain.scrips.isEmpty) throw Exception('The chain for ${d.symbol} ${_expiryLabel(exp.expirySeconds)} is empty on UAT.');
    final oi = <int, _Oi>{};
    if (idx != null) {
      try {
        final o = await fno.StockRepositoryImpl().fetchOptionsOiData(idx, d.exchange.value, exp.expirySeconds);
        for (final s in o.scrips) {
          final row = oi.putIfAbsent(s.strikePrice.round(), () => _Oi());
          if (s.optionType == FnoOptionType.Call) {
            row.ce = s.oi;
            row.cePrev = s.prevOi;
          } else {
            row.pe = s.oi;
            row.pePrev = s.prevOi;
          }
        }
      } catch (e) {
        debugPrint('GenUI OI by strike failed: $e');
      }
    }
    return _Chain(dashboard: d, expiry: exp, chain: chain, oi: oi, ref: ref, indexId: idx);
  }

  ExpiryInfo _pickExpiry(List<ExpiryInfo> list) {
    if (_expirySeconds != null) return list.firstWhere((e) => e.expirySeconds == _expirySeconds, orElse: () => list.first);
    final want = (widget.expiry ?? '').toLowerCase();
    if (want.contains('month')) return list.firstWhere((e) => e.expiryFlag.toLowerCase().startsWith('m'), orElse: () => list.first);
    if (want.contains('next')) return list.length > 1 ? list[1] : list.first;
    for (final e in list) {
      if (want.isNotEmpty && _expiryLabel(e.expirySeconds).toLowerCase().contains(want.split(' ').first)) return e;
    }
    return list.first;
  }

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) => FutureBuilder<_Chain>(
        future: _future,
        builder: (context, snap) {
          final c = snap.data;
          return CardFrame(
            live: true,
            title: c == null ? 'Option chain' : '${c.dashboard.symbol} option chain',
            subtitle: c == null ? null : 'Expiry ${_expiryLabel(c.expiry.expirySeconds)} · ${c.expiry.expiryFlag}',
            views: OptionChainCard.views,
            view: _view,
            onViewChanged: (v) => setState(() => _view = v),
            onRefresh: _reload,
            child: snap.hasError
                ? _error(context, snap.error!)
                : c == null
                    ? _loading()
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        _header(context, c),
                        MOSpacing.verticalSpace8,
                        _chips<ExpiryInfo>(context, c.dashboard.expiry.toList(), c.expiry, (e) => _expiryLabel(e.expirySeconds), (e) {
                          _expirySeconds = e.expirySeconds;
                          _reload();
                        }),
                        MOSpacing.verticalSpace8,
                        if (_view == 'chain') _ChainTable(c: c, openStrike: widget.strike, openType: widget.optionType, openSide: widget.side),
                        if (_view == 'oi') _OiBars(c: c),
                        if (_view == 'greeks') _GreeksTable(c: c),
                        MOSpacing.verticalSpace6,
                        Text(
                          c.oi.isEmpty && c.indexId != null
                              ? 'Tap a strike row to trade that option. Prices and OI come from the live feed (the Explore OI-by-strike API returned nothing for this expiry on UAT).'
                              : 'Tap a strike row to trade that option. Prices come from the live feed when UAT ticks.',
                          style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal),
                        ),
                      ]),
          );
        },
      );

  Widget _header(BuildContext context, _Chain c) {
    final ch = c.chain;
    return Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing8, children: <Widget>[
      _spot(context, c),
      _kv(context, 'ATM', _int(c.atm)),
      if (ch.pcrOi != 0) _kv(context, 'PCR (OI)', ch.pcrOi.toStringAsFixed(2), color: ch.pcrOi > 1 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
      if (ch.maxPain != 0) _kv(context, 'Max pain', _int(ch.maxPain)),
      if (ch.indiaVix.ltp != 0) _kv(context, 'India VIX', '${ch.indiaVix.ltp.toStringAsFixed(2)} (${_signed(ch.indiaVix.perChange)}%)', color: _pnlColor(context, -ch.indiaVix.change)),
      if (ch.futureScrip.lotSize != 0) _kv(context, 'Lot size', _int(ch.futureScrip.lotSize)),
    ]);
  }

  Widget _spot(BuildContext context, _Chain c) {
    Widget body(double ltp, double pct) => _kv(context, 'Spot', ltp == 0 ? '—' : '${_money(ltp)}${pct == 0 ? '' : '  ${_signed(pct)}%'}', color: ltp == 0 || pct == 0 ? null : _pnlColor(context, pct));
    double pick(double? live) => (live ?? 0) != 0 ? live! : c.spot;
    if (c.indexId != null) {
      return LivePrice.index(indexId: c.indexBroadcastId, exchangeCode: c.dashboard.exchange.value, builder: (context, t) => body(pick(t?.ltp), (t?.ltp ?? 0) != 0 ? t!.perChange : 0));
    }
    return LivePrice.scrip(scrip: c.dashboard.spot.id, builder: (context, t) => body(pick(t?.ltp), (t?.ltp ?? 0) != 0 ? t!.perChange : 0));
  }
}

class _ChainTable extends StatelessWidget {
  const _ChainTable({required this.c, this.openStrike, this.openType, this.openSide});
  final _Chain c;
  final double? openStrike;
  final String? openType;
  final String? openSide;

  /// The strike the user named, snapped to the nearest one in the chain.
  int? get _target {
    if (openStrike == null || openStrike == 0 || c.chain.scrips.isEmpty) return null;
    var best = c.chain.scrips.first.strikePrice;
    for (final s in c.chain.scrips) {
      if ((s.strikePrice - openStrike!).abs() < (best - openStrike!).abs()) best = s.strikePrice;
    }
    return best.round();
  }

  @override
  Widget build(BuildContext context) {
    final head = MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
    return Column(children: <Widget>[
      Row(children: <Widget>[
        Expanded(flex: 3, child: Text('CE OI', style: head)),
        Expanded(flex: 3, child: Text('CE LTP', style: head, textAlign: TextAlign.right)),
        Expanded(flex: 3, child: Text('Strike', style: head, textAlign: TextAlign.center)),
        Expanded(flex: 3, child: Text('PE LTP', style: head)),
        Expanded(flex: 3, child: Text('PE OI', style: head, textAlign: TextAlign.right)),
      ]),
      const Divider(height: 12),
      if (_target != null && !c.chain.scrips.any((s) => s.strikePrice.round() == openStrike!.round()))
        Padding(padding: MOSpacing.paddingVertical4, child: Text('${_int(openStrike!)} is not in the loaded strikes; showing the nearest, ${_int(_target!)}.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
      for (final s in c.sorted)
        _StrikeRow(
          key: ValueKey<String>('row-${s.strikePrice}'),
          c: c,
          s: s,
          initialSide: _target == s.strikePrice.round() ? ((openType ?? 'call').toLowerCase().startsWith('p') ? 'PE' : 'CE') : null,
          initialAction: (openSide ?? 'buy').toLowerCase() == 'sell' ? 'sell' : 'buy',
        ),
    ]);
  }
}

class _StrikeRow extends StatefulWidget {
  const _StrikeRow({super.key, required this.c, required this.s, this.initialSide, this.initialAction = 'buy'});
  final _Chain c;
  final OptionChainResponseV2_ScripEntryV2 s;
  final String? initialSide;
  final String initialAction;

  @override
  State<_StrikeRow> createState() => _StrikeRowState();
}

class _StrikeRowState extends State<_StrikeRow> {
  late bool _open = widget.initialSide != null;
  late String? _side = widget.initialSide; // 'CE' | 'PE'
  late String _action = widget.initialAction;

  ScripId _id(int code) => ScripId(scripCode: code, exchange: Exchange.valueOf(widget.c.foExchange));

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final s = widget.s;
    final strike = s.strikePrice.round();
    final isAtm = strike == c.atm;
    final itmCall = s.strikePrice < c.spot;
    final oi = c.oi[strike];
    final shade = context.surfaceBackgroundNeutralFaded;
    final num_ = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    final strikeStyle = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong);

    Widget ltp(int code, bool call) => LivePrice.scrip(
          scrip: _id(code),
          builder: (context, t) {
            final p = t?.ltp ?? 0;
            final pct = t?.perChange ?? 0;
            return Column(crossAxisAlignment: call ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: <Widget>[
              Text(p == 0 ? '—' : _money(p), style: num_),
              if (p != 0) Text('${_signed(pct)}%', style: MOTypography.bodyXsmallRegular.copyWith(color: _pnlColor(context, pct))),
            ]);
          },
        );
    Widget oiCell(int code, bool call) => LivePrice.scrip(
          scrip: _id(code),
          builder: (context, t) {
            final staticOi = call ? (oi?.ce ?? 0) : (oi?.pe ?? 0);
            final prev = call ? (oi?.cePrev ?? 0) : (oi?.pePrev ?? 0);
            final v = (t?.oi ?? 0) != 0 ? t!.oi : staticOi;
            final d = prev == 0 ? 0 : v - prev;
            return Column(crossAxisAlignment: call ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: <Widget>[
              Text(v == 0 ? '—' : _compact(v), style: num_),
              if (d != 0) Text(_compact(d), style: MOTypography.bodyXsmallRegular.copyWith(color: _pnlColor(context, d))),
            ]);
          },
        );

    return Column(children: <Widget>[
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: isAtm ? Border(top: BorderSide(color: context.surfaceTextNeutralNormal), bottom: BorderSide(color: context.surfaceTextNeutralNormal)) : null,
          ),
          child: Row(children: <Widget>[
            Expanded(flex: 6, child: Container(color: itmCall ? shade : null, padding: const EdgeInsets.symmetric(horizontal: 2), child: Row(children: <Widget>[Expanded(child: oiCell(s.callScripCode, true)), Expanded(child: ltp(s.callScripCode, true))]))),
            Expanded(flex: 3, child: Text(_int(strike), style: strikeStyle, textAlign: TextAlign.center)),
            Expanded(flex: 6, child: Container(color: !itmCall ? shade : null, padding: const EdgeInsets.symmetric(horizontal: 2), child: Row(children: <Widget>[Expanded(child: ltp(s.putScripCode, false)), Expanded(child: oiCell(s.putScripCode, false))]))),
          ]),
        ),
      ),
      if (_open) ...<Widget>[
        Padding(
          padding: MOSpacing.paddingVertical4,
          child: Wrap(spacing: MOSpacing.spacing8, children: <Widget>[
            for (final side in const <String>['CE', 'PE'])
              for (final a in const <String>['buy', 'sell'])
                MOButton(
                  label: '${a == 'buy' ? 'Buy' : 'Sell'} $side',
                  onPressed: () => setState(() {
                    _side = side;
                    _action = a;
                  }),
                  variant: _side == side && _action == a ? MOButtonVariant.primary : MOButtonVariant.secondary,
                  color: a == 'buy' ? MOButtonColor.primary : MOButtonColor.negative,
                  size: MOButtonSize.small,
                ),
          ]),
        ),
        if (_side != null)
          OrderTicketCard(
            key: ValueKey<String>('oc-$strike-$_side-$_action'),
            ref: _fnoRef(_id(_side == 'CE' ? s.callScripCode : s.putScripCode), '${c.dashboard.symbol} ${_int(strike)} $_side', '${c.dashboard.symbol} ${_expiryLabel(c.expiry.expirySeconds)} ${_int(strike)} $_side'),
            side: _action,
            qty: c.chain.futureScrip.lotSize == 0 ? null : c.chain.futureScrip.lotSize,
            product: 'intraday',
          ),
      ],
    ]);
  }
}

class _OiBars extends StatelessWidget {
  const _OiBars({required this.c});
  final _Chain c;

  @override
  Widget build(BuildContext context) {
    var rows = c.sorted.where((s) => c.oi.containsKey(s.strikePrice.round())).toList();
    var fromGreeks = false;
    if (rows.isEmpty && c.chain.greeks.isNotEmpty) {
      // Explore's OI-by-strike is empty on UAT; the chain's greeks carry previous-day OI per contract.
      for (final s in c.sorted) {
        final ce = c.chain.greeks[s.callScripCode]?.prevOi ?? 0;
        final pe = c.chain.greeks[s.putScripCode]?.prevOi ?? 0;
        if (ce == 0 && pe == 0) continue;
        c.oi[s.strikePrice.round()] = _Oi()
          ..ce = ce
          ..pe = pe;
      }
      rows = c.sorted.where((s) => c.oi.containsKey(s.strikePrice.round())).toList();
      fromGreeks = rows.isNotEmpty;
    }
    if (rows.isEmpty) {
      return Padding(padding: MOSpacing.paddingVertical8, child: Text('No open-interest-by-strike data for this expiry on UAT. The chain view still shows OI from the live feed when it ticks.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)));
    }
    final ce = context.surfaceTextNegativeNormal;
    final pe = context.surfaceTextPositiveNormal;
    final maxY = rows.fold<double>(0, (m, s) {
      final o = c.oi[s.strikePrice.round()]!;
      return [m, o.ce.toDouble(), o.pe.toDouble()].reduce((a, b) => a > b ? a : b);
    });
    int maxCe = 0, maxPe = 0;
    for (final s in rows) {
      final o = c.oi[s.strikePrice.round()]!;
      if (o.ce > (c.oi[maxCe]?.ce ?? -1)) maxCe = s.strikePrice.round();
      if (o.pe > (c.oi[maxPe]?.pe ?? -1)) maxPe = s.strikePrice.round();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Row(children: <Widget>[
        _legend(context, ce, 'Call OI (resistance)'),
        MOSpacing.horizontalSpace12,
        _legend(context, pe, 'Put OI (support)'),
      ]),
      MOSpacing.verticalSpace8,
      SizedBox(
        height: 220,
        child: BarChart(BarChartData(
          maxY: maxY * 1.15,
          barGroups: <BarChartGroupData>[
            for (var i = 0; i < rows.length; i++)
              BarChartGroupData(x: i, barsSpace: 2, barRods: <BarChartRodData>[
                BarChartRodData(toY: c.oi[rows[i].strikePrice.round()]!.ce.toDouble(), color: ce, width: 7, borderRadius: BorderRadius.circular(2)),
                BarChartRodData(toY: c.oi[rows[i].strikePrice.round()]!.pe.toDouble(), color: pe, width: 7, borderRadius: BorderRadius.circular(2)),
              ]),
          ],
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(),
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= rows.length || (rows.length > 8 && i.isOdd)) return const SizedBox.shrink();
                  final k = rows[i].strikePrice.round();
                  return Padding(padding: const EdgeInsets.only(top: 4), child: Text(_int(k), style: MOTypography.bodyXsmallRegular.copyWith(color: k == c.atm ? context.surfaceTextNeutralStrong : context.surfaceTextNeutralNormal, fontWeight: k == c.atm ? FontWeight.w700 : null)));
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(touchTooltipData: BarTouchTooltipData(getTooltipItem: (g, _, rod, ri) => BarTooltipItem('${_int(rows[g.x].strikePrice)} ${ri == 0 ? 'CE' : 'PE'}\n${_compact(rod.toY)}', MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextStaticWhiteNormal)))),
        )),
      ),
      MOSpacing.verticalSpace8,
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing8, children: <Widget>[
        _kv(context, 'Highest call OI (resistance)', _int(maxCe), color: ce),
        _kv(context, 'Highest put OI (support)', _int(maxPe), color: pe),
        if (c.chain.pcrOi != 0) _kv(context, 'PCR', '${c.chain.pcrOi.toStringAsFixed(2)} · ${c.chain.pcrOi > 1.2 ? 'bullish bias' : c.chain.pcrOi < 0.8 ? 'bearish bias' : 'neutral'}'),
      ]),
      if (fromGreeks) ...<Widget>[
        MOSpacing.verticalSpace6,
        Text('Previous session\'s OI per strike (from the chain), since the live OI-by-strike feed is empty on UAT.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ],
    ]);
  }

  Widget _legend(BuildContext context, Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        MOSpacing.horizontalSpace4,
        Text(text, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ]);
}

class _GreeksTable extends StatelessWidget {
  const _GreeksTable({required this.c});
  final _Chain c;

  @override
  Widget build(BuildContext context) {
    final head = MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
    final cell = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    Widget row(List<String> cells, {TextStyle? style, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: <Widget>[
            for (var i = 0; i < cells.length; i++) Expanded(flex: i == 0 ? 3 : 2, child: Text(cells[i], textAlign: i == 0 ? TextAlign.left : TextAlign.right, style: (style ?? cell).copyWith(fontWeight: bold ? FontWeight.w700 : null))),
          ]),
        );
    if (c.chain.greeks.isEmpty) {
      return Padding(padding: MOSpacing.paddingVertical8, child: Text('UAT returned no greeks for this expiry.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)));
    }
    return Column(children: <Widget>[
      row(const <String>['Option', 'IV', 'Delta', 'Theta', 'Vega', 'Prev OI'], style: head),
      const Divider(height: 8),
      for (final s in c.sorted)
        for (final e in <MapEntry<String, int>>[MapEntry('${_int(s.strikePrice)} CE', s.callScripCode), MapEntry('${_int(s.strikePrice)} PE', s.putScripCode)])
          if (c.chain.greeks[e.value] != null)
            row(<String>[
              e.key,
              c.chain.greeks[e.value]!.iv.toStringAsFixed(1),
              c.chain.greeks[e.value]!.delta.toStringAsFixed(2),
              c.chain.greeks[e.value]!.theta.toStringAsFixed(2),
              c.chain.greeks[e.value]!.vega.toStringAsFixed(2),
              _compact(c.chain.greeks[e.value]!.prevOi),
            ], bold: s.strikePrice.round() == c.atm),
    ]);
  }
}

// ---------------------------------------------------------------------------
// F&O pulse: PCR, VIX, advance/decline, index view with support/resistance
// ---------------------------------------------------------------------------

class _Pulse {
  _Pulse({required this.dash, this.indexView, this.admin, this.chain, this.chainExpiry = ''});
  final FNODashboardResponseV4 dash;
  final IndexAdviceDashboard? indexView;
  final AdminDataResponse? admin;
  /// Nearest-expiry chain header for the chosen index: PCR, max pain, VIX.
  final OptionChainResponseV2? chain;
  final String chainExpiry;
}

/// "How is Nifty looking?", "F&O market sentiment", "Nifty support and resistance".
class FnoPulseCard extends StatefulWidget {
  const FnoPulseCard({super.key, this.index, this.view});
  final String? index;
  final String? view;
  static const List<String> views = <String>['summary', 'levels'];

  @override
  State<FnoPulseCard> createState() => _FnoPulseCardState();
}

class _FnoPulseCardState extends State<FnoPulseCard> {
  late String _view = FnoPulseCard.views.contains(widget.view) ? widget.view! : 'summary';
  late Future<_Pulse> _future = _load();
  String _horizon = 'Short term';
  String get _idx => _indexId(widget.index) ?? 'NIFTY';

  Future<_Pulse> _load() async {
    final repo = fno.StockRepositoryImpl();
    final dash = await repo.getFnoDashboard(<String>['AdvanceDeclines', 'IndexView', 'Indices'], false, (_) {});
    IndexAdviceDashboard? iv = dash.hasIndexView() ? dash.indexView : null;
    AdminDataResponse? admin = iv != null && iv.hasAdminData() ? iv.adminData : null;
    try {
      iv ??= await repo.getFnoIndexView();
    } catch (e) {
      debugPrint('GenUI index view failed: $e');
    }
    // Research levels: the classic Index View asks with the enum names ShortTerm / Positional.
    for (final horizon in const <String>['ShortTerm', 'Positional']) {
      try {
        final a = await repo.fetchOverViewProIndexAdviceAdmin(_idx, horizon);
        if (a != null && (a.cmp != 0 || a.description.isNotEmpty)) {
          admin = a;
          _horizon = horizon == 'ShortTerm' ? 'Intraday / short term' : 'Positional';
          break;
        }
      } catch (e) {
        debugPrint('GenUI index advice $horizon failed: $e');
      }
    }
    // Breadth and PCR sections are mostly empty on UAT; the option chain header carries PCR, max pain and VIX.
    OptionChainResponseV2? chain;
    var chainExpiry = '';
    try {
      final oc = OptionChainRepositoryImpl();
      final isBse = _idx == 'SENSEX' || _idx == 'BANKEX';
      final d = await oc.fetchQuoteOptionChainDashboardData(isBse ? Exchange.BSE.value : Exchange.NSE.value, 0, 1, indexId: _indexDisplayName[_idx] ?? _idx);
      if (d != null && d.expiry.isNotEmpty) {
        chainExpiry = _expiryLabel(d.expiry.first.expirySeconds);
        chain = await oc.fetchQuoteOptionChainData(_chainSymbol(d.symbol), DateFormat('dd-MM-yyyy').format(_expiryDate(d.expiry.first.expirySeconds)), 1, exchangeCode: isBse ? Exchange.BSE_FO.value : Exchange.NSE_FO.value);
      }
    } catch (e) {
      debugPrint('GenUI pulse chain header failed: $e');
    }
    return _Pulse(dash: dash, indexView: iv, admin: admin, chain: chain, chainExpiry: chainExpiry);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Pulse>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: 'F&O pulse',
          subtitle: 'PCR, VIX, breadth and Motilal Oswal\'s $_idx view',
          views: FnoPulseCard.views,
          view: _view,
          onViewChanged: (v) => setState(() => _view = v),
          onRefresh: () => setState(() {
            _future = _load();
          }),
          child: snap.hasError
              ? _error(context, snap.error!)
              : !snap.hasData
                  ? _loading()
                  : _view == 'levels'
                      ? _levels(context, snap.data!)
                      : _summary(context, snap.data!),
        ),
      );

  Widget _summary(BuildContext context, _Pulse p) {
    final ad = p.dash.advanceDecline;
    final overall = ad.overall;
    var vix = overall.indiaVix;
    // The breadth section is often empty on UAT; the Index View carries VIX too.
    final nv = p.indexView?.indexData.niftyVix;
    if (vix.ltp == 0 && nv != null && nv.ltp != 0) vix = IndiaVix(indexId: nv.indexId, ltp: nv.ltp, change: nv.change, perChange: nv.perChange);
    if (vix.ltp == 0 && (p.chain?.indiaVix.ltp ?? 0) != 0) vix = p.chain!.indiaVix;
    final ch = p.chain;
    final pcrs = ad.indexPcrData.indexPcrDataList;
    final total = overall.advance + overall.decline;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing8, children: <Widget>[
        _kv(context, 'India VIX', vix.ltp == 0 ? '—' : '${vix.ltp.toStringAsFixed(2)} (${_signed(vix.perChange)}%)', color: vix.ltp == 0 ? null : _pnlColor(context, -vix.change)),
        if (ch != null && ch.pcrOi != 0) _kv(context, '$_idx PCR (OI)', '${ch.pcrOi.toStringAsFixed(2)} · ${ch.pcrOi > 1.2 ? 'bullish bias' : ch.pcrOi < 0.8 ? 'bearish bias' : 'neutral'}', color: ch.pcrOi >= 1 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
        if (ch != null && ch.maxPain != 0) _kv(context, 'Max pain (${p.chainExpiry})', _int(ch.maxPain)),
        if (total > 0) _kv(context, 'F&O advances', _int(overall.advance), color: context.surfaceTextPositiveNormal),
        if (total > 0) _kv(context, 'F&O declines', _int(overall.decline), color: context.surfaceTextNegativeNormal),
      ]),
      if (total == 0) ...<Widget>[
        MOSpacing.verticalSpace6,
        Text('F&O advance/decline breadth is not published on UAT.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ],
      if (total > 0) ...<Widget>[
        MOSpacing.verticalSpace8,
        ClipRRect(
          borderRadius: BorderRadius.circular(MOSpacing.spacing4),
          child: SizedBox(
            height: 8,
            child: Row(children: <Widget>[
              Expanded(flex: overall.advance, child: Container(color: context.surfaceTextPositiveNormal)),
              Expanded(flex: overall.decline, child: Container(color: context.surfaceTextNegativeNormal)),
            ]),
          ),
        ),
      ],
      MOSpacing.verticalSpace12,
      Text('Put-call ratio by index', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
      MOSpacing.verticalSpace4,
      if (pcrs.isEmpty) Text(ch != null && ch.pcrOi != 0 ? 'Only the $_idx chain PCR above is available on UAT; the per-index PCR feed is empty.' : 'No PCR data on UAT right now.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      for (final r in pcrs)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: <Widget>[
            Expanded(flex: 3, child: Text(r.indexId, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
            Expanded(flex: 3, child: Text(r.expiry, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
            Expanded(flex: 2, child: Text(r.pcr.toStringAsFixed(2), textAlign: TextAlign.right, style: MOTypography.bodySmallSemibold.copyWith(color: r.pcr >= 1 ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal))),
            Expanded(flex: 3, child: Text(r.pcr > 1.2 ? 'bullish' : r.pcr < 0.8 ? 'bearish' : 'neutral', textAlign: TextAlign.right, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
          ]),
        ),
      MOSpacing.verticalSpace8,
      Text('PCR above 1 means more puts than calls are open (traders hedged or bullish); below 0.8 leans bearish.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
    ]);
  }

  Widget _levels(BuildContext context, _Pulse p) {
    final a = p.admin;
    if (a == null || (a.cmp == 0 && a.s1 == 0 && a.description.isEmpty)) {
      return Padding(padding: MOSpacing.paddingVertical8, child: Text('The $_idx research view has no levels published on UAT right now.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)));
    }
    Widget level(String k, double v, Color c) => Expanded(child: Column(children: <Widget>[
          Text(k, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          Text(v == 0 ? '—' : _int(v), style: MOTypography.bodySmallSemibold.copyWith(color: c)),
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      LivePrice.index(
        indexId: _indexDisplayName[_idx] ?? _idx,
        exchangeCode: _idx == 'SENSEX' || _idx == 'BANKEX' ? Exchange.BSE.value : Exchange.NSE.value,
        builder: (context, t) => Row(children: <Widget>[
          level('S2', a.s2, context.surfaceTextPositiveNormal),
          level('S1', a.s1, context.surfaceTextPositiveNormal),
          level(a.cmp != 0 ? 'CMP' : 'Live', a.cmp != 0 ? a.cmp : (t?.ltp ?? 0), context.surfaceTextNeutralStrong),
          level('R1', a.r1, context.surfaceTextNegativeNormal),
          level('R2', a.r2, context.surfaceTextNegativeNormal),
        ]),
      ),
      if (a.cmp != 0 && a.s2 != 0 && a.r2 != 0) ...<Widget>[
        MOSpacing.verticalSpace8,
        LayoutBuilder(builder: (context, box) {
          final span = (a.r2 - a.s2).abs();
          final pos = span == 0 ? 0.5 : ((a.cmp - a.s2) / span).clamp(0.0, 1.0);
          return Stack(children: <Widget>[
            Container(height: 6, decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(3))),
            Positioned(left: (box.maxWidth - 12) * pos, child: Container(width: 12, height: 6, decoration: BoxDecoration(color: context.surfaceTextNeutralStrong, borderRadius: BorderRadius.circular(3)))),
          ]);
        }),
      ],
      if (a.description.isNotEmpty) ...<Widget>[
        MOSpacing.verticalSpace12,
        Text(a.description.replaceAll(r'\n', '\n'), style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
      ],
      if (a.chartDescription.isNotEmpty) ...<Widget>[
        MOSpacing.verticalSpace6,
        Text(a.chartDescription.replaceAll(r'\n', '\n'), style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
      ],
      MOSpacing.verticalSpace6,
      Text('Levels and view are from Motilal Oswal research ($_horizon). Not a recommendation generated by the AI.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// F&O movers: most active, OI gainers/losers, options in momentum
// ---------------------------------------------------------------------------

/// "Most active options", "OI gainers in futures", "options in momentum".
class FnoMoversCard extends StatefulWidget {
  const FnoMoversCard({super.key, this.kind, this.segment, this.view, this.timeframe, this.underlying});
  final String? kind; // active | oi_gainers | oi_losers | momentum
  final String? underlying; // index to filter the tabs by, if the user named one
  final String? segment; // options | futures
  final String? view;
  final String? timeframe; // 5m 15m 30m 1h 1d (momentum only)
  static const List<String> views = <String>['list', 'bars'];
  static const Map<String, String> kinds = <String, String>{'active': 'Most active', 'oi_gainers': 'OI gainers', 'oi_losers': 'OI losers', 'momentum': 'In momentum'};

  @override
  State<FnoMoversCard> createState() => _FnoMoversCardState();
}

class _Mover {
  _Mover({required this.id, required this.symbol, required this.name, required this.pct, this.ltp = 0, this.oi = 0, this.oiChange = 0, this.volume = 0, this.tag = ''});
  final ScripId id;
  final String symbol;
  final String name;
  final double pct;
  final double ltp;
  final int oi;
  final int oiChange;
  final int volume;
  final String tag;
}

class _FnoMoversCardState extends State<FnoMoversCard> {
  late String _view = FnoMoversCard.views.contains(widget.view) ? widget.view! : 'list';
  late String _kind = FnoMoversCard.kinds.containsKey(widget.kind) ? widget.kind! : 'active';
  late String _segment = widget.segment == 'futures' ? 'futures' : 'options';
  late int _tf = _tfIndex(widget.timeframe);
  late Future<List<_Mover>> _future = _load();
  String _tabNote = '';
  static const List<String> _tfLabels = <String>['5 min', '15 min', '30 min', '1 hour', '1 day'];

  static int _tfIndex(String? s) {
    final t = (s ?? '').toLowerCase().replaceAll(' ', '');
    if (t.startsWith('5')) return 0;
    if (t.startsWith('30')) return 2;
    if (t.startsWith('1h') || t.contains('hour')) return 3;
    if (t.startsWith('1d') || t.contains('day')) return 4;
    return 1;
  }

  Future<List<_Mover>> _load() async {
    final repo = fno.StockRepositoryImpl();
    if (_kind == 'momentum') {
      final r = await repo.getOptionsMomentum(_tf);
      return <_Mover>[
        for (final e in r.optionsInMomentum.entries)
          _Mover(id: e.scrip, symbol: e.tradeSymbol, name: '${e.indexId.isEmpty ? e.description : e.indexId} ${_int(e.strikePrice / 100)} ${e.optionType == FnoOptionType.Call ? 'CE' : 'PE'} · ${e.expiryFlag}', pct: e.perChange / 100, tag: e.isGainer ? 'gainer' : 'loser'),
      ];
    }
    final screen = _kind == 'active' ? 'most_active_contract' : _kind;
    // The movers API needs the expiry and instrument the classic tabs carry; read them from
    // the dashboard's TrendingOptions section (instrumentId like OPTIDX / FUTIDX).
    String? expiryDate;
    String? instType;
    try {
      final d = await repo.getFnoDashboard(<String>['TrendingOptions'], false, (_) {});
      final tabs = (d.hasTrendingOptions() ? d.trendingOptions : d.fnOMovers).data;
      debugPrint('GenUI movers tabs: ${tabs.map((t) => '${t.instrumentId}/${t.screenType}/${t.expiryDate}').join(', ')}');
      // instrumentId is the index (NIFTY, BANKNIFTY…); expiryDate is yyyy-MM-dd.
      final want = _indexId(widget.underlying);
      final tab = tabs.cast<FnoMovers?>().firstWhere((t) => t!.screenType == screen && t.expiryDate.isNotEmpty && (want == null || t.instrumentId == want),
          orElse: () => tabs.cast<FnoMovers?>().firstWhere((t) => t!.screenType == screen && t.expiryDate.isNotEmpty,
              orElse: () => tabs.cast<FnoMovers?>().firstWhere((t) => t!.expiryDate.isNotEmpty, orElse: () => null)));
      expiryDate = tab?.expiryDate;
      instType = tab?.instrumentId;
      if (tab != null) _tabNote = '${tab.instrumentName.isEmpty ? tab.instrumentId : tab.instrumentName} · expiry ${tab.expiryDate}';
    } catch (e) {
      debugPrint('GenUI movers tabs failed: $e');
    }
    if (_segment == 'futures') {
      // The tabs carry option expiries; futures expire monthly, so take the nearest futures contract.
      try {
        final f = await MoGetQuoteRepositoryImpl().fetchQuoteFuturesData(symbol: instType ?? 'NIFTY', exchangeCode: Exchange.NSE.value);
        if (f.expiries.isNotEmpty) {
          final e = (f.expiries.toList()..sort((a, b) => a.expirySeconds.compareTo(b.expirySeconds))).first;
          expiryDate = DateFormat('yyyy-MM-dd').format(_expiryDate(e.expirySeconds));
          instType ??= 'NIFTY';
          _tabNote = '$instType futures · expiry $expiryDate';
        }
      } catch (e) {
        debugPrint('GenUI futures expiry lookup failed: $e');
      }
    }
    if (expiryDate == null || expiryDate.isEmpty) {
      // No tabs: use the nearest Nifty expiry from the option-chain dashboard, as the classic tab would.
      try {
        final d = await OptionChainRepositoryImpl().fetchQuoteOptionChainDashboardData(Exchange.NSE.value, 0, 1, indexId: 'NIFTY 50');
        if (d != null && d.expiry.isNotEmpty) {
          expiryDate = DateFormat('yyyy-MM-dd').format(_expiryDate(d.expiry.first.expirySeconds));
          instType = 'NIFTY';
          _tabNote = 'NIFTY · expiry $expiryDate';
        }
      } catch (_) {}
    }
    final r = await repo.getFnoMoversByType(_segment, screen, expiryDate: expiryDate, instType: instType, count: 10);
    final rows = <FnoEntryV4>[...r.index, ...r.stocks];
    return <_Mover>[
      for (final e in rows) _Mover(id: e.scrip, symbol: e.tradeSymbol, name: e.description.isEmpty ? e.expiryFlag : '${e.description} · ${e.expiryFlag}', pct: e.perChange / 100, ltp: e.ltp / 100, oi: e.openInterest, oiChange: e.oiDifference, volume: e.volume),
    ];
  }

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  Widget build(BuildContext context) => CardFrame(
        live: true,
        title: '${FnoMoversCard.kinds[_kind]} · ${_kind == 'momentum' ? 'options' : _segment}',
        subtitle: _tabNote.isEmpty ? null : _tabNote,
        views: FnoMoversCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: _reload,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          _chips<String>(context, FnoMoversCard.kinds.keys.toList(), _kind, (k) => FnoMoversCard.kinds[k]!, (k) {
            _kind = k;
            _reload();
          }),
          MOSpacing.verticalSpace6,
          if (_kind == 'momentum')
            _chips<int>(context, List<int>.generate(5, (i) => i), _tf, (i) => _tfLabels[i], (i) {
              _tf = i;
              _reload();
            })
          else
            _chips<String>(context, const <String>['options', 'futures'], _segment, (s) => s[0].toUpperCase() + s.substring(1), (s) {
              _segment = s;
              _reload();
            }),
          MOSpacing.verticalSpace8,
          FutureBuilder<List<_Mover>>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) return _error(context, snap.error!);
              if (!snap.hasData) return _loading();
              final rows = snap.data!;
              if (rows.isEmpty) return Padding(padding: MOSpacing.paddingVertical8, child: Text('Nothing returned for this filter on UAT.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)));
              return _view == 'bars' ? _bars(context, rows) : Column(children: <Widget>[for (final m in rows) _MoverRow(m: m, showOi: _kind != 'momentum')]);
            },
          ),
        ]),
      );

  Widget _bars(BuildContext context, List<_Mover> rows) {
    final byOi = _kind != 'momentum' && _kind != 'active';
    final vals = rows.map((m) => byOi ? m.oiChange.toDouble() : m.pct).toList();
    final maxAbs = vals.fold<double>(0, (a, b) => b.abs() > a ? b.abs() : a);
    return Column(children: <Widget>[
      for (var i = 0; i < rows.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: <Widget>[
            SizedBox(width: 136, child: Text(_contractLabel(rows[i]), maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: maxAbs == 0 ? 0 : (vals[i].abs() / maxAbs).clamp(0.02, 1.0),
                  child: Container(height: 14, decoration: BoxDecoration(color: _pnlColor(context, vals[i]), borderRadius: BorderRadius.circular(3))),
                ),
              ),
            ),
            MOSpacing.horizontalSpace8,
            SizedBox(width: 72, child: Text(byOi ? _compact(vals[i]) : '${_signed(vals[i])}%', textAlign: TextAlign.right, style: MOTypography.bodyXsmallSemibold.copyWith(color: _pnlColor(context, vals[i])))),
          ]),
        ),
      MOSpacing.verticalSpace4,
      Text(byOi ? 'Bars show the change in open interest.' : 'Bars show today\'s % change.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
    ]);
  }
}

/// "NIFTY 24900 PE" from the API's description ("NSE 09 Nov PE 24900 · W").
String _contractLabel(_Mover m) {
  final d = m.name.replaceFirst(RegExp(r'^NSE |^BSE '), '').replaceAll(RegExp(r'\s*·.*$'), '');
  final mm = RegExp(r'(CE|PE|FUT)\s*([0-9.]*)').firstMatch(d);
  if (mm == null) return '${m.symbol} $d'.trim();
  final strike = mm.group(2) ?? '';
  return '${m.symbol} ${strike.isEmpty ? '' : '${_int(double.tryParse(strike) ?? 0)} '}${mm.group(1)}'.trim();
}

class _MoverRow extends StatefulWidget {
  const _MoverRow({required this.m, required this.showOi});
  final _Mover m;
  final bool showOi;

  @override
  State<_MoverRow> createState() => _MoverRowState();
}

class _MoverRowState extends State<_MoverRow> {
  String? _side;

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    return Column(children: <Widget>[
      InkWell(
        onTap: () => setState(() => _side = _side == null ? '' : null),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LivePrice.scrip(
            scrip: m.id,
            builder: (context, t) {
              final ltp = (t?.ltp ?? 0) != 0 ? t!.ltp : m.ltp;
              final pct = t != null && t.ltp != 0 ? t.perChange : m.pct;
              final oi = (t?.oi ?? 0) != 0 ? t!.oi : m.oi;
              return Row(children: <Widget>[
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(m.symbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                  ]),
                ),
                if (widget.showOi)
                  SizedBox(
                    width: 92,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                      Text('OI ${_compact(oi)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                      if (m.oiChange != 0) Text(_compact(m.oiChange), style: MOTypography.bodyXsmallRegular.copyWith(color: _pnlColor(context, m.oiChange))),
                      if (m.volume != 0) Text('Vol ${_compact(m.volume)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                    ]),
                  ),
                SizedBox(
                  width: 84,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                    Text(ltp == 0 ? '—' : _money(ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text('${_signed(pct)}%', style: MOTypography.bodyXsmallSemibold.copyWith(color: _pnlColor(context, pct))),
                  ]),
                ),
              ]);
            },
          ),
        ),
      ),
      if (_side != null) ...<Widget>[
        Row(children: <Widget>[
          MOButton(label: 'Buy', onPressed: () => setState(() => _side = 'buy'), variant: _side == 'buy' ? MOButtonVariant.primary : MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small),
          MOSpacing.horizontalSpace8,
          MOButton(label: 'Sell', onPressed: () => setState(() => _side = 'sell'), variant: _side == 'sell' ? MOButtonVariant.primary : MOButtonVariant.secondary, color: MOButtonColor.negative, size: MOButtonSize.small),
        ]),
        if (_side!.isNotEmpty) OrderTicketCard(key: ValueKey<String>('mv-${m.id.scripCode}-$_side'), ref: _fnoRef(m.id, m.symbol, m.name), side: _side, product: 'intraday'),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// F&O positions with MTM
// ---------------------------------------------------------------------------

class _Positions {
  _Positions({required this.rows, this.summary, this.marginUsed = 0});
  final List<NetPositionScrip> rows;
  final PositionSummaryV4? summary;
  final double marginUsed;
}

/// "My F&O positions", "what is my MTM", "how are my options doing".
class FnoPositionsCard extends StatefulWidget {
  const FnoPositionsCard({super.key, this.view, this.assetType = 'F&O'});
  final String? view;
  /// 'F&O' | 'Commodity' | 'Currency' (the net-position API's assetType).
  final String assetType;
  static const List<String> views = <String>['open', 'all'];

  @override
  State<FnoPositionsCard> createState() => _FnoPositionsCardState();
}

class _FnoPositionsCardState extends State<FnoPositionsCard> {
  late String _view = FnoPositionsCard.views.contains(widget.view) ? widget.view! : 'open';
  late Future<_Positions> _future = _load();

  Future<_Positions> _load() async {
    final res = await getIt<NetPositionRepository>().getNetPosition(assetType: widget.assetType, type: 'net');
    PositionSummaryV4? sum;
    if (widget.assetType != 'F&O') return _Positions(rows: res.net, marginUsed: res.marginUtilized);
    try {
      final d = await fno.StockRepositoryImpl().getFnoDashboard(<String>['PositionV2'], true, (_) {});
      if (d.hasPosition()) sum = d.position;
    } catch (e) {
      debugPrint('GenUI F&O position summary failed: $e');
    }
    return _Positions(rows: res.net, summary: sum, marginUsed: res.marginUtilized);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Positions>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: '${widget.assetType} positions',
          views: FnoPositionsCard.views,
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

  Widget _body(BuildContext context, _Positions p) {
    final rows = _view == 'open' ? p.rows.where((r) => r.netQty != 0).toList() : p.rows;
    final s = p.summary;
    final dayMtm = s?.dayMtm ?? rows.fold<double>(0, (a, r) => a + r.dayMTM);
    final overall = s?.overallMtm ?? rows.fold<double>(0, (a, r) => a + r.overallMTM);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing8, children: <Widget>[
        _kv(context, 'Day MTM', _signed(dayMtm), color: _pnlColor(context, dayMtm)),
        _kv(context, 'Overall MTM', _signed(overall), color: _pnlColor(context, overall)),
        if (s != null) _kv(context, 'Booked P&L', _signed(s.bookedPnl), color: _pnlColor(context, s.bookedPnl)),
        if (s != null && s.availableMargin != 0) _kv(context, 'Available margin', _money(s.availableMargin)),
        if (p.marginUsed != 0) _kv(context, 'Margin used', _money(p.marginUsed)),
        _kv(context, 'Positions', '${rows.length}'),
      ]),
      MOSpacing.verticalSpace8,
      if (rows.isEmpty)
        Padding(padding: MOSpacing.paddingVertical8, child: Text(_view == 'open' ? (widget.assetType == 'F&O' ? 'No open F&O positions. Buy an option or future from the option chain or movers card to open one.' : 'No open ${widget.assetType.toLowerCase()} positions.') : 'No ${widget.assetType} positions today.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)))
      else
        for (final r in rows) _FnoPositionRow(r: r),
    ]);
  }
}

class _FnoPositionRow extends StatefulWidget {
  const _FnoPositionRow({required this.r});
  final NetPositionScrip r;

  @override
  State<_FnoPositionRow> createState() => _FnoPositionRowState();
}

class _FnoPositionRowState extends State<_FnoPositionRow> {
  bool _exit = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final lots = r.lotSize == 0 ? r.netQty : r.netQty ~/ r.lotSize;
    return Column(children: <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LivePrice.scrip(
          scrip: r.id,
          builder: (context, t) {
            final ltp = (t?.ltp ?? 0) != 0 ? t!.ltp : r.ltp;
            final mult = r.multiplier == 0 ? 1 : r.multiplier;
            // Live MTM when the feed ticks: open qty × (ltp − net avg) × multiplier, plus booked.
            final live = r.netQty == 0 || ltp == 0 ? r.overallMTM : r.bPL + r.netQty * (ltp - r.netAvg) * mult;
            return Row(children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(r.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                  Text('${r.netQty > 0 ? 'Long' : r.netQty < 0 ? 'Short' : 'Closed'} ${r.netQty == 0 ? '' : '${r.netQty.abs()} (${lots.abs()} lot${lots.abs() == 1 ? '' : 's'})'} · avg ${_money(r.netAvg)} · ${r.product.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                Text(_signed(live), style: MOTypography.bodySmallSemibold.copyWith(color: _pnlColor(context, live))),
                Text(ltp == 0 ? 'LTP —' : 'LTP ${_money(ltp)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              ]),
              if (r.netQty != 0 && r.canSquareOff) ...<Widget>[
                MOSpacing.horizontalSpace8,
                MOButton(label: _exit ? 'Hide' : 'Exit', onPressed: () => setState(() => _exit = !_exit), variant: MOButtonVariant.secondary, color: MOButtonColor.negative, size: MOButtonSize.small),
              ],
            ]);
          },
        ),
      ),
      if (_exit)
        OrderTicketCard(
          key: ValueKey<String>('fx-${r.id.scripCode}'),
          ref: _fnoRef(r.id, r.tradeSymbol, r.description),
          side: r.netQty > 0 ? 'sell' : 'buy',
          qty: r.netQty.abs(),
          orderType: 'market',
          product: r.product.name.toLowerCase() == 'normal' ? 'intraday' : null,
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Strategy ideas (Predict & Trade pots)
// ---------------------------------------------------------------------------

/// "Bullish option strategy on Nifty", "what strategy should I trade this week".
class FnoStrategiesCard extends StatefulWidget {
  const FnoStrategiesCard({super.key, this.sentiment});
  final String? sentiment; // bullish | bearish | neutral
  static const List<String> views = <String>['bullish', 'bearish', 'neutral', 'all'];

  @override
  State<FnoStrategiesCard> createState() => _FnoStrategiesCardState();
}

class _FnoStrategiesCardState extends State<FnoStrategiesCard> {
  late String _view = FnoStrategiesCard.views.contains((widget.sentiment ?? '').toLowerCase()) ? widget.sentiment!.toLowerCase() : 'all';
  late Future<PredictNTrade> _future = _load();

  String _source = 'Predict & Trade';

  Future<PredictNTrade> _load() async {
    final d = await fno.StockRepositoryImpl().getFnoDashboard(<String>['PredictNTrade'], false, (_) {});
    if (d.predictNTrade.pots.isNotEmpty) return d.predictNTrade;
    // UAT rarely publishes Predict & Trade pots; the Option Store dashboard has the same StrategyInfo shape.
    try {
      final os = await OptionStoreRepositoryImpl().fetchOptionStoreDashboardData('false');
      final pots = <StrategyInfo>[...os.freePot.pots, ...os.megaPot.pots];
      if (pots.isNotEmpty) {
        _source = 'Option Store';
        return PredictNTrade(pots: pots, benchmark: BenchmarkSymbolInfo(displayName: os.freePot.benchmarkIndex.isNotEmpty ? os.freePot.benchmarkIndex : os.megaPot.benchmarkIndex));
      }
    } catch (e) {
      debugPrint('GenUI option store fallback failed: $e');
    }
    return d.predictNTrade;
  }

  bool _match(StrategyInfo s) {
    switch (_view) {
      case 'bullish':
        return s.sentiment == PredictionType.Bullish;
      case 'bearish':
        return s.sentiment == PredictionType.Bearish;
      case 'neutral':
        return s.sentiment == PredictionType.Neutral || s.sentiment == PredictionType.NA;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PredictNTrade>(
        future: _future,
        builder: (context, snap) {
          final pots = snap.data?.pots.where(_match).toList() ?? const <StrategyInfo>[];
          return CardFrame(
            title: 'Option strategy ideas',
            subtitle: snap.hasData && snap.data!.benchmark.displayName.isNotEmpty ? '$_source on ${snap.data!.benchmark.displayName}' : '$_source ready-made strategies',
            views: FnoStrategiesCard.views,
            view: _view,
            onViewChanged: (v) => setState(() => _view = v),
            onRefresh: () => setState(() {
              _future = _load();
            }),
            child: snap.hasError
                ? _error(context, snap.error!)
                : !snap.hasData
                    ? _loading()
                    : pots.isEmpty
                        ? Padding(padding: MOSpacing.paddingVertical8, child: Text('No ${_view == 'all' ? '' : '$_view '}strategies are published on UAT right now.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)))
                        : Column(children: <Widget>[
                            for (final s in pots) _StrategyTile(s: s),
                            MOSpacing.verticalSpace4,
                            Text('Strategies come from Motilal Oswal\'s $_source desk. Multi-leg orders are placed from the Option Store in the classic app.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                          ]),
          );
        },
      );
}

class _StrategyTile extends StatelessWidget {
  const _StrategyTile({required this.s});
  final StrategyInfo s;

  @override
  Widget build(BuildContext context) {
    final sentimentColor = s.sentiment == PredictionType.Bullish
        ? context.surfaceTextPositiveNormal
        : s.sentiment == PredictionType.Bearish
            ? context.surfaceTextNegativeNormal
            : context.surfaceTextNeutralNormal;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: MOSpacing.paddingAll8,
      decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(s.strategyType.isEmpty ? s.symbol : s.strategyType, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
          Text(s.sentiment.name, style: MOTypography.bodyXsmallSemibold.copyWith(color: sentimentColor)),
        ]),
        Text('${s.symbol}${s.expiryDate == 0 ? '' : ' · ${_expiryLabel(s.expiryDate)}'}${s.lotSize == 0 ? '' : ' · lot ${s.lotSize}'}${s.isMultiLeg ? ' · multi-leg' : ''}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        MOSpacing.verticalSpace6,
        Wrap(spacing: MOSpacing.spacing16, runSpacing: MOSpacing.spacing6, children: <Widget>[
          _kv(context, 'Max profit', s.maxProfit == 0 ? 'Unlimited' : _money(s.maxProfit), color: context.surfaceTextPositiveNormal),
          _kv(context, 'Max loss', s.maxLoss == 0 ? 'Unlimited' : _money(s.maxLoss.abs()), color: context.surfaceTextNegativeNormal),
          if (s.breakeven.isNotEmpty) _kv(context, 'Breakeven', s.breakeven),
          if (s.requiredFunds != 0) _kv(context, 'Funds needed', _money(s.requiredFunds)),
          if (s.riskToRewardRatio.isNotEmpty || s.riskToReward != 0) _kv(context, 'Risk : reward', s.riskToRewardRatio.isNotEmpty ? s.riskToRewardRatio : s.riskToReward.toStringAsFixed(2)),
        ]),
        if (s.description.isNotEmpty) ...<Widget>[
          MOSpacing.verticalSpace6,
          Text(s.description, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Futures
// ---------------------------------------------------------------------------

class _Futures {
  _Futures({required this.res, required this.lotSize, this.spotId, this.indexId, required this.spotExchange, required this.symbol, this.spotPrice = 0, this.indexBroadcastId = ''});
  final double spotPrice;
  final String indexBroadcastId;
  final QuoteFuturesResponse res;
  final int lotSize;
  final ScripId? spotId;
  final String? indexId;
  final int spotExchange;
  final String symbol;
}

/// "Nifty futures", "Reliance futures price", "what is the basis on Bank Nifty".
class FuturesCard extends StatefulWidget {
  const FuturesCard({super.key, this.underlying});
  final String? underlying;

  @override
  State<FuturesCard> createState() => _FuturesCardState();
}

class _FuturesCardState extends State<FuturesCard> {
  late Future<_Futures> _future = _load();

  Future<_Futures> _load() async {
    final text = (widget.underlying ?? '').trim();
    final idx = _indexId(text);
    // The option-chain dashboard tells us the symbol, spot scrip and lot size.
    final oc = OptionChainRepositoryImpl();
    OptionChainDashboard? d;
    ScripRef? ref;
    if (idx != null) {
      d = await oc.fetchQuoteOptionChainDashboardData(idx == 'SENSEX' || idx == 'BANKEX' ? Exchange.BSE.value : Exchange.NSE.value, 0, 3, indexId: _indexDisplayName[idx] ?? idx);
    } else {
      ref = await StockResolver.instance!.resolve(text);
      if (ref == null) throw Exception('Could not find "$text" in search.');
      d = await oc.fetchQuoteOptionChainDashboardData(ref.exchangeCode ?? Exchange.NSE.value, int.tryParse(ref.scripCode) ?? 0, 3);
    }
    final symbol = d?.symbol.isNotEmpty == true ? d!.symbol : (idx ?? ref?.symbol ?? text);
    final exch = d?.exchange.value ?? Exchange.NSE.value;
    final fut = await MoGetQuoteRepositoryImpl().fetchQuoteFuturesData(symbol: _chainSymbol(symbol), exchangeCode: exch);
    if (fut.expiries.isEmpty) throw Exception('No futures contracts came back for $symbol on UAT.');
    var lot = 0;
    if (d != null && d.expiry.isNotEmpty) {
      try {
        final fo = d.exchange == Exchange.BSE ? Exchange.BSE_FO.value : Exchange.NSE_FO.value;
        final ch = await oc.fetchQuoteOptionChainData(_chainSymbol(d.symbol), DateFormat('dd-MM-yyyy').format(_expiryDate(d.expiry.first.expirySeconds)), 1, exchangeCode: fo);
        lot = ch?.futureScrip.lotSize ?? 0;
      } catch (_) {}
    }
    return _Futures(
      res: fut,
      lotSize: lot,
      spotId: d?.spot.id,
      indexId: idx,
      spotExchange: exch,
      symbol: symbol,
      spotPrice: d?.spot.currentPrice ?? 0,
      indexBroadcastId: (d?.spot.indexSpot.isNotEmpty ?? false) ? d!.spot.indexSpot : (_indexDisplayName[idx] ?? idx ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Futures>(
        future: _future,
        builder: (context, snap) => CardFrame(
          live: true,
          title: snap.hasData ? '${snap.data!.symbol} futures' : 'Futures',
          subtitle: snap.hasData && snap.data!.lotSize != 0 ? 'Lot size ${snap.data!.lotSize}' : null,
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

  Widget _body(BuildContext context, _Futures f) {
    final foEx = f.spotExchange == Exchange.BSE.value ? Exchange.BSE_FO : Exchange.NSE_FO;
    double pick(double? live) => (live ?? 0) != 0 ? live! : f.spotPrice;
    Widget withSpot(Widget Function(double spot) child) => f.indexId != null
        ? LivePrice.index(indexId: f.indexBroadcastId, exchangeCode: f.spotExchange, builder: (context, t) => child(pick(t?.ltp)))
        : f.spotId != null
            ? LivePrice.scrip(scrip: f.spotId!, builder: (context, t) => child(pick(t?.ltp)))
            : child(f.spotPrice);
    return withSpot((spot) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          _kv(context, 'Spot', spot == 0 ? '— (no tick yet)' : _money(spot)),
          MOSpacing.verticalSpace8,
          for (final e in f.res.expiries) _FutureRow(id: ScripId(scripCode: e.scripCode, exchange: foEx), expirySeconds: e.expirySeconds, spot: spot, symbol: f.symbol, lot: f.lotSize),
          MOSpacing.verticalSpace6,
          Text('Basis = futures price − spot. A positive basis (premium) is normal; a discount often signals weakness. Tap a contract to trade.', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        ]));
  }
}

class _FutureRow extends StatefulWidget {
  const _FutureRow({required this.id, required this.expirySeconds, required this.spot, required this.symbol, required this.lot});
  final ScripId id;
  final int expirySeconds;
  final double spot;
  final String symbol;
  final int lot;

  @override
  State<_FutureRow> createState() => _FutureRowState();
}

class _FutureRowState extends State<_FutureRow> {
  String? _side;

  @override
  Widget build(BuildContext context) {
    final label = '${widget.symbol} ${_expiryLabel(widget.expirySeconds)} FUT';
    return Column(children: <Widget>[
      InkWell(
        onTap: () => setState(() => _side = _side == null ? '' : null),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LivePrice.scrip(
            scrip: widget.id,
            builder: (context, t) {
              final ltp = t?.ltp ?? 0;
              final basis = ltp == 0 || widget.spot == 0 ? null : ltp - widget.spot;
              return AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(label, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text(basis == null ? 'Basis —' : 'Basis ${_signed(basis)} (${basis >= 0 ? 'premium' : 'discount'})', style: MOTypography.bodyXsmallRegular.copyWith(color: basis == null ? context.surfaceTextNeutralNormal : _pnlColor(context, basis))),
                  ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                  Text(ltp == 0 ? '—' : _money(ltp), style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong)),
                  Text(t == null ? 'OI —' : '${_signed(t.perChange)}% · OI ${_compact(t.oi)}', style: MOTypography.bodyXsmallRegular.copyWith(color: t == null ? context.surfaceTextNeutralNormal : _pnlColor(context, t.perChange))),
                ]));
            },
          ),
        ),
      ),
      if (_side != null) ...<Widget>[
        Row(children: <Widget>[
          MOButton(label: 'Buy', onPressed: () => setState(() => _side = 'buy'), variant: _side == 'buy' ? MOButtonVariant.primary : MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small),
          MOSpacing.horizontalSpace8,
          MOButton(label: 'Sell', onPressed: () => setState(() => _side = 'sell'), variant: _side == 'sell' ? MOButtonVariant.primary : MOButtonVariant.secondary, color: MOButtonColor.negative, size: MOButtonSize.small),
        ]),
        if (_side!.isNotEmpty) OrderTicketCard(key: ValueKey<String>('fut-${widget.id.scripCode}-$_side'), ref: _fnoRef(widget.id, label, label), side: _side, qty: widget.lot == 0 ? null : widget.lot, product: 'intraday'),
      ],
    ]);
  }
}
