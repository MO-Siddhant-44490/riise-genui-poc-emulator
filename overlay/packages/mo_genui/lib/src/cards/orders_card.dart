import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_interactive/interactive/models/order_form_data.dart';
import 'package:mosl_interactive/interactive/models/order_request_values.dart';
import 'package:mosl_interactive/interactive/repository/interactive_repository.dart';
import 'package:mosl_interactive/interactive/repository/place_order_event.dart';
import 'package:mosl_interactive/trading_core/order_action.dart' as mi;
import 'package:mosl_interactive/trading_core/order_type.dart' as mi;
import 'package:mosl_interactive/trading_core/price_factory.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_extensions/order_detail_entry_extensions.dart';
import 'package:trader_network/DIOApiService2.dart';
import 'package:trader_network/URL.dart';
import 'package:trader_network/models/constants.dart';
import 'package:trader_network/trader_network.dart';
import 'package:trader_trading_core/extension/pb_enum_mapper.dart';
import 'package:trader_trading_core/extension/scrip_quote_extensions.dart';
import 'package:trader_orders/order_position/domain/net_position_repository.dart';
import 'package:trader_proto_gen/Reports/NetPositions.pb.dart';
import 'package:trader_proto_gen/Reports/OrderBookModels.pb.dart';
import 'package:trader_proto_gen/Reports/OrderReportModels.pb.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:trader_proto_gen/TradingCore/CoreEnums.pbenum.dart';

/// Order book and positions, from the same repository the Trades tab uses.
/// Pending orders can be modified or cancelled right here: both go through
/// `InteractiveRepository.placeOrder` with the same request objects the
/// classic order book builds (`cancelOrderRequest`, `OrderRequestValues.modifyOrder`).
class OrdersCard extends StatefulWidget {
  const OrdersCard({super.key, this.view, this.stock, this.intent});

  final String? view;

  /// Optional stock name/symbol to narrow the list to (as the user wrote it).
  final String? stock;

  /// "cancel" | "modify" | "exit": opens the matching row's action directly.
  final String? intent;

  static const List<String> views = <String>['pending', 'completed', 'positions', 'trigx'];

  @override
  State<OrdersCard> createState() => _OrdersCardState();
}

class _OrdersCardState extends State<OrdersCard> {
  late String _view = OrdersCard.views.contains(widget.view) ? widget.view! : 'pending';
  late String _filter = (widget.stock ?? '').trim().toLowerCase();
  final Map<String, Future<dynamic>> _futures = <String, Future<dynamic>>{};

  NetPositionRepository get _repo => getIt<NetPositionRepository>();

  Future<dynamic> _load(String view) => _futures.putIfAbsent(view, () {
        switch (view) {
          case 'positions':
            return _repo.getNetPosition(assetType: 'All', type: 'net');
          case 'completed':
            return _repo.getOrderReport(orderType: 'Orders', status: 'Completed');
          case 'trigx':
            // Same report endpoint the classic TrigX tab uses for bracket orders; GTT uses the GTT type.
            return Future.wait(<Future<OrderReportResponseV4>>[
              callApiWithDio(url: '${URL.GTT_ORDERS_REPORT}?type=GTT&lastFetchTime=0', apiVersion: Constants.API_V4_0, runtimeType: OrderReportResponseV4(), requestType: HttpMethod.get),
              callApiWithDio(url: '${URL.GTT_ORDERS_REPORT}?type=BO&lastFetchTime=0', apiVersion: Constants.API_V4_0, runtimeType: OrderReportResponseV4(), requestType: HttpMethod.get),
            ]);
          default:
            return _repo.getOrderReport(orderType: 'Orders', status: 'Pending');
        }
      });

  void _refresh() => setState(() => _futures.remove(_view));

