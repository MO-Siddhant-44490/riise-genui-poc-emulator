import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/fund_ref.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_mutual_funds/invest_in_sip/data/invest_in_sip_repository_impl.dart';
import 'package:mo_mutual_funds/invest_in_sip/domain/model/lumsum_scheme_master.dart';
import 'package:mo_mutual_funds/invest_in_sip/domain/model/rm_code_model.dart';
import 'package:mo_mutual_funds/invest_in_sip/domain/model/sip_scheme_master_model.dart';
import 'package:mo_mutual_funds/manage_sip/data/manage_sip_repository_impl.dart';
import 'package:mo_mutual_funds/mf_common/constant/mutual_fund_api_request_params.dart';
import 'package:mo_mutual_funds/mf_common/mf_transaction_navigator/mutual_fund_transaction_args.dart';
import 'package:mo_mutual_funds/mf_common/mf_transaction_navigator/mutual_fund_transaction_paths.dart';
import 'package:mo_mutual_funds/mutual_fund_payment/data/payment_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_payment/domain/model/bank_list_model.dart';
import 'package:mo_mutual_funds/mutual_fund_payment/domain/model/create_sip_request_model.dart';
import 'package:mo_mutual_funds/mutual_fund_payment/domain/model/mandate_list_entry_model.dart';
import 'package:mo_mutual_funds/mutual_fund_payment/domain/model/sip_model.dart';
import 'package:mo_mutual_funds/mutual_fund_switch/data/repository/switch_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_fund_switch/domain/model/client_holding_data_model.dart';
import 'package:mo_mutual_funds/mutual_fund_switch/domain/model/switch_fund_details_model.dart';
import 'package:mo_mutual_funds/mutual_funds_order_book/data/transactions_type_repository_impl.dart';
import 'package:mo_mutual_funds/mutual_funds_order_book/domain/model/order_book_response_model.dart';
import 'package:mo_mutual_funds/mutual_funds_order_book/domain/model/sip_transaction_model.dart';
import 'package:mo_mutual_funds/set_redeem_amount_and_duration_screen/models/folio_list.dart';
import 'package:mo_mutual_funds/set_redeem_amount_and_duration_screen/models/withdraw_sip_folio_model.dart';
import 'package:mo_mutual_funds/set_redeem_amount_and_duration_screen/models/withdraw_sip_model.dart';
import 'package:mo_mutual_funds/withdrawal_amount_screen/data/withdraw_repository_impl.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/preferences.dart';

/// Mutual fund transactions, through the same repositories and request
/// objects the classic MF screens use. Payment itself (Razorpay) and mandate
/// registration are the app's own gateway screens; the card hands off to them
/// only after the order exists.

/// Swallows a failed optional lookup so the others still load.
Future<void> _safe(Future<void> f) => f.catchError((Object e) { debugPrint('MF lookup failed: $e'); });

