import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/entities/stock_resolver.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_stock_sip/domain/mo_stock_sip_repository.dart';
import 'package:mo_stock_sip/helper/stock_sip_enum.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_proto_gen/StockSip/StockSipModels.pb.dart';
import 'package:trader_proto_gen/StockSip/StockSipModels.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/Exchange.pbenum.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';

/// Stock SIPs: the user's running SIPs (pause / resume / cancel) and starting
/// a new one, through the same `MoStockSipRepository` the classic SIP screens
/// use (`validateOrder` → `createOrder`). A new SIP that needs a bank
/// mandate stops at the mandate step, which the classic app does through the
/// Razorpay SDK; that step is not hosted in the AI view yet.
class StockSipCard extends StatefulWidget {
  const StockSipCard({super.key, this.ref, this.stock, this.amount, this.qty, this.frequency, this.intent});
  final ScripRef? ref;
  final String? stock;
  final double? amount;
  final int? qty;
  final String? frequency; // daily | weekly | monthly
  final String? intent; // view | start

  static const List<String> views = <String>['mine', 'start'];

  @override
  State<StockSipCard> createState() => _StockSipCardState();
}

class _StockSipCardState extends State<StockSipCard> {
  MoStockSipRepository get _repo => getIt<MoStockSipRepository>();
  late String _view = widget.intent == 'start' || widget.ref != null || widget.stock != null ? 'start' : 'mine';
  Future<StockSipOrderDetailResponseV2>? _book;
  String _rowStatus = '';

  @override
  Widget build(BuildContext context) => CardFrame(
        title: _view == 'start' ? 'Start a stock SIP' : 'My stock SIPs',
        views: StockSipCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() => _book = null),
        child: _view == 'start' ? _StartSip(repo: _repo, ref: widget.ref, stock: widget.stock, amount: widget.amount, qty: widget.qty, frequency: widget.frequency, onStarted: () => setState(() { _view = 'mine'; _book = null; })) : _mine(context),
      );

  Widget _mine(BuildContext context) => FutureBuilder<StockSipOrderDetailResponseV2>(
        future: _book ??= _repo.getOrderBook(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching your SIPs…');
          final r = snap.data;
          if (snap.hasError || r == null) return CardError(title: "Couldn't load SIPs.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _book = null));
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          if (r.orders.isEmpty) return Text('No stock SIPs yet. Try "start a weekly SIP in TVS Motor".', style: sub);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            for (final o in r.orders.take(10))
              Padding(
                padding: MOSpacing.paddingVertical6,
                child: Row(children: <Widget>[
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text(o.tradeSymbol, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                      Text('${o.frequency.name} · ${o.quantity > 0 ? '${o.quantity} shares' : '₹${_m(o.amount.toInt() / 100)}'} · ${o.status.name}${o.nextDate > 0 ? ' · next ${_d(o.nextDate)}' : ''}', style: sub),
                      Text('Invested ₹${_m(o.totalAmountInvested.toInt() / 100)} · ${o.totalQty} shares', style: sub),
                    ]),
                  ),
                  PopupMenuButton<String>(
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      if (o.status == StockSipOrderDetailV2_SipStatusV2.Paused) const PopupMenuItem<String>(value: 'resume', child: Text('Resume')) else const PopupMenuItem<String>(value: 'pause', child: Text('Pause')),
                      const PopupMenuItem<String>(value: 'cancel', child: Text('Cancel SIP')),
                    ],
                    onSelected: (a) => _act(a, o),
                  ),
                ]),
              ),
            if (_rowStatus.isNotEmpty) Text(_rowStatus, style: sub),
          ]);
        },
      );

  Future<void> _act(String a, StockSipOrderDetailV2 o) async {
    setState(() => _rowStatus = '${a[0].toUpperCase()}${a.substring(1)}…');
    try {
      final res = a == 'cancel'
          ? await _repo.cancelSip(sipID: o.sipId)
          : await _repo.stockSipOrderStatusUpdate(stockSipStatus: a == 'pause' ? StockSipStatus.pause : StockSipStatus.resume, sipID: '${o.sipId}');
      if (!mounted) return;
      setState(() {
        _rowStatus = res?.message ?? 'Done';
        _book = null;
      });
    } catch (e) {
      if (mounted) setState(() => _rowStatus = '$e');
    }
  }
}

class _StartSip extends StatefulWidget {
  const _StartSip({required this.repo, required this.onStarted, this.ref, this.stock, this.amount, this.qty, this.frequency});
  final MoStockSipRepository repo;
  final ScripRef? ref;
  final String? stock;
  final double? amount;
  final int? qty;
  final String? frequency;
  final VoidCallback onStarted;

  @override
  State<_StartSip> createState() => _StartSipState();
}

