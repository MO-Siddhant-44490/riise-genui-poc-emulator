import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/preferences.dart';
import 'package:trader_add_fund/domain/funds_repository.dart';
import 'package:trader_add_fund/domain/model/fund_transfer_res.dart';
import 'package:trader_add_fund/domain/model/getbankdetail_datamodel.dart';
import 'package:trader_add_fund/domain/withdrawalfunds_repository.dart';
import 'package:trader_add_fund/helper/add_fund_navigator.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_proto_gen/FundTransfer/FundTransfer.pb.dart';
import 'package:trader_proto_gen/Reports/MarginReport.pb.dart';

/// Funds: available margin and ledger, the margin breakdown, add money and
/// withdraw. Reads and writes go through the same `FundsRepository` /
/// `WithdrawalFundsRepository` the classic Funds screen uses. Only the
/// payment gateway page itself (net banking / UPI collect) opens outside the
/// chat, in the app's generic web view, because the bank hosts it.
class FundsCard extends StatefulWidget {
  const FundsCard({super.key, this.view, this.amount});

  final String? view;
  final double? amount;

  static const List<String> views = <String>['summary', 'breakdown', 'add', 'withdraw'];

  static String? viewForIntent(String? intent) {
    switch ((intent ?? '').toLowerCase()) {
      case 'add':
        return 'add';
      case 'withdraw':
        return 'withdraw';
      default:
        return null;
    }
  }

  @override
  State<FundsCard> createState() => _FundsCardState();
}

class _Summary {
  _Summary({this.margins, this.payout});
  final AvailableMargins? margins;
  final FundPayoutInfoV4? payout;
}

class _FundsCardState extends State<FundsCard> {
  late String _view = FundsCard.views.contains(widget.view) ? widget.view! : 'summary';
  Future<_Summary>? _summary;
  Future<MarginReportV4>? _report;

  FundsRepository get _funds => getIt<FundsRepository>();
  WithdrawalFundsRepository get _withdraw => getIt<WithdrawalFundsRepository>();

  Future<_Summary> _loadSummary() async {
    final results = await Future.wait(<Future<dynamic>>[
      _funds.fetchAvailableMarginData().catchError((_) => null),
      _withdraw.fetchMaxFunds().then((r) {
        if (r.hasError()) return null;
        final info = FundPayoutInfoV4();
        r.data.unpackInto(info);
        return info;
      }).catchError((_) => null),
    ]);
    return _Summary(margins: results[0] as AvailableMargins?, payout: results[1] as FundPayoutInfoV4?);
  }

  void _refresh() => setState(() {
        _summary = null;
        _report = null;
      });

  @override
  Widget build(BuildContext context) {
    return CardFrame(
      title: _view == 'add'
          ? 'Add funds'
          : _view == 'withdraw'
              ? 'Withdraw funds'
              : 'My funds',
      views: FundsCard.views,
      view: _view,
      onViewChanged: (v) => setState(() => _view = v),
      onRefresh: _refresh,
      child: switch (_view) {
        'breakdown' => _Breakdown(future: _report ??= _funds.getMarginReport(), onRetry: _refresh),
        'add' => _AddFunds(funds: _funds, amount: widget.amount, onDone: _refresh),
        'withdraw' => _Withdraw(repo: _withdraw, amount: widget.amount, onDone: _refresh),
        _ => _SummaryView(
            future: _summary ??= _loadSummary(),
            onRetry: _refresh,
            onAdd: () => setState(() => _view = 'add'),
            onWithdraw: () => setState(() => _view = 'withdraw'),
          ),
      },
    );
  }
}

class _SummaryView extends StatelessWidget {
  const _SummaryView({required this.future, required this.onRetry, required this.onAdd, required this.onWithdraw});
  final Future<_Summary> future;
  final VoidCallback onRetry, onAdd, onWithdraw;

