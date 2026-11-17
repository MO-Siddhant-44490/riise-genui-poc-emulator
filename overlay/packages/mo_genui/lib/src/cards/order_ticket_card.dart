import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/cards/funds_card.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_interactive/interactive/models/bracket_order_form_data.dart';
import 'package:mosl_interactive/interactive/models/gtt_order_form_data.dart';
import 'package:mosl_interactive/interactive/models/message_codes.dart';
import 'package:mosl_interactive/interactive/models/order_form_data.dart';
import 'package:mosl_interactive/interactive/repository/interactive_repository.dart';
import 'package:mosl_interactive/interactive/repository/place_order_event.dart';
import 'package:mosl_interactive/trading_core/order_life.dart' as mi;
import 'package:mosl_interactive/trading_core/order_type.dart' as mi;
import 'package:mosl_interactive/trading_core/price_factory.dart';
import 'package:mosl_security/prefs/preferences.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_orders/order_form/domain/brokerage_detailes_model.dart';
import 'package:trader_orders/order_form/domain/order_form_model.dart';
import 'package:trader_orders/order_form/models/order_form_input.dart';
import 'package:trader_orders/order_form/services/order_form_repository.dart';
import 'package:trader_proto_gen/Reports/BrokerageModel.pb.dart';
import 'package:trader_proto_gen/TradingCore/CoreEnums.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';
import 'package:trader_trading_core/extension/pb_enum_mapper.dart';

/// Buy / sell ticket with the classic order pad's full option set, entirely
/// inside the AI view.
///
/// The options are not hard-coded: the card loads the same `OrderFormModel`
/// the classic pad builds (`OrderFormRepository.orderFormModel`), so which
/// products (Delivery / Intraday / MTF / T+5), order types, validities and
/// exchanges are offered comes from the same eligibility data. Placement goes
/// through the same `InteractiveRepository` calls: `execute` for regular
/// orders, `placeGttOrder` for TrigX on Delivery, `placeBracketOrder` for
/// TrigX on Intraday. The LLM only prefills what the user said.
class OrderTicketCard extends StatefulWidget {
  const OrderTicketCard({
    super.key,
    required this.ref,
    this.side,
    this.qty,
    this.amount,
    this.orderType,
    this.price,
    this.trigger,
    this.product,
    this.validity,
    this.amo,
    this.target,
    this.stopLoss,
  });

  final ScripRef ref;
  final String? side; // buy | sell
  final int? qty;
  final double? amount; // rupees, delivery amount mode
  final String? orderType; // market | limit | sl | gtt
  final double? price;
  final double? trigger;
  final String? product; // delivery | intraday | mtf | t+5
  final String? validity; // day | ioc | gtd
  final bool? amo;
  final double? target; // TrigX target trigger
  final double? stopLoss; // TrigX stop-loss trigger

  @override
  State<OrderTicketCard> createState() => _OrderTicketCardState();
}

enum _Stage { form, placing, done }

class _OrderTicketCardState extends State<OrderTicketCard> {
  final OrderFormRepository _repo = OrderFormRepositoryImpl();

  late bool _buy = (widget.side ?? 'buy').toLowerCase() != 'sell';
  late int _qty = max(1, widget.qty ?? 1);
  bool _amountMode = false;
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  late final TextEditingController _price = TextEditingController(text: widget.price == null ? '' : widget.price!.toStringAsFixed(2));
  late final TextEditingController _trigger = TextEditingController(text: widget.trigger == null ? '' : widget.trigger!.toStringAsFixed(2));
  late final TextEditingController _disclosed = TextEditingController();
  late final TextEditingController _tgTrigger = TextEditingController(text: widget.target == null ? '' : widget.target!.toStringAsFixed(2));
  late final TextEditingController _slTrigger = TextEditingController(text: widget.stopLoss == null ? '' : widget.stopLoss!.toStringAsFixed(2));
  late final TextEditingController _trailStep = TextEditingController(text: '1');

  ProductType? _product;
  OrderType _orderType = OrderType.Market;
  OrderLife _life = OrderLife.DAY;
  DateTime? _gtdDate;
  late bool _amo = widget.amo ?? false;
  bool _sor = false;
  bool _consent = false;
  bool _advanced = false;
  late bool _trigx = (widget.orderType ?? '').toLowerCase() == 'gtt' || widget.target != null || widget.stopLoss != null;
  late bool _tg = widget.target != null;
  late bool _sl = widget.stopLoss != null;
  bool _tsl = false;
  bool _showCharges = false;
  bool _showAddFunds = false;

