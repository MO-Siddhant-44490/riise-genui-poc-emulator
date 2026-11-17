import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mosl_broadcaster/core/broadcast_helper.dart';
import 'package:mosl_broadcaster/models/request_models.dart';
import 'package:mosl_broadcaster/models/response_models.dart';
import 'package:mosl_socket_core/models/socket_state.dart';
import 'package:trader_proto_gen/TradingCore/ScripId.pb.dart';

/// App-wide: has any live tick arrived? Cards use it to say "no live feed"
/// instead of showing dashes forever (UAT's feed is often silent).
class LiveFeedStatus {
  LiveFeedStatus._();
  static final ValueNotifier<bool> hasTicks = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> waitedLong = ValueNotifier<bool>(false);

  /// Broadcast socket state as the app's broadcaster reports it, plus the last
  /// connection error, so the tag can say whether the socket is even up.
  static final ValueNotifier<String> socket = ValueNotifier<String>('unknown');
  static Timer? _timer;
  static StreamSubscription<dynamic>? _stateSub;
  static StreamSubscription<dynamic>? _errSub;
  static StreamSubscription<BroadcastResponse2>? _anySub;

  static void _watch() {
    if (_stateSub != null) return;
    final h = BroadCastHelper.instance;
    _stateSub = h.socketStateStream.listen((SocketState st) => socket.value = st.name);
    _errSub = h.connectionErrorStream.listen((e) => socket.value = 'error');
    // Any tick on any symbol proves the feed is alive, even for symbols no card shows.
    _anySub = h.onStreamReceived().listen((t) {
      if (t.ltp != 0 && !hasTicks.value) {
        hasTicks.value = true;
        waitedLong.value = false;
      }
    });
  }

  static void noteSubscribed() {
    _watch();
    if (hasTicks.value || _timer != null) return;
    _timer = Timer(const Duration(seconds: 6), () {
      if (!hasTicks.value) waitedLong.value = true;
    });
  }

  static void noteTick(BroadcastResponse2 t) {
    if (t.ltp == 0 || hasTicks.value) return;
    // Called from inside a StreamBuilder's build; notify listeners after the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (hasTicks.value) return;
      hasTicks.value = true;
      waitedLong.value = false;
    });
  }
}

/// Subscribes one symbol to the app's live price feed (the same broadcaster
/// every classic screen uses) and rebuilds on each tick. Streaming is shared
/// app-wide, so there is nothing to tear down per card.
class LivePrice extends StatefulWidget {
  const LivePrice({super.key, required this.symbol, required this.builder});

  LivePrice.scrip({super.key, required ScripId scrip, required this.builder})
      : symbol = BroadcastSymbol.forScrip(scripCode: scrip.scripCode, exchangeCode: scrip.exchange.value);

  LivePrice.index({super.key, required String indexId, required int exchangeCode, required this.builder})
      : symbol = BroadcastSymbol.forIndex(indexId: indexId, exchangeCode: exchangeCode);

  final BroadcastSymbol symbol;
  final Widget Function(BuildContext context, BroadcastResponse2? tick) builder;

  @override
  State<LivePrice> createState() => _LivePriceState();
}

class _LivePriceState extends State<LivePrice> {
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(LivePrice old) {
    super.didUpdateWidget(old);
    if (old.symbol != widget.symbol) _subscribe();
  }

  void _subscribe() => subscribeLive(<BroadcastSymbol>[widget.symbol]);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BroadcastResponse2>(
      stream: BroadCastHelper.instance.onTickReceived(widget.symbol),
      builder: (context, snap) {
        final t = snap.data;
        if (t != null) LiveFeedStatus.noteTick(t);
        return widget.builder(context, t);
      },
    );
  }
}

/// Subscribes many symbols at once (lists), then lets rows read ticks via [LivePrice].
void subscribeLive(Iterable<BroadcastSymbol> symbols) {
  final set = symbols.toSet();
  if (set.isEmpty) return;
  BroadCastHelper.instance.fetchSnapShot(set);
  BroadCastHelper.instance.startQuoteStreaming(set);
  LiveFeedStatus.noteSubscribed();
}

/// Small status tag: "Live" once ticks flow, "No live feed" after a wait.
class LiveTag extends StatelessWidget {
  const LiveTag({super.key, required this.builder});
  final Widget Function(BuildContext context, String text) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: LiveFeedStatus.hasTicks,
        builder: (context, has, _) => ValueListenableBuilder<bool>(
          valueListenable: LiveFeedStatus.waitedLong,
          builder: (context, waited, _) => ValueListenableBuilder<String>(
            valueListenable: LiveFeedStatus.socket,
            builder: (context, sock, _) => builder(
              context,
              has
                  ? 'Live · UAT'
                  : !waited
                      ? 'Connecting…'
                      : sock == 'connected'
                          ? 'Socket up · no ticks from UAT'
                          : sock == 'error' || sock == 'disconnected'
                              ? 'Feed socket $sock'
                              : 'No live feed (UAT)',
            ),
          ),
        ),
      );
}