  @override
  Widget build(BuildContext context) => FutureBuilder<_Summary>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching balances…');
          final s = snap.data;
          if (snap.hasError || s == null || (s.margins == null && s.payout == null)) {
            return CardError(title: "Couldn't load funds.", message: '${snap.error ?? 'No data'}', onRetry: onRetry);
          }
          final m = s.margins;
          final p = s.payout;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (m != null) ...<Widget>[
              Text('Available to trade', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
              Text(rupees(m.overall.toInt() / 100), style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
              MOSpacing.verticalSpace8,
              Row(children: <Widget>[
                Expanded(child: _Tile(label: 'Cash', value: rupees(m.cash.toInt() / 100))),
                MOSpacing.horizontalSpace8,
                Expanded(child: _Tile(label: 'F&O', value: rupees(m.fno.toInt() / 100))),
              ]),
            ],
            if (p != null) ...<Widget>[
              MOSpacing.verticalSpace8,
              Row(children: <Widget>[
                Expanded(child: _Tile(label: 'Ledger balance', value: rupees(p.ledgerBalance.toInt() / 100))),
                MOSpacing.horizontalSpace8,
                Expanded(child: _Tile(label: 'Withdrawable', value: rupees(p.eligibleAmount.toInt() / 100))),
              ]),
              if (p.marginShortfall > 0)
                Padding(
                  padding: MOSpacing.paddingVertical6,
                  child: Row(children: <Widget>[
                    Icon(Icons.warning_amber_rounded, size: 14, color: context.feedbackIconWarningNormal),
                    MOSpacing.horizontalSpace6,
                    Expanded(child: Text('Margin shortfall ${rupees(p.marginShortfall.toInt() / 100)}', style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
                  ]),
                ),
            ],
            MOSpacing.verticalSpace8,
            Row(children: <Widget>[
              Expanded(child: MOButton(label: 'Add funds', onPressed: onAdd, variant: MOButtonVariant.primary, color: MOButtonColor.primary, size: MOButtonSize.small)),
              MOSpacing.horizontalSpace8,
              Expanded(child: MOButton(label: 'Withdraw', onPressed: onWithdraw, variant: MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small)),
            ]),
          ]);
        },
      );
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.future, required this.onRetry});
  final Future<MarginReportV4> future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => FutureBuilder<MarginReportV4>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching margin report…');
          final r = snap.data;
          if (snap.hasError || r == null) return CardError(title: "Couldn't load the breakdown.", message: '${snap.error ?? 'No data'}', onRetry: onRetry);
          final label = MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal);
          final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
          final value = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            _line('Opening balance', rupees(r.openingBalance.toInt() / 100), label, value),
            _line('Withdrawable', rupees(r.withdrawableAmount.toInt() / 100), label, value),
            for (final e in r.entry) ...<Widget>[
              _line(e.label, rupees(e.value.toInt() / 100), label, value),
              for (final s in e.second) Padding(padding: const EdgeInsets.only(left: 12), child: _line(s.label, rupees(s.value.toInt() / 100), sub, sub)),
            ],
          ]);
        },
      );

  Widget _line(String k, String v, TextStyle ks, TextStyle vs) => Padding(
        padding: MOSpacing.paddingVertical4,
        child: Row(children: <Widget>[Expanded(child: Text(k, style: ks)), Text(v, style: vs)]),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
        padding: MOSpacing.paddingAll8,
        decoration: BoxDecoration(color: context.surfaceBackgroundNeutralSubtle, borderRadius: MOSpacing.borderRadius8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          Text(value, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
        ]),
      );
}

enum _Step { form, busy, done, failed }

/// Add money: amount + bank + method, then the gateway page in the app's web view.
class _AddFunds extends StatefulWidget {
  const _AddFunds({required this.funds, required this.onDone, this.amount});
  final FundsRepository funds;
  final double? amount;
  final VoidCallback onDone;

  @override
  State<_AddFunds> createState() => _AddFundsState();
}