  Future<OrderFormModel>? _model;
  Future<BrokerageDetailResponseV2>? _charges;
  double _lastLtp = 0;
  _Stage _stage = _Stage.form;
  PlaceOrderEvent? _result;
  String? _error;
  StreamSubscription<PlaceOrderEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _model = _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final c in <TextEditingController>[_amount, _price, _trigger, _disclosed, _tgTrigger, _slTrigger, _trailStep]) {
      c.dispose();
    }
    super.dispose();
  }

  ScripId get _scripId => ScripId(scripCode: int.tryParse(widget.ref.scripCode) ?? 0, exchange: Exchange.valueOf(widget.ref.exchangeCode ?? 0) ?? Exchange.NSE);

  Future<OrderFormModel> _load() async {
    final m = await _repo.orderFormModel(OrderFormInput(scripId: _scripId, action: _buy ? OrderAction.Buy : OrderAction.Sell, source: 'GenUI'));
    _applyDefaults(m);
    return m;
  }

  /// Same defaults the classic pad applies once the model is known.
  void _applyDefaults(OrderFormModel m) {
    final wanted = (widget.product ?? '').toLowerCase();
    final products = _products(m);
    _product = products.cast<ProductType?>().firstWhere(
          (p) => switch (wanted) {
            'intraday' => p == ProductType.ValuePlus,
            'mtf' => p == ProductType.MTF,
            't+5' || 'tplus5' || 't5' => p == ProductType.Normal,
            _ => p == ProductType.Delivery,
          },
          orElse: () => products.isEmpty ? null : products.first,
        );
    _orderType = switch ((widget.orderType ?? 'market').toLowerCase()) {
      'limit' => OrderType.Limit,
      'sl' || 'stoploss' || 'stop loss' => OrderType.StopLoss,
      _ => OrderType.Market,
    };
    if (!m.allowedOrderTypes.contains(_orderType)) _orderType = m.allowedOrderTypes.contains(OrderType.Market) ? OrderType.Market : m.allowedOrderTypes.first;
    _life = switch ((widget.validity ?? 'day').toLowerCase()) { 'ioc' => OrderLife.IOC, 'gtd' => OrderLife.GTD, _ => OrderLife.DAY };
    if (!m.allowedOrderLife.contains(_life)) _life = OrderLife.DAY;
    if (_life != OrderLife.DAY || _amo) _advanced = true;
    _gtdDate ??= m.gtdRange.end;
    // Classic prefills a Sell with the sellable holdings.
    if (!_buy && widget.qty == null && m.orderData.availableQty > 0) _qty = m.orderData.availableQty;
    if (widget.amount != null) _amountMode = true;
    // Best price execution is on by default when both exchanges are available.
    _sor = _sorVisible(m);
    _lastLtp = m.bcast.ltp;
  }

  List<ProductType> _products(OrderFormModel m) {
    final out = <ProductType>[];
    if (m.allowedProducts.contains(ProductType.Delivery)) out.add(ProductType.Delivery);
    if (m.allowedProducts.contains(ProductType.ValuePlus)) out.add(ProductType.ValuePlus);
    if (m.mtfAllowed && (_buy || m.orderData.mtfQty > 0)) out.add(ProductType.MTF);
    if (m.tPlusFiveAllowed && m.marginInfo.normalPercent > 0) out.add(ProductType.Normal);
    return out;
  }

  String _productLabel(ProductType p) => switch (p) {
        ProductType.ValuePlus => 'Intraday',
        ProductType.MTF => 'MTF',
        ProductType.Normal => 'T+5',
        _ => 'Delivery',
      };

  bool _sorVisible(OrderFormModel m) =>
      !_amo && (_orderType == OrderType.Market || _orderType == OrderType.Limit) && m.allowedExchanges.map((e) => e.id.exchange).toSet().containsAll(<Exchange>{Exchange.NSE, Exchange.BSE});

  // Classic OrderLifeValidator rules for a cash scrip.
  bool _gtdDisabled() => _orderType == OrderType.Market && (_product == ProductType.Delivery || _product == ProductType.MTF || _product == ProductType.Normal);

  double _ltpOr(double fallback) => _lastLtp > 0 ? _lastLtp : fallback;
  double get _entryPrice => _orderType == OrderType.Market ? _ltpOr(0) : (double.tryParse(_price.text) ?? 0);

  double _roundTick(double v, double tick) => tick <= 0 ? v : (v / tick).round() * tick;

  void _prefillTrigX(OrderFormModel m) {
    final base = _entryPrice;
    if (base <= 0) return;
    final tick = m.quote.tickSize;
    if (_tg && _tgTrigger.text.isEmpty) _tgTrigger.text = _roundTick(base * (_buy ? 1.05 : 0.95), tick).toStringAsFixed(2);
    if (_sl && _slTrigger.text.isEmpty) _slTrigger.text = _roundTick(base * (_buy ? 0.95 : 1.05), tick).toStringAsFixed(2);
  }

  // ---------------------------------------------------------------- request

  OrderFormData _formData(OrderFormModel m) {
    final scrip = m.scrip;
    final pf = scrip.priceFactory;
    final sf = scrip.sizeFactory;
    final product = _product ?? ProductType.Delivery;
    final isMarket = _orderType == OrderType.Market;
    final isSl = _orderType == OrderType.StopLoss && !_trigx;
    final mi.OrderType type = _trigx ? (isMarket ? mi.OrderType.market : mi.OrderType.limit) : _orderType.acOrderType;
    final life = _trigx && product != ProductType.ValuePlus
        ? mi.OrderLife.gtt
        : (_advanced && !_trigx && !(_life == OrderLife.GTD && _gtdDisabled()))
            ? _life.acOrderLife
            : mi.OrderLife.day;
    final disclosedLots = int.tryParse(_disclosed.text) ?? 0;
    return OrderFormData(
      scrip: scrip,
      action: (_buy ? OrderAction.Buy : OrderAction.Sell).acOrderAction,
      productType: product.acProductType,
      orderType: type,
      orderSize: sf.fromLots(_qty),
      price: isMarket ? Price.zero : pf.getPrice(double.tryParse(_price.text) ?? 0),
      triggerPrice: isSl ? pf.getPrice(double.tryParse(_trigger.text) ?? 0) : Price.zero,
      orderLife: life,
      disclosedSize: _advanced && m.disclosedLotAllowed && disclosedLots > 0 ? sf.fromLots(disclosedLots) : null,
      validity: life == mi.OrderLife.gtd && _gtdDate != null ? DateUtils.dateOnly(_gtdDate!) : null,
      isAmo: _amo && !_trigx && !isMarket,
      remarks: 'NewOrder',
      participantCode: m.participantCode,
      surveillanceIndicator: m.quote.isSurveillance ? m.quote.shortCode : '',
      surveillanceConsent: _consent || !m.quote.isSurveillance,
      caLevel: m.quote.caLevel,
      isSOR: _sor && _sorVisible(m) && !_trigx,
      source: 'genui',
    );
  }

  int _maxLotSize(OrderFormModel m) {
    if (m.quote.maxLotSize == 0 && m.scrip.exchange.isEquity) {
      return Preferences.userConfigPref.get().cashMaxOrderQty.toInt();
    }
    return m.quote.maxLotSize;
  }

  Stream<PlaceOrderEvent> _send(OrderFormModel m) {
    final repo = getIt<InteractiveRepository>();
    final form = _formData(m);
    if (!_trigx) return repo.execute(form);
    final pf = m.scrip.priceFactory;
    final tg = _tg ? pf.getPrice(double.tryParse(_tgTrigger.text) ?? 0) : Price.zero;
    final sl = (_sl || _tsl) ? pf.getPrice(double.tryParse(_slTrigger.text) ?? 0) : Price.zero;
    final jump = _tsl ? pf.getPrice(double.tryParse(_trailStep.text) ?? 1) : Price.zero;
    final ltp = pf.getPrice(m.bcast.ltp == 0 ? m.bcast.close : m.bcast.ltp);
    if (_product == ProductType.ValuePlus) {
      // Intraday TrigX is a bracket order, as in the classic pad.
      return repo.placeBracketOrder(
        BracketOrderFormData(
          formData: form,
          targetTriggerPrice: tg,
          targetPrice: tg,
          slTriggerPrice: sl,
          slPrice: sl,
          isTrailing: _tsl,
          jumpPrice: jump,
          trailSLTriggerPrice: _tsl ? sl : Price.zero,
          trailSLPrice: _tsl ? sl : Price.zero,
          secLegBuyOrSell: form.action.reverse.charId,
          secLegOrderQty: form.orderSize.quantity,
          secLegOrderNo: '0',
        ),
        MessageCode.newBORequest,
        maxLotSize: _maxLotSize(m),
      );
    }
    final oco = _tg || _sl;
    return repo.placeGttOrder(
      GttOrderFormData(
        formData: form,
        gttIdentifier: oco ? 'M' : 'S',
        profitTriggerPrice: tg,
        profitPrice: tg,
        slTriggerPrice: _sl ? sl : Price.zero,
        slPrice: _sl ? sl : Price.zero,
        isTrailing: _tsl,
        jumpPrice: jump,
        trailSLTriggerPrice: _tsl ? sl : Price.zero,
        trailSLPrice: _tsl ? sl : Price.zero,
        secLegBuyOrSell: oco ? form.action.reverse.charId : ' ',
        secLegOrderQty: oco ? form.orderSize.quantity : 0,
        minFillQty: ltp,
      ),
      MessageCode.newGTTRequest,
      maxLotSize: _maxLotSize(m),
    );
  }

  void _place(OrderFormModel m) {
    if (_stage == _Stage.placing) return;
    setState(() {
      _stage = _Stage.placing;
      _result = null;
      _error = null;
    });
    _sub?.cancel();
    _sub = _send(m).listen((e) {
      if (!mounted) return;
      setState(() {
        _result = e;
        if (e.isSuccess) _stage = _Stage.done;
        if (e.isFailure) _stage = _Stage.form;
      });
    }, onError: (Object err) {
      if (!mounted) return;
      setState(() {
        _error = '$err';
        _stage = _Stage.form;
      });
    }, onDone: () {
      if (mounted && _stage == _Stage.placing) setState(() => _stage = _Stage.form);
    });
  }

  Future<void> _switchExchange(OrderFormModel current, ScripId id) async {
    setState(() => _model = _repo.switchExchange(current, id));
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final r = widget.ref;
    return CardFrame(
      title: '${_buy ? 'Buy' : 'Sell'} ${r.symbol}',
      subtitle: r.name,
      live: true,
      child: FutureBuilder<OrderFormModel>(
        future: _model,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Preparing the order pad…');
          final m = snap.data;
          if (snap.hasError || m == null) {
            return CardError(title: "Couldn't prepare the order.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _model = _load()));
          }
          final res = _result;
          if (_stage == _Stage.done && res != null) return _Done(event: res, summary: _summary(m), onNew: () => setState(() => _stage = _Stage.form));
          return LivePrice.scrip(
            scrip: m.id,
            builder: (context, t) {
              if (t != null && t.ltp != 0) _lastLtp = t.ltp;
              return _form(context, m, t?.ltp ?? m.bcast.ltp, t?.perChange ?? 0);
            },
          );
        },
      ),
    );
  }

  String _summary(OrderFormModel m) {
    final type = _trigx
        ? 'TrigX ${_product == ProductType.ValuePlus ? 'bracket' : 'GTT'}${_tg ? ' · target ₹${_tgTrigger.text}' : ''}${_sl || _tsl ? ' · SL ₹${_slTrigger.text}' : ''}'
        : switch (_orderType) {
            OrderType.Limit => 'Limit @ ₹${_price.text}',
            OrderType.StopLoss => 'SL @ ₹${_price.text} (trigger ₹${_trigger.text})',
            _ => 'Market',
          };
    return '${_buy ? 'Buy' : 'Sell'} $_qty × ${m.quote.tradeSymbol} (${m.id.exchange.name}) · $type · ${_productLabel(_product ?? ProductType.Delivery)}${_amo ? ' · AMO' : ''}${_life != OrderLife.DAY ? ' · ${_life.name}' : ''}';
  }

  Widget _form(BuildContext context, OrderFormModel m, double ltp, double pc) {
    final d = m.orderData;
    final strong = context.surfaceTextNeutralStrong;
    final normal = context.surfaceTextNeutralNormal;
    final products = _products(m);
    if (_product != null && !products.contains(_product)) _product = products.isEmpty ? null : products.first;
    final product = _product ?? ProductType.Delivery;
    final isMarket = _orderType == OrderType.Market;
    final isSl = _orderType == OrderType.StopLoss && !_trigx;
    if (_amountMode) {
      final amt = double.tryParse(_amount.text) ?? 0;
      final px = _entryPrice;
      if (px > 0) _qty = max(1, (amt / px).floor());
    }
    if (_trigx) _prefillTrigX(m);

    final price = _entryPrice;
    final value = _qty * price;
    final marginNeeded = price > 0 ? m.calculator.get2(_buy ? OrderAction.Buy : OrderAction.Sell, product, _qty, price) : 0.0;
    final available = d.marginAvailable;
    final shortfall = _buy && !_amo && available >= 0 && marginNeeded > available ? marginNeeded - available : 0.0;
    final sellable = product == ProductType.MTF ? d.mtfQty : product == ProductType.Normal ? d.tPlusFiveQty : d.availableQty;
    final sellShort = !_buy && product != ProductType.ValuePlus && sellable < _qty;
    final limit = double.tryParse(_price.text) ?? 0;
    final trig = double.tryParse(_trigger.text) ?? 0;
    // The proto carries the tick as a float (0.05 arrives as 0.0500000007…); work in paise.
    final tick = (m.quote.tickSize * 100).round() / 100;
    final badTick = !isMarket && limit > 0 && tick > 0 && ((limit * 100).round() % (tick * 100).round()) != 0;
    final needsPrice = !isMarket && limit <= 0;
    final badSl = isSl && (trig <= 0 || (_buy ? trig > limit : trig < limit));
    final needsConsent = m.quote.isSurveillance && !_consent;
    final trigxIncomplete = _trigx && ((_tg && (double.tryParse(_tgTrigger.text) ?? 0) <= 0) || ((_sl || _tsl) && (double.tryParse(_slTrigger.text) ?? 0) <= 0));
    final blocked = sellShort || needsPrice || badTick || badSl || needsConsent || trigxIncomplete || shortfall > 0 || _qty <= 0;
    final res = _result;
    final exchanges = m.allowedExchanges.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Price + exchange switch
        Row(children: <Widget>[
          Text(ltp == 0 ? '—' : '₹${_money(ltp)}', style: MOTypography.headingSmall.copyWith(color: normal)),
          MOSpacing.horizontalSpace8,
          Expanded(child: Text(ltp == 0 ? 'waiting for live price' : '${pct(pc)} today', style: MOTypography.bodyXsmallSemibold.copyWith(color: ltp == 0 ? strong : deltaColor(context, pc)))),
          if (exchanges.length > 1)
            Wrap(spacing: 4, children: <Widget>[
              for (final e in exchanges)
                _Chip(label: e.id.exchange.name, selected: e.id.exchange == m.id.exchange, onTap: () => _switchExchange(m, e.id)),
            ])
          else
            Text(m.id.exchange.name, style: MOTypography.bodyXsmallSemibold.copyWith(color: strong)),
        ]),
        MOSpacing.verticalSpace12,
        // Buy / Sell
        Row(children: <Widget>[
          Expanded(child: _Seg(label: 'Buy', selected: _buy, color: context.surfaceTextPositiveNormal, onTap: () => _setSide(true))),
          MOSpacing.horizontalSpace8,
          Expanded(child: _Seg(label: 'Sell', selected: !_buy, color: context.surfaceTextNegativeNormal, onTap: () => _setSide(false))),
        ]),
        MOSpacing.verticalSpace12,
        // Product
        Wrap(spacing: MOSpacing.spacing6, runSpacing: MOSpacing.spacing6, children: <Widget>[
          for (final p in products) _Chip(label: _productLabel(p), selected: product == p, onTap: () => setState(() => _product = p)),
        ]),
        if (product == ProductType.MTF || product == ProductType.Normal)
          Padding(
            padding: EdgeInsets.only(top: MOSpacing.spacing4),
            child: Text(
              product == ProductType.MTF
                  ? 'MTF: pay part now, MOSL funds the rest. Interest applies. MTF funds available ₹${_money(d.mtfFundAvailable)}.'
                  : 'T+5: pay ${m.marginInfo.normalPercent / 100}% now, settle within 5 days.',
              style: MOTypography.bodyXsmallRegular.copyWith(color: strong),
            ),
          ),
        MOSpacing.verticalSpace12,
        // Quantity / amount
        Row(children: <Widget>[
          Text(_amountMode ? 'Amount' : 'Quantity', style: MOTypography.bodySmallRegular.copyWith(color: strong)),
          if (_buy && product == ProductType.Delivery) ...<Widget>[
            MOSpacing.horizontalSpace6,
            InkWell(onTap: () => setState(() => _amountMode = !_amountMode), child: Text(_amountMode ? 'use qty' : 'use ₹ amount', style: MOTypography.bodyXsmallSemibold.copyWith(color: context.actionBackgroundPrimaryDefault))),
          ],
          const Spacer(),
          if (_amountMode)
            SizedBox(width: 140, child: _Field(controller: _amount, label: 'Invest ₹', onChanged: (_) => setState(() {})))
          else ...<Widget>[
            _Step(icon: Icons.remove, onTap: () => setState(() => _qty = max(1, _qty - 1))),
            SizedBox(width: 56, child: Text('$_qty', textAlign: TextAlign.center, style: MOTypography.bodyLargeSemibold.copyWith(color: normal))),
            _Step(icon: Icons.add, onTap: () => setState(() => _qty++)),
          ],
        ]),
        if (_amountMode) Text('≈ $_qty shares at ₹${_money(price)}', style: MOTypography.bodyXsmallRegular.copyWith(color: strong)),
        if (!_buy)
          Padding(
            padding: EdgeInsets.only(top: MOSpacing.spacing4),
            child: Text(
              sellable > 0 ? 'You can sell $sellable (${_productLabel(product)})' : 'No ${product == ProductType.ValuePlus ? '' : 'holdings in this stock'}${product == ProductType.ValuePlus ? 'holdings needed for intraday short' : ' · switch to Intraday to short'}',
              style: MOTypography.bodyXsmallRegular.copyWith(color: sellShort ? context.surfaceTextNegativeNormal : strong),
            ),
          ),
        MOSpacing.verticalSpace12,
        // Order type
        Wrap(spacing: MOSpacing.spacing6, runSpacing: MOSpacing.spacing6, children: <Widget>[
          for (final t in <OrderType>[OrderType.Market, OrderType.Limit, OrderType.StopLoss])
            if (m.allowedOrderTypes.contains(t) && !(t == OrderType.StopLoss && _trigx))
              _Chip(label: t == OrderType.StopLoss ? 'Stop loss' : t.name, selected: _orderType == t, onTap: () => setState(() => _orderType = t)),
          _Chip(label: 'TrigX', selected: _trigx, onTap: () => setState(() {
                _trigx = !_trigx;
                if (_trigx && _orderType == OrderType.StopLoss) _orderType = OrderType.Limit;
                if (_trigx && !_tg && !_sl) _sl = true;
              })),
        ]),
        if (!isMarket) ...<Widget>[
          MOSpacing.verticalSpace8,
          Row(children: <Widget>[
            Expanded(child: _Field(controller: _price, label: 'Limit price (tick ₹${tick.toStringAsFixed(2)})', onChanged: (_) => setState(() {}))),
            if (isSl) ...<Widget>[MOSpacing.horizontalSpace8, Expanded(child: _Field(controller: _trigger, label: 'Trigger price', onChanged: (_) => setState(() {})))],
          ]),
          if (badTick) _Hint('Price must be a multiple of ₹${tick.toStringAsFixed(2)}.', warn: true),
          if (badSl && trig > 0) _Hint(_buy ? 'For a buy SL the trigger must be at or below the limit price.' : 'For a sell SL the trigger must be at or above the limit price.', warn: true),
        ],
        // TrigX legs
        if (_trigx) ...<Widget>[
          MOSpacing.verticalSpace8,
          _Hint(product == ProductType.ValuePlus ? 'Bracket order: entry now, target and stop loss as linked intraday legs.' : 'GTT: target and stop-loss legs stay active beyond today until triggered.'),
          Row(children: <Widget>[
            _Toggle(label: 'Target', value: _tg, onChanged: (v) => setState(() => _tg = v)),
            _Toggle(label: 'Stop loss', value: _sl, onChanged: (v) => setState(() => _sl = v)),
            _Toggle(label: 'Trailing', value: _tsl, onChanged: (v) => setState(() => _tsl = v)),
          ]),
          Row(children: <Widget>[
            if (_tg) Expanded(child: _Field(controller: _tgTrigger, label: 'Target ₹', onChanged: (_) => setState(() {}))),
            if (_tg && (_sl || _tsl)) MOSpacing.horizontalSpace8,
            if (_sl || _tsl) Expanded(child: _Field(controller: _slTrigger, label: 'Stop loss ₹', onChanged: (_) => setState(() {}))),
            if (_tsl) ...<Widget>[MOSpacing.horizontalSpace8, SizedBox(width: 90, child: _Field(controller: _trailStep, label: 'Trail step', onChanged: (_) => setState(() {})))],
          ]),
        ],
        MOSpacing.verticalSpace8,
        // Advanced
        InkWell(
          onTap: () => setState(() => _advanced = !_advanced),
          child: Row(children: <Widget>[
            Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 18, color: context.surfaceIconNeutralNormal),
            MOSpacing.horizontalSpace4,
            Text('Advanced${_advanced ? '' : ' · ${_life.name}${_amo ? ' · AMO' : ''}${_sor ? ' · best price' : ''}'}', style: MOTypography.bodyXsmallSemibold.copyWith(color: strong)),
          ]),
        ),
        if (_advanced && !_trigx) ...<Widget>[
          MOSpacing.verticalSpace8,
          Row(children: <Widget>[
            Text('Validity', style: MOTypography.bodyXsmallRegular.copyWith(color: strong)),
            MOSpacing.horizontalSpace8,
            for (final l in <OrderLife>[OrderLife.DAY, OrderLife.IOC, OrderLife.GTD])
              if (m.allowedOrderLife.contains(l) && !(l == OrderLife.GTD && _gtdDisabled()))
                Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: _Chip(label: l.name, selected: _life == l, onTap: () => setState(() => _life = l))),
          ]),
          if (_life == OrderLife.GTD)
            Padding(
              padding: EdgeInsets.only(top: MOSpacing.spacing6),
              child: Row(children: <Widget>[
                Text('Good till ${DateFormat('d MMM yyyy').format(_gtdDate ?? m.gtdRange.end)}', style: MOTypography.bodyXsmallRegular.copyWith(color: normal)),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(context: context, initialDate: _gtdDate ?? m.gtdRange.end, firstDate: m.gtdRange.start, lastDate: m.gtdRange.end);
                    if (picked != null) setState(() => _gtdDate = picked);
                  },
                  child: const Text('Change'),
                ),
              ]),
            ),
          Row(children: <Widget>[
            if (!isMarket) _Toggle(label: 'AMO (after market)', value: _amo, onChanged: (v) => setState(() {
                  _amo = v;
                  if (v) _sor = false;
                })),
            if (_sorVisible(m)) _Toggle(label: 'Best price (NSE/BSE)', value: _sor, onChanged: (v) => setState(() => _sor = v)),
          ]),
          if (m.disclosedLotAllowed)
            Padding(
              padding: EdgeInsets.only(top: MOSpacing.spacing6),
              child: Row(children: <Widget>[
                Expanded(child: _Field(controller: _disclosed, label: 'Disclosed qty (optional)', onChanged: (_) => setState(() {}), prefix: '')),
              ]),
            ),
        ],
        if (m.quote.isSurveillance)
          Padding(
            padding: EdgeInsets.only(top: MOSpacing.spacing6),
            child: _Toggle(label: 'This scrip is under exchange surveillance (${m.quote.shortCode}). I understand.', value: _consent, onChanged: (v) => setState(() => _consent = v)),
          ),
        MOSpacing.verticalSpace12,
        Divider(height: 1, color: context.surfaceBorderNeutralNormal),
        MOSpacing.verticalSpace8,
        _KV('Order value', value == 0 ? '—' : '₹${_money(value)}'),
        _KV('Margin required', value == 0 ? '—' : '₹${_money(marginNeeded)}'),
        _KV('Available margin', available == 0 ? '—' : '₹${_money(available)}', warn: shortfall > 0),
        if (d.isBanScrip) const _KV('Note', 'Scrip is in ban period', warn: true),
        // Charges
        InkWell(
          onTap: () => setState(() {
            _showCharges = !_showCharges;
            _charges ??= _repo.brokerageDetails(BrokerageDetailsInput(productType: product.value, scripCode: m.scrip.code, exchange: m.scrip.exchange.code, action: (_buy ? OrderAction.Buy : OrderAction.Sell).value));
          }),
          child: Padding(
            padding: MOSpacing.paddingVertical4,
            child: Row(children: <Widget>[
              Expanded(child: Text('Charges & brokerage', style: MOTypography.bodySmallRegular.copyWith(color: strong))),
              Icon(_showCharges ? Icons.expand_less : Icons.expand_more, size: 18, color: context.surfaceIconNeutralNormal),
            ]),
          ),
        ),
        if (_showCharges) _Charges(future: _charges!, qty: _qty, price: price),
        // Shortfall → add funds inline
        if (shortfall > 0) ...<Widget>[
          MOSpacing.verticalSpace6,
          Container(
            padding: MOSpacing.paddingAll8,
            decoration: BoxDecoration(color: context.feedbackBackgroundWarningSubtle, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
            child: Row(children: <Widget>[
              Icon(Icons.account_balance_wallet_outlined, size: 18, color: context.feedbackIconWarningNormal),
              MOSpacing.horizontalSpace8,
              Expanded(child: Text('Add ₹${_money(shortfall)} more to place this order.', style: MOTypography.bodyXsmallRegular.copyWith(color: normal))),
              TextButton(onPressed: () => setState(() => _showAddFunds = !_showAddFunds), child: Text(_showAddFunds ? 'Hide' : 'Add funds')),
            ]),
          ),
          if (_showAddFunds) Padding(padding: EdgeInsets.only(top: MOSpacing.spacing8), child: FundsCard(view: 'add', amount: shortfall.ceilToDouble())),
        ],
        if (_error != null || (res != null && res.isFailure && _stage != _Stage.done)) ...<Widget>[
          MOSpacing.verticalSpace8,
          Container(
            padding: MOSpacing.paddingAll8,
            decoration: BoxDecoration(color: context.feedbackBackgroundWarningSubtle, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
            child: Row(children: <Widget>[
              Icon(Icons.error_outline, size: 18, color: context.feedbackIconWarningNormal),
              MOSpacing.horizontalSpace8,
              Expanded(child: Text(_error ?? 'Not placed: ${res!.message.friendly}', style: MOTypography.bodyXsmallRegular.copyWith(color: normal))),
            ]),
          ),
        ],
        MOSpacing.verticalSpace12,
        MOButton(
          label: _stage == _Stage.placing ? 'Placing…' : '${_buy ? 'Buy' : 'Sell'} $_qty ${m.quote.tradeSymbol}${_trigx ? ' (TrigX)' : ''}',
          onPressed: _stage == _Stage.placing || blocked ? null : () => _place(m),
          isLoading: _stage == _Stage.placing,
          variant: MOButtonVariant.primary,
          color: _buy ? MOButtonColor.positive : MOButtonColor.negative,
          size: MOButtonSize.medium,
          isFullWidth: true,
        ),
        MOSpacing.verticalSpace6,
        Text('Same order service and eligibility rules as the classic order pad. UAT account.', style: MOTypography.bodyXsmallRegular.copyWith(color: strong)),
      ],
    );
  }

  void _setSide(bool buy) {
    if (_buy == buy) return;
    setState(() {
      _buy = buy;
      // The pad model depends on the side (MTF/T+5 sellable quantities), reload it like the classic pad does.
      _model = _load();
    });
  }
}