class _StartSipState extends State<_StartSip> {
  ScripRef? _ref;
  List<ScripRef> _suggestions = const <ScripRef>[];
  final TextEditingController _search = TextEditingController();
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  late final TextEditingController _qty = TextEditingController(text: widget.qty == null ? '' : '${widget.qty}');
  late bool _byAmount = widget.qty == null;
  late StockSipFrequency _freq = switch ((widget.frequency ?? 'monthly').toLowerCase()) { 'daily' => StockSipFrequency.Daily, 'weekly' => StockSipFrequency.Weekly, _ => StockSipFrequency.Monthly };
  late DateTime _start = DateTime.now().add(const Duration(days: 1));
  bool _busy = false;
  String _status = '';
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _ref = widget.ref;
    if (_ref == null && (widget.stock ?? '').isNotEmpty) _resolve(widget.stock!);
  }

  @override
  void dispose() {
    _search.dispose();
    _amount.dispose();
    _qty.dispose();
    super.dispose();
  }

  Future<void> _resolve(String q) async {
    final r = StockResolver.instance;
    if (r == null) return;
    setState(() => _resolving = true);
    final ref = await r.resolve(q);
    if (!mounted) return;
    setState(() {
      _ref = ref;
      _resolving = false;
    });
  }

  Future<void> _find(String q) async {
    final r = StockResolver.instance;
    if (r == null || q.trim().length < 2) return;
    final res = await r.suggest(q.trim(), limit: 6);
    if (mounted) setState(() => _suggestions = res);
  }

  ScripId get _scripId => ScripId(scripCode: int.tryParse(_ref!.scripCode) ?? 0, exchange: Exchange.valueOf(_ref!.exchangeCode ?? 0) ?? Exchange.NSE);

  Future<void> _submit() async {
    final ref = _ref;
    if (ref == null) return _fail('Pick a stock.');
    final amount = double.tryParse(_amount.text) ?? 0;
    final qty = int.tryParse(_qty.text) ?? 0;
    if (_byAmount ? amount < 1 : qty < 1) return _fail(_byAmount ? 'Enter an amount.' : 'Enter a quantity.');
    setState(() {
      _busy = true;
      _status = 'Validating…';
    });
    try {
      final create = ValidateCreateOrderRequest(
        scrip: _scripId,
        amount: _byAmount ? Int64((amount * 100).round()) : Int64(0),
        quantity: _byAmount ? 0 : qty,
        frequency: _freq,
        startDate: _start.millisecondsSinceEpoch ~/ 1000,
      );
      final v = await widget.repo.validateOrder(ValidateSipOrderRequest(action: SipAction.Create, createSip: create));
      if (!mounted) return;
      if (v != null && v.bankMandateAmount > 0) {
        return _fail('This SIP needs a bank mandate of ₹${_m(v.bankMandateAmount.toInt() / 100)}. The mandate step (Razorpay) is not hosted in the AI view yet. ${v.message}');
      }
      setState(() => _status = 'Creating SIP…');
      final res = await widget.repo.createOrder(StockSipOrderRequestV2(scrip: create.scrip, quantity: create.quantity, amount: create.amount, startDate: create.startDate, frequency: create.frequency));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = res?.message ?? 'SIP created.';
      });
      widget.onStarted();
    } catch (e) {
      _fail('$e');
    }
  }

  void _fail(String m) {
    if (mounted) setState(() {
      _busy = false;
      _status = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    if (_resolving) return const CardLoading(text: 'Looking up the stock…');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (_ref != null)
        Row(children: <Widget>[
          Expanded(child: Text('${_ref!.symbol} · ${_ref!.name}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal))),
          TextButton(onPressed: () => setState(() => _ref = null), child: const Text('Change')),
        ])
      else ...<Widget>[
        TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _search, onChanged: _find, decoration: const InputDecoration(labelText: 'Stock', isDense: true, border: OutlineInputBorder(), prefixIcon: Icon(Icons.search, size: 18))),
        Wrap(spacing: 6, children: <Widget>[for (final s in _suggestions) ActionChip(label: Text('${s.symbol} · ${s.exchange}'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _ref = s))]),
      ],
      MOSpacing.verticalSpace8,
      Row(children: <Widget>[
        ChoiceChip(label: const Text('By amount'), selected: _byAmount, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _byAmount = true)),
        MOSpacing.horizontalSpace6,
        ChoiceChip(label: const Text('By quantity'), selected: !_byAmount, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _byAmount = false)),
      ]),
      MOSpacing.verticalSpace6,
      if (_byAmount)
        TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount per instalment', prefixText: '₹ ', isDense: true, border: OutlineInputBorder()))
      else
        TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Shares per instalment', isDense: true, border: OutlineInputBorder())),
      MOSpacing.verticalSpace8,
      Row(children: <Widget>[
        Text('Frequency', style: sub),
        MOSpacing.horizontalSpace8,
        for (final f in <StockSipFrequency>[StockSipFrequency.Daily, StockSipFrequency.Weekly, StockSipFrequency.Monthly])
          Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: Text(f.name), selected: _freq == f, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _freq = f))),
      ]),
      Row(children: <Widget>[
        Text('Starts ${DateFormat('d MMM yyyy').format(_start)}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
        TextButton(
          onPressed: () async {
            final p = await showDatePicker(context: context, initialDate: _start, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 60)));
            if (p != null) setState(() => _start = p);
          },
          child: const Text('Change'),
        ),
      ]),
      if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: Text(_status, style: sub)),
      MOSpacing.verticalSpace6,
      MOButton(label: 'Start SIP', onPressed: _busy ? null : _submit, isLoading: _busy, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small, isFullWidth: true),
    ]);
  }
}

String _m(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
String _d(int n) => n <= 0 ? '' : DateFormat('d MMM').format(DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n));