  bool _matches(String symbol, String description) =>
      _filter.isEmpty || symbol.toLowerCase().contains(_filter) || description.toLowerCase().contains(_filter);

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    return CardFrame(
      title: _view == 'positions' ? 'My positions' : _view == 'trigx' ? 'My TrigX orders (GTT / bracket)' : 'My orders',
      subtitle: _filter.isEmpty ? null : 'Showing: ${widget.stock}',
      views: OrdersCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: _refresh,
      child: FutureBuilder<dynamic>(
        future: _load(_view),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
          if (snap.hasError || snap.data == null) {
            return CardError(title: "Couldn't load this.", message: '${snap.error ?? 'No data'}', onRetry: _refresh);
          }
          if (_view == 'positions') {
            final p = snap.data as PositionResponse;
            final rows = p.net.where((s) => _matches(s.tradeSymbol, '')).toList();
            if (rows.isEmpty) return _empty(context, 'No open positions${_filter.isEmpty ? '' : ' in ${widget.stock}'}.');
            final openExit = widget.intent == 'exit' && rows.length == 1;
            return Column(children: <Widget>[for (final s in rows) _PositionRow(key: ValueKey<String>('${s.id.scripCode}-${s.product.value}'), s: s, repo: _repo, onChanged: _refresh, openExit: openExit)]);
          }
          if (_view == 'trigx') {
            final lists = snap.data as List<OrderReportResponseV4>;
            final rows = <OrderReport>[for (final r in lists) ...r.pending, for (final r in lists) ...r.completed].where((o) => _matches(o.tradeSymbol, o.description)).toList();
            if (rows.isEmpty) return _empty(context, 'No GTT or bracket orders.');
            return Column(children: <Widget>[for (final o in rows.take(10)) _OrderRow(o: o)]);
          }
          final r = snap.data as OrderReportResponseV4;
          final all = _view == 'completed' ? r.completed : r.pending;
          final rows = all.where((o) => _matches(o.tradeSymbol, o.description)).toList();
          if (rows.isEmpty) {
            return _empty(context, _view == 'completed' ? 'No completed orders today.' : 'No pending orders${_filter.isEmpty ? '' : ' for ${widget.stock}'}.');
          }
          final openAction = intent != null && rows.length == 1 && _view == 'pending';
          return Column(children: <Widget>[
            for (final o in rows.take(10))
              _view == 'pending'
                  ? _PendingOrderRow(key: ValueKey<String>(o.orderInfo.uniqueOrderId), o: o, repo: _repo, onChanged: _refresh, openAction: openAction ? intent : null)
                  : _OrderRow(o: o),
          ]);
        },
      ),
    );
  }

  Widget _empty(BuildContext context, String text) => Row(children: <Widget>[
        Expanded(child: Text(text, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
        if (_filter.isNotEmpty)
          TextButton(onPressed: () => setState(() => _filter = ''), child: Text('Show all', style: MOTypography.labelSmallBoldAbc)),
      ]);
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.o});
  final OrderReport o;

  @override
  Widget build(BuildContext context) {
    final buy = o.orderInfo.orderAction == OrderAction.Buy;
    final time = o.latestTradeTime == 0 ? '' : DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(o.latestTradeTime * (o.latestTradeTime < 100000000000 ? 1000 : 1)));
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: AdaptiveRow(start: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[_SideBadge(buy: buy), MOSpacing.horizontalSpace10]), leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(o.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            Text('${o.orderInfo.orderType.name} · ${o.orderInfo.productType.name}${time.isEmpty ? '' : ' · $time'}${o.reason.isEmpty ? '' : ' · ${o.reason}'}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
          Text('${o.orderQty - o.quantityRemaining}/${o.orderQty}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
          Text(o.tradePrice == 0 ? 'Mkt' : '₹${_money(o.tradePrice)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
        ])),
    );
  }
}

enum _Mode { idle, confirmCancel, modify, busy, done, failed }

/// A pending order with inline Modify / Cancel. Nothing leaves the chat.
class _PendingOrderRow extends StatefulWidget {
  const _PendingOrderRow({super.key, required this.o, required this.repo, required this.onChanged, this.openAction});
  final OrderReport o;
  final NetPositionRepository repo;
  final VoidCallback onChanged;
  final String? openAction;

  @override
  State<_PendingOrderRow> createState() => _PendingOrderRowState();
}