String _m(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
Widget _sub(BuildContext c, String t) => Text(t, style: MOTypography.bodyXsmallRegular.copyWith(color: c.surfaceTextNeutralStrong));

// -------------------------------------------------------------------- invest

/// Lumpsum or SIP in one scheme: scheme masters → RM code → bank → mandate →
/// folio → create order (`orderSip` / `orderLumpsum`) → payment screen.
class MfInvestCard extends StatefulWidget {
  const MfInvestCard({super.key, required this.ref, this.amount, this.mode, this.frequency, this.embedded = false});
  final FundRef ref;
  final double? amount;
  final String? mode; // sip | lumpsum
  final String? frequency; // monthly | quarterly
  final bool embedded;

  @override
  State<MfInvestCard> createState() => _MfInvestCardState();
}

class _Prep {
  _Prep({this.sip, this.lump, this.rm, this.banks = const <BankDetailsModel>[], this.mandates = const <MandateListEntryModel>[], this.folio = ''});
  final SipSchemeMasterData? sip;
  final LumpsumSchemeMasterData? lump;
  final RMCodeModel? rm;
  final List<BankDetailsModel> banks;
  final List<MandateListEntryModel> mandates;
  final String folio;
}

class _MfInvestCardState extends State<MfInvestCard> {
  late bool _sip = (widget.mode ?? 'sip').toLowerCase() != 'lumpsum';
  late bool _monthly = (widget.frequency ?? 'monthly').toLowerCase() != 'quarterly';
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  DateTime _start = DateTime.now().add(const Duration(days: 2));
  BankDetailsModel? _bank;
  MandateListEntryModel? _mandate;
  bool _upi = true;
  Future<_Prep>? _prep;
  bool _busy = false;
  String _status = '';
  OrderSipModel? _order;

  Future<_Prep> _load() async {
    debugPrint('GenUI invest: amount=${widget.amount} mode=${widget.mode} freq=${widget.frequency}');
    final inv = InvestInSipRepositoryImpl();
    final pay = PaymentRepositoryImpl();
    SipSchemeMasterData? sip;
    LumpsumSchemeMasterData? lump;
    RMCodeModel? rm;
    var banks = <BankDetailsModel>[];
    var mandates = <MandateListEntryModel>[];
    var folio = '';
    await Future.wait<void>(<Future<void>>[
      _safe(inv.getSipMaster(widget.ref.isin).then((v) => sip = v.data.firstOrNull)),
      _safe(inv.getLumpsumSchemeMaster(widget.ref.isin, MutualFundRequestParams.schemeMaster).then((v) => lump = v.data.firstOrNull)),
      _safe(inv.getRMCode(Preferences.getClientId()).then((v) => rm = v)),
      _safe(pay.getBankDetails().then((v) => banks = v.data)),
      _safe(pay.getMandateList(0).then((v) => mandates = v.data)),
      _safe(inv.fetchFolioData(isin: widget.ref.isin).then((v) => folio = v.data.entry.firstOrNull?.folioNo ?? '')),
    ]);
    _bank ??= banks.cast<BankDetailsModel?>().firstWhere((b) => (b?.defaulTFlag ?? '').toUpperCase().startsWith('Y'), orElse: () => banks.firstOrNull);
    _mandate ??= mandates.cast<MandateListEntryModel?>().firstWhere((m) => (m?.status ?? '').toUpperCase().contains('APPROV') || (m?.status ?? '').toUpperCase().contains('SUCCESS'), orElse: () => null);
    return _Prep(sip: sip, lump: lump, rm: rm, banks: banks, mandates: mandates, folio: folio);
  }

  int _ymd(DateTime d) => int.parse(DateFormat('yyyyMMdd').format(d));

  Future<void> _place(_Prep p) async {
    final amount = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    final bank = _bank;
    final master = _sip ? p.sip : null;
    final lump = _sip ? null : p.lump;
    if (bank == null) return _fail('No bank account linked for MF payments.');
    if (amount < 1) return _fail('Enter an amount.');
    if (_sip && master == null) return _fail('SIP is not available for this scheme.');
    if (!_sip && lump == null) return _fail('Lumpsum is not available for this scheme.');
    if (_sip && amount < (master!.sipminimuminstallmentamount)) return _fail('Minimum SIP is ₹${_m(master.sipminimuminstallmentamount)}.');
    if (!_sip && amount < (lump!.minpuramt)) return _fail('Minimum lumpsum is ₹${_m(lump.minpuramt)}.');
    setState(() {
      _busy = true;
      _status = 'Creating order…';
    });
    final rm = p.rm?.data;
    final mandateId = _sip ? (_mandate?.mandateId ?? '') : '';
    final isBse = _mandate?.isBSE ?? false;
    final payMode = _upi ? 4 : 3; // classic PaymentOption.indexVal: 3 = net banking, 4 = UPI
    try {
      OrderSipModel res;
      if (_sip) {
        final end = _monthly ? DateTime(_start.year, _start.month + 357, _start.day) : DateTime(_start.year, _start.month + 119 * 3, _start.day);
        res = await PaymentRepositoryImpl().orderSip(
          context: context,
          sipReqbj: CreateSipRequestModel(
            isin: widget.ref.isin,
            txnType: mandateId.isNotEmpty && isBse ? 13 : 2,
            amount: amount,
            isSip: true,
            freq: _monthly ? 0 : 1,
            isGeneratedToday: true,
            payMode: payMode,
            accountNumber: bank.aCNumber,
            ifscCode: bank.ifsCCode,
            schemeCode: master!.schemecode,
            token: master.token,
            startDate: _ymd(_start),
            endDate: _ymd(end),
            tenure: 999,
            mandateId: mandateId,
            rmCode: rm?.rmCode ?? '',
            arnId: rm?.arnCode ?? '',
            euinNumber: rm?.euinNo ?? '',
            mandateType: mandateId.isNotEmpty ? 1 : 0,
            subBrokerCode: rm?.subBroker ?? '',
            seconds: 6,
            createRazorPayUpiLink: false,
            folioNo: p.folio,
            segmentFlag: 0,
          ),
        );
      } else {
        res = await PaymentRepositoryImpl().orderLumpsum(
          context: context,
          lumpSumOrderReqObj: LumpSumOrderRequestModel(
            orderType: 3,
            txnType: 0,
            txnId: 0,
            isin: widget.ref.isin,
            schemeCode: lump!.schemecode,
            token: lump.token,
            amount: amount,
            paymentMode: payMode,
            rmCode: rm?.rmCode ?? '',
            arnId: rm?.arnCode ?? '',
            euinNumber: rm?.euinNo ?? '',
            isAmo: false,
            seconds: 6,
            subBrokerCode: rm?.subBroker ?? '',
            accountNumber: bank.aCNumber,
            ifscCode: bank.ifsCCode,
            folioNo: p.folio,
            segmentFlag: 0,
          ),
        );
      }
      if (!mounted) return;
      if (!res.status || (res.data.orderNumber ?? '').isEmpty) return _fail(res.data.message ?? res.message);
      setState(() {
        _busy = false;
        _order = res;
        _status = 'Order ${res.data.orderNumber} created. ${res.data.paymentDetail == null ? 'It will be collected through your mandate.' : 'Complete the payment to confirm it.'}';
      });
    } catch (e) {
      _fail('$e');
    }
  }

  void _pay(BuildContext context, _Prep p) {
    final o = _order;
    final bank = _bank;
    if (o == null || bank == null) return;
    final amount = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    // Same payment screen the classic flow opens after order creation (Razorpay / net banking).
    Navigator.pushNamed(
      context,
      MutualFundTransactionPaths.newPaymentPath,
      arguments: PaymentArguments(
        bankData: bank,
        subtext: '₹${_m(amount)}',
        amount: amount,
        isin: widget.ref.isin,
        paymode: _upi ? 4 : 3,
        orderData: o,
        txnType: _sip ? (_monthly ? 'MONTHLY SIP' : 'QUARTERLY SIP') : 'LUMPSUM',
        branch: bank.brancHName,
        mandateID: _mandate?.mandateId ?? '',
        dionOrderId: o.data.orderNumber ?? '',
        source: 'GenUI',
        isFromMFBasket: false,
        isStepUpSip: false,
        segmentFlag: 0,
      ),
    );
  }

  void _fail(String m) {
    if (mounted) setState(() {
      _busy = false;
      _status = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = FutureBuilder<_Prep>(
      future: _prep ??= _load(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Preparing the investment…');
        final p = snap.data;
        if (snap.hasError || p == null) return CardError(title: "Couldn't prepare.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _prep = null));
        final canSip = p.sip != null, canLump = p.lump != null;
        if (!canSip && _sip && canLump) _sip = false;
        final minAmt = _sip ? (p.sip?.sipminimuminstallmentamount ?? 0) : (p.lump?.minpuramt ?? 0);
        final sipDays = (p.sip?.sipdates ?? '').split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toSet();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            if (canSip) ChoiceChip(label: const Text('SIP'), selected: _sip, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _sip = true)),
            MOSpacing.horizontalSpace6,
            if (canLump) ChoiceChip(label: const Text('Lumpsum'), selected: !_sip, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _sip = false)),
            if (!canSip && !canLump) _sub(context, 'This scheme is not open for purchase.'),
          ]),
          MOSpacing.verticalSpace8,
          TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _amount, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: _sip ? 'Amount per instalment' : 'Amount', prefixText: '₹ ', helperText: minAmt > 0 ? 'Minimum ₹${_m(minAmt)}' : null, isDense: true, border: const OutlineInputBorder())),
          Wrap(spacing: 6, children: <Widget>[for (final a in const <int>[500, 1000, 5000, 10000]) ActionChip(label: Text('+₹${NumberFormat('#,##,###', 'en_IN').format(a)}'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _amount.text = '${(double.tryParse(_amount.text) ?? 0).toInt() + a}'))]),
          if (_sip) ...<Widget>[
            MOSpacing.verticalSpace8,
            Row(children: <Widget>[
              _sub(context, 'Frequency'),
              MOSpacing.horizontalSpace8,
              ChoiceChip(label: const Text('Monthly'), selected: _monthly, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _monthly = true)),
              MOSpacing.horizontalSpace6,
              ChoiceChip(label: const Text('Quarterly'), selected: !_monthly, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _monthly = false)),
            ]),
            Row(children: <Widget>[
              Text('First instalment ${DateFormat('d MMM yyyy').format(_start)}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _start, firstDate: DateTime.now().add(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 45)), selectableDayPredicate: (d) => sipDays.isEmpty || sipDays.contains(d.day));
                  if (d != null) setState(() => _start = d);
                },
                child: const Text('Change'),
              ),
            ]),
            if (p.mandates.isNotEmpty)
              _sub(context, _mandate != null ? 'Autopay mandate ${_mandate!.mandateId} (${_mandate!.status}) will collect future instalments.' : 'No approved mandate yet; the first instalment is paid now, autopay is set up in the app.')
            else
              _sub(context, 'No autopay mandate on this account. The first instalment is paid now; later instalments need a mandate, which the app registers through the bank.'),
          ],
          MOSpacing.verticalSpace8,
          _sub(context, 'Pay from'),
          Wrap(spacing: 6, runSpacing: 4, children: <Widget>[
            for (final b in p.banks) ChoiceChip(label: Text('${b.banKName} ··${b.aCNumber.length > 4 ? b.aCNumber.substring(b.aCNumber.length - 4) : b.aCNumber}'), selected: _bank == b, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _bank = b)),
            if (p.banks.isEmpty) _sub(context, 'No bank linked for MF.'),
          ]),
          Row(children: <Widget>[
            ChoiceChip(label: const Text('UPI'), selected: _upi, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _upi = true)),
            MOSpacing.horizontalSpace6,
            ChoiceChip(label: const Text('Net banking'), selected: !_upi, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _upi = false)),
          ]),
          if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: _sub(context, _status)),
          MOSpacing.verticalSpace6,
          if (_order == null)
            MOButton(label: _sip ? 'Start SIP' : 'Invest', onPressed: _busy || (!canSip && !canLump) ? null : () => _place(p), isLoading: _busy, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small, isFullWidth: true)
          else if (_order!.data.paymentDetail != null)
            MOButton(label: 'Pay ₹${_amount.text} now', onPressed: () => _pay(context, p), variant: MOButtonVariant.primary, color: MOButtonColor.positive, size: MOButtonSize.small, isFullWidth: true),
          MOSpacing.verticalSpace4,
          _sub(context, 'Order is created by the same MF transaction API as the classic Invest screen; the payment page is the bank gateway.'),
        ]);
      },
    );
    if (widget.embedded) return body;
    return CardFrame(title: 'Invest in ${widget.ref.shortName}', subtitle: widget.ref.category, tag: 'Mutual fund', child: body);
  }
}