class _Charges extends StatelessWidget {
  const _Charges({required this.future, required this.qty, required this.price});
  final Future<BrokerageDetailResponseV2> future;
  final int qty;
  final double price;

  @override
  Widget build(BuildContext context) => FutureBuilder<BrokerageDetailResponseV2>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching charges…');
          final r = snap.data;
          if (snap.hasError || r == null) return _Hint("Couldn't load charges: ${snap.error ?? 'no data'}", warn: true);
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          final val = MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (r.brokerageType.isNotEmpty) Text('Plan: ${r.brokerageType}', style: sub),
            for (final s in r.brokerageDetails) ...<Widget>[
              Padding(padding: EdgeInsets.only(top: MOSpacing.spacing4), child: Text(s.title, style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal))),
              for (final v in s.values)
                Row(children: <Widget>[Expanded(child: Text(v.label, style: sub)), Text(_fmtCharge(v.value), style: val)]),
            ],
            Text('Rates as per your plan; the exact amount is shown on the contract note.', style: sub),
          ]);
        },
      );

  String _fmtCharge(double v) => v == v.roundToDouble() && v.abs() >= 1 ? '₹${_money(v)}' : '$v';
}

class _Done extends StatelessWidget {
  const _Done({required this.event, required this.summary, required this.onNew});
  final PlaceOrderEvent event;
  final String summary;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final orderNo = e is OrderSuccess ? e.orderNo : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.check_circle, color: context.surfaceTextPositiveNormal, size: 20),
          MOSpacing.horizontalSpace6,
          Text('Order placed', style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
        ]),
        MOSpacing.verticalSpace4,
        Text(summary, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        Text(orderNo.isEmpty ? e.message.friendly : 'Order no. $orderNo', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
        MOSpacing.verticalSpace8,
        MOButton(label: 'Place another', onPressed: onNew, variant: MOButtonVariant.tertiary, color: MOButtonColor.primary, size: MOButtonSize.small),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Row(children: <Widget>[
            Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
            Expanded(child: Text(label, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
          ]),
        ),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text, {this.warn = false});
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: MOSpacing.spacing4),
        child: Text(text, style: MOTypography.bodyXsmallRegular.copyWith(color: warn ? context.surfaceTextNegativeNormal : context.surfaceTextNeutralStrong)),
      );
}