class _PendingOrderRowState extends State<_PendingOrderRow> {
  late _Mode _mode = widget.openAction == 'cancel' && widget.o.isCancellable
      ? _Mode.confirmCancel
      : widget.openAction == 'modify' && widget.o.isEditable
          ? _Mode.modify
          : _Mode.idle;
  late final TextEditingController _qty = TextEditingController(text: '${widget.o.quantityRemaining}');
  late final TextEditingController _price = TextEditingController(text: widget.o.orderInfo.orderPrice == 0 ? '' : widget.o.orderInfo.orderPrice.toStringAsFixed(2));
  late bool _market = widget.o.orderInfo.orderType == OrderType.Market;
  String _status = '';
  StreamSubscription<PlaceOrderEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _qty.dispose();
    _price.dispose();
    super.dispose();
  }

  /// The report row has no series/lot info; the order-details call returns the
  /// full `OrderDetailEntry` the classic book builds its requests from.
  Future<OrderDetailEntry> _entry() {
    final info = widget.o.orderInfo;
    return widget.repo.getOrderDetails(info.orderId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), ''), info.uniqueOrderId, orderStatus: info.orderStatus);
  }

  Future<void> _send(Future<OrderRequestValues> Function() build, String verb) async {
    setState(() {
      _mode = _Mode.busy;
      _status = '$verb…';
    });
    try {
      final req = await build();
      _sub?.cancel();
      _sub = getIt<InteractiveRepository>().placeOrder(req).listen((e) {
        if (!mounted) return;
        setState(() {
          _mode = e.isSuccess ? _Mode.done : _Mode.failed;
          _status = e.isSuccess ? (e is OrderSuccess && e.orderNo.isNotEmpty ? 'Order no. ${e.orderNo}' : e.message.friendly) : e.message.friendly;
        });
        if (e.isSuccess) widget.onChanged();
      }, onError: (Object err) {
        if (!mounted) return;
        setState(() {
          _mode = _Mode.failed;
          _status = '$err';
        });
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _mode = _Mode.failed;
        _status = '$err';
      });
    }
  }

  Future<void> _cancel() => _send(() async => (await _entry()).cancelOrderRequest(), 'Cancelling');

  Future<void> _modify() => _send(() async {
        final entry = await _entry();
        final base = entry.obtainOrderFormData();
        final scrip = base.scrip;
        final qty = int.tryParse(_qty.text.trim()) ?? widget.o.quantityRemaining;
        final price = double.tryParse(_price.text.trim()) ?? 0;
        if (!_market && price <= 0) throw 'Enter a limit price.';
        final form = OrderFormData(
          scrip: scrip,
          action: base.action,
          productType: base.productType,
          orderType: _market ? mi.OrderType.market : mi.OrderType.limit,
          orderSize: scrip.sizeFactory.fromQuantity(qty),
          price: _market ? Price.zero : scrip.priceFactory.getPrice(price),
          triggerPrice: base.triggerPrice,
          isAmo: base.isAmo,
          orderLife: base.orderLife,
          disclosedSize: base.disclosedSize,
          remarks: base.remarks,
          caLevel: base.caLevel,
          source: 'genui',
        );
        return OrderRequestValues.modifyOrder(entry.editOrder(), form);
      }, 'Modifying');

  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    final buy = o.orderInfo.orderAction == OrderAction.Buy;
    final labelStyle = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        AdaptiveRow(start: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[_SideBadge(buy: buy), MOSpacing.horizontalSpace10]), leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(o.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text('${o.orderInfo.orderType.name} · ${o.orderInfo.productType.name} · ${o.orderInfo.orderStatus.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
            ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
            Text('${o.orderQty - o.quantityRemaining}/${o.orderQty}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            Text(o.orderInfo.orderPrice == 0 ? 'Mkt' : '₹${_money(o.orderInfo.orderPrice)}', style: labelStyle),
          ])),
        if (_mode == _Mode.idle && (o.isEditable || o.isCancellable))
          Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
            if (o.isEditable) TextButton(onPressed: () => setState(() => _mode = _Mode.modify), child: const Text('Modify')),
            if (o.isCancellable) TextButton(onPressed: () => setState(() => _mode = _Mode.confirmCancel), child: const Text('Cancel')),
          ]),
        if (_mode == _Mode.confirmCancel)
          Row(children: <Widget>[
            Expanded(child: Text('Cancel this ${buy ? 'buy' : 'sell'} order of ${o.quantityRemaining} ${o.tradeSymbol}?', style: labelStyle)),
            TextButton(onPressed: () => setState(() => _mode = _Mode.idle), child: const Text('Keep')),
            MOButton(label: 'Yes, cancel', onPressed: _cancel, variant: MOButtonVariant.primary, color: MOButtonColor.negative, size: MOButtonSize.small),
          ]),
        if (_mode == _Mode.modify) ...<Widget>[
          MOSpacing.verticalSpace6,
          Row(children: <Widget>[
            Expanded(child: _field(context, _qty, 'Qty')),
            MOSpacing.horizontalSpace8,
            Expanded(child: _field(context, _price, 'Price', enabled: !_market)),
            MOSpacing.horizontalSpace8,
            ChoiceChip(label: const Text('Market'), selected: _market, onSelected: (_) => setState(() => _market = true)),
            MOSpacing.horizontalSpace4,
            ChoiceChip(label: const Text('Limit'), selected: !_market, onSelected: (_) => setState(() => _market = false)),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
            TextButton(onPressed: () => setState(() => _mode = _Mode.idle), child: const Text('Discard')),
            MOButton(label: 'Update order', onPressed: _modify, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small),
          ]),
        ],
        if (_mode == _Mode.busy || _mode == _Mode.done || _mode == _Mode.failed)
          Padding(
            padding: MOSpacing.paddingVertical4,
            child: Row(children: <Widget>[
              if (_mode == _Mode.busy) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              if (_mode != _Mode.busy)
                Icon(_mode == _Mode.done ? Icons.check_circle : Icons.error_outline, size: 14, color: _mode == _Mode.done ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
              MOSpacing.horizontalSpace6,
              Expanded(child: Text(_status, style: labelStyle)),
              if (_mode == _Mode.failed) TextButton(onPressed: () => setState(() => _mode = _Mode.idle), child: const Text('Retry')),
            ]),
          ),
      ]),
    );
  }

  Widget _field(BuildContext context, TextEditingController c, String label, {bool enabled = true}) => TextField(
        controller: c,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal),
        decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
      );
}