class _AddFundsState extends State<_AddFunds> {
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  final TextEditingController _vpa = TextEditingController();
  Future<GetBankDetailModel?>? _banks;
  Bank? _bank;
  bool _upi = true;
  _Step _step = _Step.form;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _banks = _loadBanks();
  }

  @override
  void dispose() {
    _amount.dispose();
    _vpa.dispose();
    super.dispose();
  }

  Future<GetBankDetailModel?> _loadBanks() async {
    final res = await widget.funds.getUserBankDetails();
    if (res == null) return null;
    final Map<String, dynamic> map = jsonDecode(res.data) as Map<String, dynamic>;
    map['lasttransaction'] ??= <dynamic>[];
    final model = GetBankDetailModel.fromJson(map);
    // The createtransaction call needs this header, exactly as the classic screen stores it.
    Preferences.saveFundAuthHeader(model.authHeader.toString());
    final banks = model.banks ?? <Bank>[];
    _bank ??= banks.cast<Bank?>().firstWhere((b) => b?.defaultBank == true, orElse: () => banks.isEmpty ? null : banks.first);
    return model;
  }

  Future<void> _pay() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final bank = _bank;
    if (bank == null) return _fail('Pick a bank account.');
    if (amount < 1) return _fail('Enter an amount.');
    if (_upi && _vpa.text.trim().isEmpty) return _fail('Enter your UPI ID.');
    setState(() {
      _step = _Step.busy;
      _status = 'Creating transaction…';
    });
    try {
      final FundTransferRes res = await widget.funds.initiateTransaction(bank, amount.toStringAsFixed(0), '', _upi ? _vpa.text.trim() : '');
      if (!mounted) return;
      if (!res.success) return _fail(res.errorMsg);
      final type = res.data.redirectType.toUpperCase();
      if (type == 'WEB' && !res.isPost) {
        final q = res.data.params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}').join('&');
        AddFundNavigator.navigateToWebView(context, q.isEmpty ? res.data.url : '${res.data.url}${res.data.url.contains('?') ? '&' : '?'}$q', 'Add Funds');
        setState(() {
          _step = _Step.done;
          _status = 'Bank page opened. Complete the payment there, then refresh this card.';
        });
      } else if (type == 'INTENTSTRING') {
        setState(() {
          _step = _Step.done;
          _status = 'UPI request sent for ${rupees(amount)}. Approve it in your UPI app, then refresh this card.';
        });
      } else {
        _fail('This bank uses a ${type.toLowerCase()} gateway which the AI view does not host yet. Try UPI, or another bank.');
      }
      widget.onDone();
    } catch (e) {
      if (mounted) _fail('$e');
    }
  }

  void _fail(String msg) => setState(() {
        _step = _Step.failed;
        _status = msg;
      });

  @override
  Widget build(BuildContext context) {
    final label = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return FutureBuilder<GetBankDetailModel?>(
      future: _banks,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching your bank accounts…');
        final banks = snap.data?.banks ?? <Bank>[];
        if (snap.hasError || banks.isEmpty) {
          return CardError(title: "Couldn't load bank accounts.", message: '${snap.error ?? 'No linked bank found'}', onRetry: () => setState(() => _banks = _loadBanks()));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          _AmountField(controller: _amount, onChanged: () => setState(() {})),
          Wrap(spacing: 6, children: <Widget>[
            for (final a in const <int>[1000, 5000, 10000, 25000])
              ActionChip(label: Text('+₹${NumberFormat('#,##,###', 'en_IN').format(a)}'), onPressed: () => setState(() => _amount.text = '${(double.tryParse(_amount.text) ?? 0).toInt() + a}')),
          ]),
          MOSpacing.verticalSpace8,
          Text('From bank', style: label),
          Wrap(spacing: 6, children: <Widget>[
            for (final b in banks)
              ChoiceChip(label: Text('${b.bankDisplayName ?? b.bankName ?? ''} ··${(b.accountNumber ?? '').length > 4 ? (b.accountNumber ?? '').substring((b.accountNumber ?? '').length - 4) : ''}'), selected: _bank == b, onSelected: (_) => setState(() => _bank = b)),
          ]),
          MOSpacing.verticalSpace8,
          Row(children: <Widget>[
            ChoiceChip(label: const Text('UPI'), selected: _upi, onSelected: (_bank?.upiEnabled ?? true) ? (_) => setState(() => _upi = true) : null),
            MOSpacing.horizontalSpace6,
            ChoiceChip(label: const Text('Net banking'), selected: !_upi, onSelected: (_bank?.nbEnabled ?? true) ? (_) => setState(() => _upi = false) : null),
          ]),
          if (_upi) ...<Widget>[
            MOSpacing.verticalSpace6,
            TextField(
              controller: _vpa,
              keyboardType: TextInputType.emailAddress,
              style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal),
              decoration: const InputDecoration(labelText: 'UPI ID', hintText: 'name@bank', isDense: true, border: OutlineInputBorder()),
            ),
          ],
          MOSpacing.verticalSpace8,
          _StatusLine(step: _step, status: _status, onRetry: () => setState(() => _step = _Step.form)),
          if (_step == _Step.form || _step == _Step.failed)
            MOButton(
              label: 'Add ${rupees(double.tryParse(_amount.text) ?? 0)}',
              onPressed: _pay,
              variant: MOButtonVariant.primary,
              color: MOButtonColor.primary,
              size: MOButtonSize.small,
            ),
        ]);
      },
    );
  }
}

/// Withdraw to a linked bank through the same payout request the classic screen sends.
class _Withdraw extends StatefulWidget {
  const _Withdraw({required this.repo, required this.onDone, this.amount});
  final WithdrawalFundsRepository repo;
  final double? amount;
  final VoidCallback onDone;