class _Seg extends StatelessWidget {
  const _Seg({required this.label, required this.selected, required this.color, required this.onTap});
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(MOSpacing.spacing8),
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: selected ? color : context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
          child: Text(label, style: MOTypography.bodySmallSemibold.copyWith(color: selected ? context.surfaceTextStaticWhiteNormal : context.surfaceTextNeutralStrong)),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: MOSpacing.spacing10),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: selected ? context.actionBackgroundPrimaryDefault : context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(14)),
          child: Text(label, style: MOTypography.labelSmallSemiboldAbc.copyWith(color: selected ? context.surfaceTextStaticWhiteNormal : context.surfaceTextNeutralStrong)),
        ),
      );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: context.surfaceBackgroundNeutralFaded, borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, size: 18, color: context.surfaceIconNeutralNormal),
        ),
      );
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.label, required this.onChanged, this.prefix = '₹'});
  final TextEditingController controller;
  final String label;
  final String prefix;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          labelStyle: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong),
          prefixText: prefix.isEmpty ? null : prefix,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(MOSpacing.spacing8), borderSide: BorderSide(color: context.surfaceBorderNeutralNormal)),
        ),
      );
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v, {this.warn = false});
  final String k;
  final String v;
  final bool warn;

  @override
  Widget build(BuildContext context) => Padding(
        padding: MOSpacing.paddingVertical2,
        child: Row(children: <Widget>[
          Expanded(child: Text(k, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
          Text(v, style: MOTypography.bodySmallSemibold.copyWith(color: warn ? context.surfaceTextNegativeNormal : context.surfaceTextNeutralNormal)),
        ]),
      );
}

String _money(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