class _SideBadge extends StatelessWidget {
  const _SideBadge({required this.buy});
  final bool buy;

  @override
  Widget build(BuildContext context) => Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: buy ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal, borderRadius: BorderRadius.circular(6)),
        child: Text(buy ? 'B' : 'S', style: MOTypography.labelSmallBoldAbc.copyWith(color: context.surfaceTextStaticWhiteNormal)),
      );
}

class _PositionRow extends StatefulWidget {
  const _PositionRow({super.key, required this.s, required this.repo, required this.onChanged, this.openExit = false});
  final NetPositionScrip s;
  final NetPositionRepository repo;
  final VoidCallback onChanged;
  final bool openExit;

  @override
  State<_PositionRow> createState() => _PositionRowState();
}

/// Exit = reverse market order for the net quantity, built the way the
/// classic Positions tab builds its exit orders (quote → scrip → OrderFormData).
class _PositionRowState extends State<_PositionRow> {
  late _Mode _mode = widget.openExit && widget.s.netQty != 0 ? _Mode.confirmCancel : _Mode.idle;
  String _status = '';
  StreamSubscription<PlaceOrderEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _exit() async {
    final s = widget.s;
    setState(() {
      _mode = _Mode.busy;
      _status = 'Exiting…';
    });
    try {
      final quotes = await widget.repo.getQuoteList(<ScripId>[s.id]);
      final quote = quotes.quotes.firstWhere((q) => q.id.scripCode == s.id.scripCode, orElse: () => quotes.quotes.first);
      final scrip = quote.getScrip();
      final form = OrderFormData(
        scrip: scrip,
        action: s.netQty > 0 ? mi.OrderAction.sell : mi.OrderAction.buy,
        productType: s.product.acProductType,
        orderType: mi.OrderType.market,
        orderSize: scrip.sizeFactory.fromQuantity(s.netQty.abs()),
        price: Price.zero,
        remarks: 'NewOrder',
        caLevel: quote.caLevel,
        source: 'genui',
      );
      _sub = getIt<InteractiveRepository>().execute(form).listen((e) {
        if (!mounted) return;
        setState(() {
          _mode = e.isSuccess ? _Mode.done : _Mode.failed;
          _status = e.isSuccess ? (e is OrderSuccess && e.orderNo.isNotEmpty ? 'Exit order no. ${e.orderNo}' : e.message.friendly) : e.message.friendly;
        });
        if (e.isSuccess) widget.onChanged();
      }, onError: (Object err) {
        if (mounted) setState(() {
          _mode = _Mode.failed;
          _status = '$err';
        });
      });
    } catch (err) {
      if (mounted) setState(() {
        _mode = _Mode.failed;
        _status = '$err';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final labelStyle = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(s.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              Text('${s.netQty > 0 ? 'Long' : 'Short'} ${s.netQty.abs()} @ ₹${_money(s.netAvg)} · ${s.product.name}', style: labelStyle),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
            Text(signed(s.overallMTM), style: MOTypography.bodySmallSemibold.copyWith(color: deltaColor(context, s.overallMTM))),
            Text('today ${signed(s.dayMTM)}', style: MOTypography.bodyXsmallRegular.copyWith(color: deltaColor(context, s.dayMTM))),
          ]),
          if (_mode == _Mode.idle && s.netQty != 0 && s.canSquareOff)
            TextButton(onPressed: () => setState(() => _mode = _Mode.confirmCancel), child: const Text('Exit')),
        ]),
        if (_mode == _Mode.confirmCancel)
          Row(children: <Widget>[
            Expanded(child: Text('${s.netQty > 0 ? 'Sell' : 'Buy'} ${s.netQty.abs()} ${s.tradeSymbol} at market to exit?', style: labelStyle)),
            TextButton(onPressed: () => setState(() => _mode = _Mode.idle), child: const Text('Keep')),
            MOButton(label: 'Exit at market', onPressed: _exit, variant: MOButtonVariant.primary, color: MOButtonColor.negative, size: MOButtonSize.small),
          ]),
        if (_mode == _Mode.busy || _mode == _Mode.done || _mode == _Mode.failed)
          Row(children: <Widget>[
            if (_mode == _Mode.busy) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            if (_mode != _Mode.busy) Icon(_mode == _Mode.done ? Icons.check_circle : Icons.error_outline, size: 14, color: _mode == _Mode.done ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
            MOSpacing.horizontalSpace6,
            Expanded(child: Text(_status, style: labelStyle)),
            if (_mode == _Mode.failed) TextButton(onPressed: () => setState(() => _mode = _Mode.idle), child: const Text('Retry')),
          ]),
      ]),
    );
  }
}

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
