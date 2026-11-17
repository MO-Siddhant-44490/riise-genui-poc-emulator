import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mo_mtf_hub/domain/mo_mtf_repository.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_proto_gen/Reports/MTF.pb.dart';

/// What the user has borrowed on MTF and the interest on it, from the MTF hub repository.
class MtfBorrowCard extends StatefulWidget {
  const MtfBorrowCard({super.key, this.view});
  final String? view;
  static const List<String> views = <String>['summary', 'holdings', 'interest'];

  @override
  State<MtfBorrowCard> createState() => _MtfBorrowCardState();
}

class _Data {
  _Data(this.book, this.interest);
  final DashboardScripsResponse? book;
  final InterestOverviewResponse? interest;
}

class _MtfBorrowCardState extends State<MtfBorrowCard> {
  late String _view = MtfBorrowCard.views.contains(widget.view) ? widget.view! : 'summary';
  late Future<_Data> _future = _load();

  Future<_Data> _load() async {
    final repo = getIt<MoMtfRepository>();
    DashboardScripsResponse? book;
    InterestOverviewResponse? interest;
    Future<void> safe(Future<void> f) => f.catchError((Object _) {});
    await Future.wait<void>(<Future<void>>[
      safe(repo.moMtfGetDashboardScrips().then((v) { book = v; })),
      safe(repo.moMtfGetInterestTransactions().then((v) { interest = v; })),
    ]);
    return _Data(book, interest);
  }

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'My MTF book',
        subtitle: 'Margin trading facility',
        views: MtfBorrowCard.views,
        view: _view,
        onViewChanged: (v) => setState(() => _view = v),
        onRefresh: () => setState(() { _future = _load(); }),
        child: FutureBuilder<_Data>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final d = snap.data;
            if (snap.hasError || d == null || (d.book == null && d.interest == null)) {
              return CardError(title: "Couldn't load your MTF book.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = _load(); }));
            }
            final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
            final val = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
            Widget kv(String k, num v, {bool money = true}) => Padding(padding: MOSpacing.paddingVertical2, child: Row(children: <Widget>[Expanded(child: Text(k, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))), Text(money ? '₹${_m(v)}' : '$v', style: val)]));
            final b = d.book;
            final i = d.interest;
            if (_view == 'holdings') {
              final rows = b?.scrips ?? const <scripDetail>[];
              if (rows.isEmpty) return Text('No MTF holdings.', style: sub);
              return Column(children: <Widget>[
                for (final s in rows)
                  Padding(
                    padding: MOSpacing.paddingVertical6,
                    child: Row(children: <Widget>[
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Text(s.tradeSymbol, style: val), Text('${s.quantity} @ ₹${_m(s.avgPrice)}', style: sub)])),
                      Text('₹${_m(s.investedAmount)}', style: val),
                    ]),
                  ),
              ]);
            }
            if (_view == 'interest') {
              if (i == null) return Text('Interest details unavailable.', style: sub);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                kv('Provisional interest', i.provisionalInterest),
                kv('Posted to ledger', i.interestPostedLedger),
                kv('Total incurred', i.totalInterestIncurred),
                MOSpacing.verticalSpace6,
                for (final t in i.transactions.take(8))
                  Padding(
                    padding: MOSpacing.paddingVertical4,
                    child: Row(children: <Widget>[
                      Expanded(child: Text('${_date(t.dateTime.toInt())} · ${t.interestRatePercentage}% on ₹${_m(t.totalOutstandingAmount)}', style: sub)),
                      Text('₹${_m(t.totalInterest)}', style: val),
                    ]),
                  ),
              ]);
            }
            if (b == null) return Text('MTF summary unavailable.', style: sub);
            final s = b.dashboard;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Borrowed from MOSL', style: sub),
              Text('₹${_m(s.moFunded)}', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
              MOSpacing.verticalSpace6,
              kv('MTF invested', s.mtfInvestedAmount),
              kv('Paid by you', s.paidByYou),
              kv('Provisional interest', s.provisionalInterest),
              kv('Maintenance margin', s.maintanceMargin),
              if (s.marginReqToday > 0) kv('Margin required today', s.marginReqToday),
              kv('Total outstanding', s.totalOutstandingAmount),
              Text('${b.scrips.length} MTF holdings · see the Holdings view.', style: sub),
            ]);
          },
        ),
      );

  String _m(num v) => NumberFormat('#,##,##0.00', 'en_IN').format(v);
  String _date(int n) => n <= 0 ? '' : DateFormat('d MMM').format(DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n));
}