// ---------------------------------------------------------- SIPs and orders

class MfSipsCard extends StatefulWidget {
  const MfSipsCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['sips', 'orders'];

  @override
  State<MfSipsCard> createState() => _MfSipsCardState();
}

class _MfSipsCardState extends State<MfSipsCard> {
  late String _view = MfSipsCard.views.contains(widget.view) ? widget.view! : 'sips';
  final TransactionTypeRepositoryImpl _repo = TransactionTypeRepositoryImpl();
  Future<MforderBookListModel>? _sipBook;
  Future<MforderBookListModel>? _orders;
  String _orderType = 'Buy';
  String _status = '';

  @override
  Widget build(BuildContext context) => CardFrame(
        title: _view == 'orders' ? 'My MF orders' : 'My mutual fund SIPs',
        views: MfSipsCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() {
          _sipBook = null;
          _orders = null;
        }),
        child: _view == 'orders' ? _ordersView(context) : _sipsView(context),
      );

  Widget _sipsView(BuildContext context) => FutureBuilder<MforderBookListModel>(
        // Same call the classic order book makes for the SIP tab.
        future: _sipBook ??= _repo.getCommonOrderBook('SIP', 'SUCCESSFUL', 50),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching your SIPs…');
          final rows = snap.data?.data ?? const <OrderBookResponseModel>[];
          // The order-book API answers "No Data Available" as an error when the list is empty.
          final empty = rows.isEmpty && (!snap.hasError || '${snap.error}'.toLowerCase().contains('no data'));
          if (empty) return _sub(context, 'No running mutual fund SIPs on this account. Start one with "start a SIP in <fund>".');
          if (snap.hasError) return CardError(title: "Couldn't load SIPs.", message: '${snap.error}', onRetry: () => setState(() => _sipBook = null));
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            for (final o in rows.take(12)) _SipRow(o: o, onChanged: (msg) => setState(() { _status = msg; _sipBook = null; })),
            if (_status.isNotEmpty) _sub(context, _status),
          ]);
        },
      );

  Widget _ordersView(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Wrap(spacing: 6, children: <Widget>[
          for (final t in const <MapEntry<String, String>>[MapEntry('Buy', 'Lumpsum'), MapEntry('SIP', 'SIP'), MapEntry('Sell', 'Redeem'), MapEntry('Switch', 'Switch'), MapEntry('SWP', 'SWP'), MapEntry('STP', 'STP')])
            ChoiceChip(label: Text(t.value), selected: _orderType == t.key, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() { _orderType = t.key; _orders = null; })),
        ]),
        MOSpacing.verticalSpace6,
        FutureBuilder<MforderBookListModel>(
          future: _orders ??= _repo.getCommonOrderBook(_orderType, '-1', 10),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching orders…');
            final rows = snap.data?.data ?? const <OrderBookResponseModel>[];
            if (snap.hasError || rows.isEmpty) return _sub(context, snap.hasError ? '${snap.error}' : 'No $_orderType orders.');
            return Column(children: <Widget>[for (final o in rows.take(10)) _OrderRow(o: o)]);
          },
        ),
      ]);
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.o});
  final OrderBookResponseModel o;

  @override
  Widget build(BuildContext context) => Padding(
        padding: MOSpacing.paddingVertical6,
        child: AdaptiveRow(leading: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(o.schemeName, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            _sub(context, '${o.transactionType}${o.transactionDate.isEmpty ? '' : ' · ${o.transactionDate}'}${o.paymentStatus.isEmpty ? '' : ' · ${o.paymentStatus}'}'),
          ]), trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
            Text('₹${o.amount}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            _sub(context, o.status),
          ])),
      );
}

