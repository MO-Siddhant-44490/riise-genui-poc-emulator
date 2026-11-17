import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/entities/scrip_ref.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_orders/order_form/domain/brokerage_detailes_model.dart';
import 'package:trader_orders/order_form/services/order_form_repository.dart';
import 'package:trader_proto_gen/Reports/BrokerageModel.pb.dart';
import 'package:trader_proto_gen/TradingCore/CoreEnums.pbenum.dart';

/// Brokerage and statutory charge rates for an order, from the same API the
/// order pad's "Charges" sheet uses. Rates are per the user's plan; the
/// server does not return a rupee total, so the card shows the order value
/// alongside the rate table.
class ChargesCard extends StatefulWidget {
  const ChargesCard({super.key, required this.ref, this.side, this.product, this.qty});
  final ScripRef ref;
  final String? side;
  final String? product;
  final int? qty;

  @override
  State<ChargesCard> createState() => _ChargesCardState();
}

class _ChargesCardState extends State<ChargesCard> {
  late bool _buy = (widget.side ?? 'buy').toLowerCase() != 'sell';
  late ProductType _product = switch ((widget.product ?? 'delivery').toLowerCase()) { 'intraday' => ProductType.ValuePlus, 'mtf' => ProductType.MTF, _ => ProductType.Delivery };
  Future<BrokerageDetailResponseV2>? _future;

  Future<BrokerageDetailResponseV2> _load() => OrderFormRepositoryImpl().brokerageDetails(BrokerageDetailsInput(
        productType: _product.value,
        scripCode: int.tryParse(widget.ref.scripCode) ?? 0,
        exchange: widget.ref.exchangeCode ?? 0,
        action: (_buy ? OrderAction.Buy : OrderAction.Sell).value,
      ));

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    _future ??= _load();
    final qty = widget.qty ?? 1;
    return CardFrame(
      title: 'Charges · ${widget.ref.symbol}',
      subtitle: '${_buy ? 'Buy' : 'Sell'} $qty · ${_product == ProductType.ValuePlus ? 'Intraday' : _product == ProductType.MTF ? 'MTF' : 'Delivery'}',
      live: true,
      onRefresh: _reload,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Wrap(spacing: 6, children: <Widget>[
          ChoiceChip(label: const Text('Buy'), selected: _buy, visualDensity: VisualDensity.compact, onSelected: (_) { _buy = true; _reload(); }),
          ChoiceChip(label: const Text('Sell'), selected: !_buy, visualDensity: VisualDensity.compact, onSelected: (_) { _buy = false; _reload(); }),
          ChoiceChip(label: const Text('Delivery'), selected: _product == ProductType.Delivery, visualDensity: VisualDensity.compact, onSelected: (_) { _product = ProductType.Delivery; _reload(); }),
          ChoiceChip(label: const Text('Intraday'), selected: _product == ProductType.ValuePlus, visualDensity: VisualDensity.compact, onSelected: (_) { _product = ProductType.ValuePlus; _reload(); }),
        ]),
        LivePrice.scrip(
          scrip: widget.ref.scripId,
          builder: (context, t) => Padding(
            padding: MOSpacing.paddingVertical6,
            child: Text(t == null || t.ltp == 0 ? 'Order value: waiting for live price' : 'Order value ≈ ₹${NumberFormat('#,##,##0.00', 'en_IN').format(t.ltp * qty)} at ₹${t.ltp}',
                style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal)),
          ),
        ),
        FutureBuilder<BrokerageDetailResponseV2>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching charges…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load charges.", message: '${snap.error ?? 'No data'}', onRetry: _reload);
            final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
            final val = MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              if (r.brokerageType.isNotEmpty) Text('Plan: ${r.brokerageType}', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
              for (final s in r.brokerageDetails) ...<Widget>[
                Padding(padding: EdgeInsets.only(top: MOSpacing.spacing6), child: Text(s.title, style: MOTypography.bodyXsmallSemibold.copyWith(color: context.surfaceTextNeutralNormal))),
                for (final v in s.values) Padding(padding: MOSpacing.paddingVertical2, child: Row(children: <Widget>[Expanded(child: Text(v.label, style: sub)), Text('${v.value}', style: val)])),
              ],
              MOSpacing.verticalSpace6,
              Text('Exact amounts appear on the contract note after the trade.', style: sub),
            ]);
          },
        ),
      ]),
    );
  }
}