  @override
  State<_Withdraw> createState() => _WithdrawState();
}

class _WithdrawState extends State<_Withdraw> {
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : widget.amount!.toStringAsFixed(0));
  Future<FundPayoutInfoV4>? _info;
  BankDetailV4? _bank;
  _Step _step = _Step.form;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _info = _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<FundPayoutInfoV4> _load() async {
    final r = await widget.repo.fetchMaxFunds();
    if (r.hasError()) throw r.error.errorMessage;
    final info = FundPayoutInfoV4();
    r.data.unpackInto(info);
    _bank ??= info.bankDetails.cast<BankDetailV4?>().firstWhere((b) => b?.isDefault == true, orElse: () => info.bankDetails.isEmpty ? null : info.bankDetails.first);
    return info;
  }

  Future<void> _submit(FundPayoutInfoV4 info) async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final max = info.eligibleAmount.toInt() / 100;
    final bank = _bank;
    if (bank == null) return _fail('Pick a bank account.');
    if (amount < 1) return _fail('Enter an amount.');
    if (amount > max) return _fail('You can withdraw up to ${rupees(max)}.');
    setState(() {
      _step = _Step.busy;
      _status = 'Requesting payout…';
    });
    try {
      final res = await widget.repo.requestPayout(bank.bankAccount, bank.ifscCode, (amount * 100).round());
      if (!mounted) return;
      final ok = res.status.name.toUpperCase().contains('SUCCESS') || res.transactionId.isNotEmpty;
      setState(() {
        _step = ok ? _Step.done : _Step.failed;
        _status = res.message.isNotEmpty ? res.message : (ok ? 'Withdrawal of ${rupees(amount)} requested.' : 'Request not accepted.');
      });
      if (ok) widget.onDone();
    } catch (e) {
      if (mounted) _fail('$e');
    }
  }

  void _fail(String msg) => setState(() {
        _step = _Step.failed;
        _status = msg;
      });

  @override
  Widget build(BuildContext context) {
    final label = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return FutureBuilder<FundPayoutInfoV4>(
      future: _info,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Checking withdrawable amount…');
        final info = snap.data;
        if (snap.hasError || info == null) return CardError(title: "Couldn't load withdrawal details.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() => _info = _load()));
        final max = info.eligibleAmount.toInt() / 100;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: Text('Withdrawable: ${rupees(max)}', style: label)),
            TextButton(onPressed: () => setState(() => _amount.text = max.floor().toString()), child: const Text('Withdraw all')),
          ]),
          _AmountField(controller: _amount, onChanged: () => setState(() {})),
          MOSpacing.verticalSpace8,
          Text('To bank', style: label),
          Wrap(spacing: 6, children: <Widget>[
            for (final b in info.bankDetails)
              ChoiceChip(label: Text('${b.bankName} ··${b.bankAccount.length > 4 ? b.bankAccount.substring(b.bankAccount.length - 4) : b.bankAccount}'), selected: _bank == b, onSelected: (_) => setState(() => _bank = b)),
          ]),
          MOSpacing.verticalSpace8,
          _StatusLine(step: _step, status: _status, onRetry: () => setState(() => _step = _Step.form)),
          if (_step == _Step.form || _step == _Step.failed)
            MOButton(
              label: 'Withdraw ${rupees(double.tryParse(_amount.text) ?? 0)}',
              onPressed: () => _submit(info),
              variant: MOButtonVariant.primary,
              color: MOButtonColor.primary,
              size: MOButtonSize.small,
            ),
        ]);
      },
    );
  }
}

class _AmountField extends StatelessWidget {
  const _AmountField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        onChanged: (_) => onChanged(),
        style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal),
        decoration: const InputDecoration(prefixText: '₹ ', labelText: 'Amount', isDense: true, border: OutlineInputBorder()),
      );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.step, required this.status, required this.onRetry});
  final _Step step;
  final String status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (step == _Step.form) return const SizedBox.shrink();
    return Padding(
      padding: MOSpacing.paddingVertical6,
      child: Row(children: <Widget>[
        if (step == _Step.busy) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        if (step != _Step.busy)
          Icon(step == _Step.done ? Icons.check_circle : Icons.error_outline, size: 14, color: step == _Step.done ? context.surfaceTextPositiveNormal : context.surfaceTextNegativeNormal),
        MOSpacing.horizontalSpace6,
        Expanded(child: Text(status, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralNormal))),
      ]),
    );
  }
}

String rupees(num v) => '₹${NumberFormat('#,##,##0.00', 'en_IN').format(v)}';