class _SipRow extends StatefulWidget {
  const _SipRow({required this.o, required this.onChanged});
  final OrderBookResponseModel o;
  final ValueChanged<String> onChanged;

  @override
  State<_SipRow> createState() => _SipRowState();
}

class _SipRowState extends State<_SipRow> {
  String _mode = 'idle';
  String _msg = '';

  Future<void> _act(String a) async {
    final o = widget.o;
    setState(() {
      _mode = 'busy';
      _msg = '${a[0].toUpperCase()}${a.substring(1)}…';
    });
    try {
      final repo = ManageSipRepositoryImpl();
      String msg;
      if (a == 'pause') {
        final r = await repo.pauseSip(o.transactionID, '1', o.exchangeRefNo, o.txnType);
        msg = '${r.message}';
      } else {
        final r = await repo.cancelSipOrder(int.tryParse(o.transactionID) ?? 0, int.tryParse(o.txnType) ?? 0);
        msg = '${r.message}';
      }
      if (!mounted) return;
      setState(() {
        _mode = 'done';
        _msg = msg.isEmpty ? 'Done.' : msg;
      });
      widget.onChanged(msg);
    } catch (e) {
      if (mounted) setState(() {
        _mode = 'failed';
        _msg = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(o.schemeName, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
            _sub(context, '₹${o.amount} · ${o.status}${o.sipRegDate.isEmpty ? '' : ' · since ${o.sipRegDate}'}${o.installmentsPaid.isEmpty ? '' : ' · ${o.installmentsPaid}/${o.totalInstallments} paid'}'),
          ])),
          if (_mode == 'idle') PopupMenuButton<String>(itemBuilder: (_) => const <PopupMenuEntry<String>>[PopupMenuItem<String>(value: 'pause', child: Text('Pause 1 instalment')), PopupMenuItem<String>(value: 'cancel', child: Text('Cancel SIP'))], onSelected: (a) => setState(() => _mode = 'confirm-$a')),
        ]),
        if (_mode.startsWith('confirm-'))
          Row(children: <Widget>[
            Expanded(child: _sub(context, _mode == 'confirm-cancel' ? 'Cancel this SIP? Existing units stay invested.' : 'Pause the next instalment of this SIP?')),
            TextButton(onPressed: () => setState(() => _mode = 'idle'), child: const Text('Keep')),
            MOButton(label: _mode == 'confirm-cancel' ? 'Yes, cancel' : 'Yes, pause', onPressed: () => _act(_mode.substring(8)), variant: MOButtonVariant.primary, color: MOButtonColor.negative, size: MOButtonSize.small),
          ]),
        if (_mode == 'busy' || _mode == 'done' || _mode == 'failed')
          Row(children: <Widget>[
            if (_mode == 'busy') const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            if (_mode != 'busy') Icon(_mode == 'done' ? Icons.check_circle : Icons.error_outline, size: 14, color: _mode == 'done' ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
            MOSpacing.horizontalSpace6,
            Expanded(child: _sub(context, _msg)),
          ]),
      ]),
    );
  }
}

