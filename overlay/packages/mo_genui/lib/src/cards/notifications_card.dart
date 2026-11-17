import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mo_genui/src/ui/card_frame.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:trader_core/locator.dart';
import 'package:trader_notifications/domain/notification_repository.dart';
import 'package:trader_proto_gen/Notification/Notification.pb.dart';

/// The in-app notification list, same API as the bell icon.
class NotificationsCard extends StatefulWidget {
  const NotificationsCard({super.key, this.category});
  final String? category;

  @override
  State<NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<NotificationsCard> {
  late Future<NotificationResponse> _future = getIt<NotificationRepository>().getNotificationListApi();
  String? _category;

  @override
  void initState() {
    super.initState();
    _category = widget.category?.toLowerCase();
  }

  @override
  Widget build(BuildContext context) => CardFrame(
        title: 'Notifications',
        onRefresh: () => setState(() { _future = getIt<NotificationRepository>().getNotificationListApi(); }),
        child: FutureBuilder<NotificationResponse>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const CardLoading(text: 'Fetching…');
            final r = snap.data;
            if (snap.hasError || r == null) return CardError(title: "Couldn't load notifications.", message: '${snap.error ?? 'No data'}', onRetry: () => setState(() { _future = getIt<NotificationRepository>().getNotificationListApi(); }));
            final cats = r.entry.map((e) => e.visibleCategory.isEmpty ? e.category : e.visibleCategory).where((c) => c.isNotEmpty).toSet().toList();
            final rows = r.entry.where((e) => _category == null || e.category.toLowerCase().contains(_category!) || e.visibleCategory.toLowerCase().contains(_category!)).take(12).toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              if (cats.length > 1)
                SizedBox(
                  height: 30,
                  child: ListView(scrollDirection: Axis.horizontal, children: <Widget>[
                    Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: const Text('All'), selected: _category == null, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _category = null))),
                    for (final c in cats)
                      Padding(padding: EdgeInsets.only(right: MOSpacing.spacing6), child: ChoiceChip(label: Text(c), selected: _category == c.toLowerCase(), visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => _category = c.toLowerCase()))),
                  ]),
                ),
              if (rows.isEmpty) Text('No notifications.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
              for (final n in rows)
                Padding(
                  padding: MOSpacing.paddingVertical6,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(n.title, style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
                    if (n.message.isNotEmpty) Text(n.message, maxLines: 3, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    Text('${n.visibleCategory.isEmpty ? n.category : n.visibleCategory}${n.entryDate == 0 ? '' : ' · ${DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(n.entryDate < 100000000000 ? n.entryDate * 1000 : n.entryDate))}'}',
                        style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                  ]),
                ),
            ]);
          },
        ),
      );
}