// -------------------------------------------------------- redeem / switch

/// Redeem or switch units of a fund the user holds.
class MfActionCard extends StatefulWidget {
  const MfActionCard({super.key, required this.ref, this.action, this.amount, this.toFund});
  final FundRef ref;
  final String? action; // redeem | switch
  final double? amount;
  final String? toFund;

  static const List<String> views = <String>['redeem', 'switch'];

  @override
  State<MfActionCard> createState() => _MfActionCardState();
}

class _HoldPrep {
  _HoldPrep({this.holding, this.rm, this.bank, this.targets = const <SwitchFundDetailsModel>[]});
  final ClientHoldingDataModel? holding;
  final RMCodeModel? rm;
  final BankDetailsModel? bank;
  final List<SwitchFundDetailsModel> targets;
}

class _MfActionCardState extends State<MfActionCard> {
  late String _view = MfActionCard.views.contains(widget.action) ? widget.action! : 'redeem';
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  bool _all = false;
  SwitchFundDetailsModel? _target;
  Future<_HoldPrep>? _prep;
  bool _busy = false;
  String _status = '';

  Future<_HoldPrep> _load() async {
    ClientHoldingDataModel? holding;
    RMCodeModel? rm;
    BankDetailsModel? bank;
    var targets = <SwitchFundDetailsModel>[];
    // The user's holding may be under a different plan / option than the scheme the
    // search resolved (e.g. Reg-G vs Regular-Growth-IDCW). Try the resolved ISIN, then
    // match the name against the funds the user actually holds.
    Future<void> loadHolding() async {
      try {
        holding = (await SwitchRepositoryImpl().getClientHoldingData(widget.ref.isin)).data.firstOrNull;
      } catch (_) {}
      if (holding != null) return;
      try {
        final all = await SwitchRepositoryImpl().getAllClientHoldings();
        String squash(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final want = widget.ref.shortName.toLowerCase().split(RegExp(r'[\s-]+')).where((w) => w.length > 2 && !const <String>{'fund', 'reg', 'regular', 'growth', 'plan', 'direct', 'option'}.contains(w)).map(squash).toList();
        int score(String? name) => want.where(squash(name ?? '').contains).length;
        final rows = all.data.where((h) => (h.isin ?? '').isNotEmpty).toList()..sort((a, b) => score(b.schemeName).compareTo(score(a.schemeName)));
        final best = rows.firstOrNull;
        if (best != null && score(best.schemeName) >= (want.length / 2).ceil()) {
          holding = (await SwitchRepositoryImpl().getClientHoldingData(best.isin!)).data.firstOrNull;
        }
      } catch (_) {}
    }
    await Future.wait<void>(<Future<void>>[
      loadHolding(),
      _safe(InvestInSipRepositoryImpl().getRMCode(Preferences.getClientId()).then((v) => rm = v)),
      _safe(PaymentRepositoryImpl().getBankDetails().then((v) => bank = v.data.cast<BankDetailsModel?>().firstWhere((b) => (b?.defaulTFlag ?? '').toUpperCase().startsWith('Y'), orElse: () => v.data.firstOrNull))),
    ]);
    if (_view == 'switch') {
      try {
        targets = await SwitchRepositoryImpl().getSwitchFundDetails(widget.ref.isin, '');
        if (widget.toFund != null) {
          final want = widget.toFund!.toLowerCase();
          _target ??= targets.cast<SwitchFundDetailsModel?>().firstWhere((t) => t!.schemeName.toLowerCase().contains(want), orElse: () => null);
        }
      } catch (_) {}
    }
    return _HoldPrep(holding: holding, rm: rm, bank: bank, targets: targets);
  }

  int _segment(String? mode) => switch ((mode ?? '').toLowerCase()) { 'demat' => 2, 'physical' => 1, _ => 0 };

  Future<void> _submit(_HoldPrep p) async {
    final h = p.holding;
    if (h == null) return _fail('You do not hold this fund.');
    final amount = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    final double units = _all ? h.availableUnits : (h.navValue > 0 ? amount / h.navValue : 0.0);
    if (!_all && amount < 1) return _fail('Enter an amount or choose all units.');
    if (!_all && amount > h.currentValuation) return _fail('You hold about ₹${_m(h.currentValuation)} in this fund.');
    if (_view == 'switch' && _target == null) return _fail('Pick the fund to switch into.');
    setState(() {
      _busy = true;
      _status = _view == 'switch' ? 'Placing switch…' : 'Placing redemption…';
    });
    final rm = p.rm?.data;
    try {
      String? orderNo, message;
      final folio = FolioList(folioNo: <FolioNoItem>[FolioNoItem(folioNo: h.folioNo ?? '', units: units)]);
      if (_view == 'redeem') {
        final r = await WithdrawRepositoryImpl().withdrawSip(WithdrawSipFolioModel(
          orderType: 0,
          txnId: 0,
          folioNo: folio,
          isinNo: widget.ref.isin,
          schemeCode: h.schemeCode,
          token: h.token,
          amount: _all ? h.currentValuation : amount,
          units: units,
          minRedeemFlag: true,
          rmCode: rm?.rmCode ?? '',
          arnId: rm?.arnCode ?? '',
          euinNumber: rm?.euinNo ?? '',
          offlineRedeem: true,
          txnType: 3,
          segmentFlag: _segment(h.mode),
          subBrokerCode: rm?.subBroker ?? '',
          vcAccountNo: p.bank?.aCNumber ?? '',
          vcNeftCode: p.bank?.ifsCCode ?? '',
          isAmountSelected: !_all,
          isRedeemAll: _all,
          bseUccId: '',
        ));
        orderNo = r.data.firstOrNull?.orderNumber;
        message = r.data.firstOrNull?.message ?? r.message;
      } else {
        final t = _target!;
        final r = await SwitchRepositoryImpl().performSwitch(WithdrawSipModel(
          orderType: 0,
          txnId: 0,
          folioNo: h.folioNo ?? '',
          isinNo: widget.ref.isin,
          schemeCode: h.schemeCode,
          token: h.token,
          amount: _all ? h.currentValuation : amount,
          units: units,
          minRedeemFlag: true,
          rmCode: rm?.rmCode ?? '',
          arnId: rm?.arnCode ?? '',
          euinNumber: rm?.euinNo ?? '',
          offlineRedeem: true,
          txnType: 3,
          subBrokerCode: rm?.subBroker ?? '',
          vcAccountNo: p.bank?.aCNumber ?? '',
          vcNeftCode: p.bank?.ifsCCode ?? '',
          switchToIsin: t.isin,
          switchToName: t.schemeName,
          switchToSchemeCode: t.schemeCode,
          isRedeemAll: _all,
          segmentFlag: _segment(h.mode),
          bseUccId: '',
        ));
        orderNo = r.data.orderNumber;
        message = r.data.message ?? r.message;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = (orderNo ?? '').isNotEmpty ? 'Order $orderNo placed. ${message ?? ''}' : (message ?? 'Not placed.');
      });
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
  Widget build(BuildContext context) => CardFrame(
        title: '${_view == 'switch' ? 'Switch' : 'Redeem'} ${widget.ref.shortName}',
        tag: 'Mutual fund',
        views: MfActionCard.views,
        view: _view,
        onViewChanged: (v) => setState(() {
          _view = v;
          _prep = null;
        }),
        child: FutureBuilder<_HoldPrep>(
          future: _prep ??= _load(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Checking your holding…');
            final p = snap.data;
            final h = p?.holding;
            if (snap.hasError || p == null) return CardError(title: "Couldn't load.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _prep = null));
            if (h == null) return _sub(context, 'The MF transaction service has no holding record for ${widget.ref.shortName} on this account (the portfolio view may still list it from the wealth service). Nothing to redeem here.');
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('You hold ${h.availableUnits.toStringAsFixed(3)} units ≈ ₹${_m(h.currentValuation)} (NAV ₹${h.navValue.toStringAsFixed(2)})${(h.folioNo ?? '').isEmpty ? '' : ' · folio ${h.folioNo}'}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
              MOSpacing.verticalSpace8,
              Row(children: <Widget>[
                Expanded(child: TextField(style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal), controller: _amount, enabled: !_all, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: _view == 'switch' ? 'Amount to switch' : 'Amount to redeem', prefixText: '₹ ', isDense: true, border: const OutlineInputBorder()))),
                MOSpacing.horizontalSpace8,
                ChoiceChip(label: const Text('All units'), selected: _all, visualDensity: VisualDensity.compact, onSelected: (v) => setState(() => _all = v)),
              ]),
              if (h.redemptionAmountMinimum > 0) _sub(context, 'Minimum ₹${_m(h.redemptionAmountMinimum)}'),
              if (_view == 'switch') ...<Widget>[
                MOSpacing.verticalSpace8,
                _sub(context, 'Switch into (same fund house)'),
                if (p.targets.isEmpty) _sub(context, 'No switch targets returned for this scheme.'),
                Wrap(spacing: 6, runSpacing: 4, children: <Widget>[
                  for (final t in p.targets.take(10)) ChoiceChip(label: Text(t.schemeName, maxLines: 1, overflow: TextOverflow.ellipsis), selected: _target == t, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _target = t)),
                ]),
              ],
              if (_status.isNotEmpty) Padding(padding: MOSpacing.paddingVertical4, child: _sub(context, _status)),
              MOSpacing.verticalSpace6,
              MOButton(label: _view == 'switch' ? 'Switch' : 'Redeem', onPressed: _busy ? null : () => _submit(p), isLoading: _busy, variant: MOButtonVariant.primary, color: _view == 'switch' ? MOButtonColor.primary : MOButtonColor.negative, size: MOButtonSize.small, isFullWidth: true),
              _sub(context, _view == 'switch' ? 'Exit load and tax apply as per the scheme.' : 'Proceeds go to your registered bank in 2 to 3 working days. Exit load and tax apply as per the scheme.'),
            ]);
          },
        ),
      );
}

// Helper used by the screen to resolve a fund named inside a follow-up.
Future<FundRef?> resolveFund(String name) => FundResolver.instance.resolve(name);
