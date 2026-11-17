import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mo_genui/src/live/live_price.dart';
import 'package:mo_genui/src/ui/board.dart';
import 'package:mo_genui/src/ui/board_picker.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

/// How much room the card has. Cards read [narrow] to stack two-column rows
/// when they sit at half width on the Board.
class CardLayout extends InheritedWidget {
  const CardLayout({super.key, required this.narrow, required this.width, required super.child});
  final bool narrow;
  final double width;

  static bool narrowOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CardLayout>()?.narrow ?? false;

  @override
  bool updateShouldNotify(CardLayout old) => narrow != old.narrow || width != old.width;
}

/// A list row: a leading block (name, detail) and trailing figures. Side by side when
/// the card has room; stacked when it sits in a half-width slot, so every list card
/// adapts to its slot without its own rule.
class AdaptiveRow extends StatelessWidget {
  const AdaptiveRow({super.key, this.start, required this.leading, required this.trailing, this.end});

  /// Optional badge / icon drawn before the leading block.
  final Widget? start;
  final Widget leading;
  final Widget trailing;

  /// Optional chevron / action drawn at the far end.
  final Widget? end;

  @override
  Widget build(BuildContext context) {
    if (!CardLayout.narrowOf(context)) {
      return Row(children: <Widget>[if (start != null) start!, Expanded(child: leading), trailing, if (end != null) end!]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Row(children: <Widget>[if (start != null) start!, Expanded(child: leading), if (end != null) end!]),
      // Figures keep their own line, flush right, so the eye finds them where the wide layout puts them.
      Align(alignment: Alignment.centerRight, child: trailing),
    ]);
  }
}

/// Shared chrome for every AI card: title row, status tag, refresh, and the
/// view switcher ("list / chart / table") that the user can change after the
/// router picked a default.
class CardFrame extends StatelessWidget {
  const CardFrame({
    super.key,
    required this.title,
    required this.child,
    this.tag = 'UAT data',
    this.live = false,
    this.onRefresh,
    this.views = const <String>[],
    this.view,
    this.onViewChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  /// Static tag text; ignored when [live] is true (then the feed status shows).
  final String tag;
  final bool live;
  final VoidCallback? onRefresh;
  final List<String> views;
  final String? view;
  final ValueChanged<String>? onViewChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // Half-width board cards: keep the title on the first line, move the tag and refresh below it.
      final narrow = box.maxWidth < 340;
      final tagWidget = live ? LiveTag(builder: (context, text) => CardTag(text: text)) : CardTag(text: tag);
      final refresh = onRefresh == null ? null : InkWell(onTap: onRefresh, child: Icon(Icons.refresh, size: 18, color: context.surfaceIconNeutralNormal));
      return MOCard(
        padding: narrow ? MOSpacing.paddingAll12 : MOSpacing.paddingAll16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, size: 16, color: context.surfaceTextPrimaryNormal),
                MOSpacing.horizontalSpace6,
                Expanded(
                  child: Text(title.toUpperCase(),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: MOTypography.labelSmallSemiboldAbc.copyWith(color: context.surfaceTextNeutralStrong, letterSpacing: .5)),
                ),
                if (!narrow) tagWidget,
                if (!narrow && refresh != null) ...<Widget>[MOSpacing.horizontalSpace6, refresh],
                _BoardActions(title: title),
              ],
            ),
            if (narrow) ...<Widget>[
              MOSpacing.verticalSpace4,
              Row(children: <Widget>[
                tagWidget,
                if (refresh != null) ...<Widget>[MOSpacing.horizontalSpace8, refresh]
              ]),
            ],
            if (subtitle != null) ...<Widget>[
              MOSpacing.verticalSpace2,
              Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            ],
            if (views.length > 1) ...<Widget>[
              MOSpacing.verticalSpace8,
              ViewSwitcher(views: views, selected: view ?? views.first, onChanged: onViewChanged),
            ],
            MOSpacing.verticalSpace8,
            CardLayout(narrow: narrow, width: box.maxWidth, child: child),
          ],
        ),
      );
    });
  }
}

/// Pin (chat) or size / move / remove (board) for the card being drawn, if it sits in a [CardScope].
class _BoardActions extends StatelessWidget {
  const _BoardActions({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final scope = CardScope.of(context);
    if (scope == null) return const SizedBox.shrink();
    return ValueListenableBuilder<List<Board>>(
      valueListenable: GenUiBoard.boards,
      builder: (context, boards, _) {
        final items = GenUiBoard.items.value;
        final pinned = GenUiBoard.isPinned(scope.surfaceId);
        if (!scope.onBoard) {
          final on = GenUiBoard.boardsOf(scope.surfaceId).map((b) => b.name).join(', ');
          return Padding(
            padding: const EdgeInsets.only(left: 6),
            child: InkWell(
              onTap: () async {
                // One board: the pin toggles. Several boards: choose where it goes.
                if (boards.length > 1) {
                  await showBoardPicker(context, scope.item(title));
                  return;
                }
                GenUiBoard.toggle(scope.item(title));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  duration: const Duration(seconds: 2),
                  content: Text(pinned ? 'Removed from your board.' : 'Pinned to ${GenUiBoard.active.name}. Open Board to lay it out.'),
                ));
              },
              onLongPress: () => showBoardPicker(context, scope.item(title)),
              child: Tooltip(
                message: pinned
                    ? 'On: $on'
                    : boards.length > 1
                        ? 'Add to a board'
                        : 'Pin to board',
                child: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 18, color: pinned ? context.surfaceTextPrimaryNormal : context.surfaceIconNeutralNormal),
              ),
            ),
          );
        }
        final others = boards.where((b) => b.id != GenUiBoard.activeId.value).toList();
        final item = GenUiBoard.byId(scope.surfaceId);
        final idx = items.indexWhere((i) => i.id == scope.surfaceId);
        // The host theme gives popup items no text colour, so every entry sets its own.
        final on = MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal);
        final off = MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
        final head = MOTypography.labelSmallSemiboldAbc.copyWith(color: context.surfaceTextNeutralStrong, letterSpacing: .5);
        final halfOk = GenUiBoard.halfOk(scope.component);
        Widget check(String size, String label, {bool enabled = true}) => Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              SizedBox(width: 24, child: item?.size == size ? Icon(Icons.check, size: 18, color: context.surfaceTextPrimaryNormal) : null),
              MOSpacing.horizontalSpace8,
              Text(label, style: enabled ? on : off),
            ]);
        return PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          tooltip: 'Arrange',
          color: context.surfaceBackgroundNeutralNormal,
          icon: Icon(Icons.more_horiz, size: 18, color: context.surfaceIconNeutralNormal),
          onSelected: (v) {
            String msg;
            switch (v) {
              case 'S':
              case 'M':
              case 'L':
                GenUiBoard.setSize(scope.surfaceId, v);
                msg = v == 'S' ? '$title is now half width.' : '$title is now full width.';
              case 'up':
                GenUiBoard.move(scope.surfaceId, -1);
                msg = 'Moved $title up.';
              case 'down':
                GenUiBoard.move(scope.surfaceId, 1);
                msg = 'Moved $title down.';
              case 'top':
                GenUiBoard.move(scope.surfaceId, -1000);
                msg = 'Moved $title to the top.';
              case 'remove':
                GenUiBoard.unpin(scope.surfaceId);
                msg = 'Removed $title from ${GenUiBoard.active.name}.';
              default:
                if (v.startsWith('to:')) {
                  final to = GenUiBoard.byBoardId(v.substring(3));
                  if (to == null) return;
                  GenUiBoard.moveTo(scope.surfaceId, to.id);
                  msg = 'Moved $title to ${to.name}.';
                } else if (v.startsWith('copy:')) {
                  final to = GenUiBoard.byBoardId(v.substring(5));
                  if (to == null) return;
                  GenUiBoard.pin(GenUiBoard.byId(scope.surfaceId) ?? scope.item(title), boardId: to.id);
                  msg = 'Added $title to ${to.name} as well.';
                } else {
                  return;
                }
            }
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(msg)));
          },
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(enabled: false, height: 32, child: Text('SIZE', style: head)),
            PopupMenuItem<String>(value: 'S', height: 40, enabled: halfOk, child: check('S', halfOk ? 'Half width' : 'Half width (full on phone)', enabled: halfOk)),
            PopupMenuItem<String>(value: 'M', height: 40, child: check('M', 'Full width')),
            PopupMenuItem<String>(value: 'L', height: 40, child: check('L', 'Full width, tall')),
            const PopupMenuDivider(),
            PopupMenuItem<String>(enabled: false, height: 32, child: Text('POSITION', style: head)),
            PopupMenuItem<String>(value: 'top', height: 40, enabled: idx > 0, child: Text('Move to top', style: idx > 0 ? on : off)),
            PopupMenuItem<String>(value: 'up', height: 40, enabled: idx > 0, child: Text('Move up', style: idx > 0 ? on : off)),
            PopupMenuItem<String>(value: 'down', height: 40, enabled: idx >= 0 && idx < items.length - 1, child: Text('Move down', style: idx >= 0 && idx < items.length - 1 ? on : off)),
            if (others.isNotEmpty) ...<PopupMenuEntry<String>>[
              const PopupMenuDivider(),
              PopupMenuItem<String>(enabled: false, height: 32, child: Text('BOARD', style: head)),
              for (final b in others) PopupMenuItem<String>(value: 'to:${b.id}', height: 40, child: Text('Move to ${b.name}', style: on)),
              for (final b in others)
                if (!GenUiBoard.isPinned(scope.surfaceId, boardId: b.id)) PopupMenuItem<String>(value: 'copy:${b.id}', height: 40, child: Text('Also show on ${b.name}', style: on)),
            ],
            const PopupMenuDivider(),
            PopupMenuItem<String>(
                value: 'remove', height: 40, child: Text('Remove from ${GenUiBoard.active.name}', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNegativeNormal))),
          ],
        );
      },
    );
  }
}

class CardTag extends StatelessWidget {
  const CardTag({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: MOSpacing.spacing6, vertical: MOSpacing.spacing2),
        decoration: BoxDecoration(color: context.surfaceBackgroundPrimaryFaded, borderRadius: BorderRadius.circular(MOSpacing.spacing6)),
        child: Text(text, style: MOTypography.labelSmallMediumAbc.copyWith(color: context.surfaceTextPrimaryNormal)),
      );
}

/// Pill row: the user's way to re-shape an answer without asking again.
class ViewSwitcher extends StatelessWidget {
  const ViewSwitcher({super.key, required this.views, required this.selected, this.onChanged});
  final List<String> views;
  final String selected;
  final ValueChanged<String>? onChanged;

  static const Map<String, IconData> _icons = <String, IconData>{
    'summary': Icons.dashboard_rounded,
    'list': Icons.view_list_rounded,
    'chart': Icons.bar_chart_rounded,
    'bars': Icons.bar_chart_rounded,
    'table': Icons.table_rows_rounded,
    'tiles': Icons.grid_view_rounded,
    'snapshot': Icons.dashboard_rounded,
    'returns': Icons.show_chart_rounded,
    'fundamentals': Icons.analytics_outlined,
    'technicals': Icons.ssid_chart_rounded,
    'news': Icons.newspaper_rounded,
    'strip': Icons.view_week_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return ChipStrip(
      height: 30,
      selectedIndex: views.indexOf(selected),
      children: <Widget>[
        for (final v in views)
          Padding(
            padding: EdgeInsets.only(right: MOSpacing.spacing6),
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: () => onChanged?.call(v),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: MOSpacing.spacing10),
                decoration: BoxDecoration(
                  color: v == selected ? context.actionBackgroundPrimaryDefault : context.surfaceBackgroundNeutralFaded,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(_icons[v] ?? Icons.circle_outlined, size: 13, color: v == selected ? context.surfaceTextStaticWhiteNormal : context.surfaceTextNeutralStrong),
                    MOSpacing.horizontalSpace4,
                    Text(v[0].toUpperCase() + v.substring(1),
                        style: MOTypography.labelSmallMediumAbc.copyWith(color: v == selected ? context.surfaceTextStaticWhiteNormal : context.surfaceTextNeutralStrong)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A horizontal strip of chips that scrolls by finger, mouse drag, trackpad or wheel, fades at
/// the edge that has more, and offers a chevron that pages. [selectedIndex] is scrolled into
/// view when it changes, so the active tab is never hidden off the edge.
class ChipStrip extends StatefulWidget {
  const ChipStrip({super.key, required this.children, this.height = 32, this.selectedIndex = -1, this.trailing});
  final List<Widget> children;
  final double height;
  final int selectedIndex;

  /// An extra control drawn after the chevron (the composer uses it for "all prompts").
  final Widget? trailing;

  @override
  State<ChipStrip> createState() => _ChipStripState();
}

class _ChipStripState extends State<ChipStrip> {
  final ScrollController _ctl = ScrollController();
  final List<GlobalKey> _keys = <GlobalKey>[];
  bool _moreRight = true;
  bool _moreLeft = false;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_edges);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _edges();
      _reveal();
    });
  }

  @override
  void didUpdateWidget(ChipStrip old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  void _reveal() {
    final i = widget.selectedIndex;
    if (i < 0 || i >= _keys.length) return;
    final ctx = _keys[i].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5, duration: const Duration(milliseconds: 200));
  }

  void _edges() {
    if (!_ctl.hasClients) return;
    final p = _ctl.position;
    final r = p.pixels < p.maxScrollExtent - 4;
    final l = p.pixels > 4;
    if (r != _moreRight || l != _moreLeft) {
      setState(() {
        _moreRight = r;
        _moreLeft = l;
      });
    }
  }

  void _page(int dir) {
    if (!_ctl.hasClients) return;
    final w = _ctl.position.viewportDimension * 0.8;
    _ctl.animateTo((_ctl.offset + dir * w).clamp(0, _ctl.position.maxScrollExtent).toDouble(), duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.children.length) {
      _keys.add(GlobalKey());
    }
    final bg = context.surfaceBackgroundNeutralNormal;
    // The chips scroll in their own strip; the trailing control sits beside it, never over it.
    final strip = Stack(children: <Widget>[
      Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && _ctl.hasClients) {
            final d = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() ? e.scrollDelta.dx : e.scrollDelta.dy;
            _ctl.jumpTo((_ctl.offset + d).clamp(0, _ctl.position.maxScrollExtent).toDouble());
          }
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false, dragDevices: PointerDeviceKind.values.toSet()),
          child: ListView(
            controller: _ctl,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            children: <Widget>[
              for (var i = 0; i < widget.children.length; i++) KeyedSubtree(key: _keys[i], child: widget.children[i]),
              const SizedBox(width: 40),
            ],
          ),
        ),
      ),
      if (_moreRight)
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: InkWell(
            onTap: () => _page(1),
            child: Container(
              width: 48,
              decoration: BoxDecoration(gradient: LinearGradient(colors: <Color>[bg.withValues(alpha: 0), bg, bg])),
              alignment: Alignment.centerRight,
              child: Icon(Icons.chevron_right, size: 20, color: context.surfaceTextPrimaryNormal),
            ),
          ),
        ),
      if (_moreLeft)
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: InkWell(
            onTap: () => _page(-1),
            child: Container(
                width: 28,
                decoration: BoxDecoration(gradient: LinearGradient(colors: <Color>[bg, bg.withValues(alpha: 0)])),
                alignment: Alignment.centerLeft,
                child: Icon(Icons.chevron_left, size: 18, color: context.surfaceTextPrimaryNormal)),
          ),
        ),
    ]);
    return SizedBox(
      height: widget.height,
      child: widget.trailing == null ? strip : Row(children: <Widget>[Expanded(child: strip), widget.trailing!]),
    );
  }
}

/// Loading / error states shared by cards.
class CardLoading extends StatelessWidget {
  const CardLoading({super.key, this.text = 'Fetching…'});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: context.surfaceTextPrimaryNormal)),
          MOSpacing.horizontalSpace12,
          Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong))),
        ],
      );
}

class CardError extends StatelessWidget {
  const CardError({super.key, required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(title, style: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal)),
          MOSpacing.verticalSpace4,
          Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
          if (onRetry != null) ...<Widget>[
            MOSpacing.verticalSpace8,
            MOButton(label: 'Retry', onPressed: onRetry, variant: MOButtonVariant.secondary, color: MOButtonColor.primary, size: MOButtonSize.small),
          ],
        ],
      );
}

/// Formatting helpers shared by cards. Prices arrive as rupees (double) or paise (int) depending on the API.
String signed(num v, {int decimals = 2}) => '${v < 0 ? '−' : '+'}${v.abs().toStringAsFixed(decimals)}';
String pct(num v) => '${signed(v)}%';
Color deltaColor(BuildContext context, num v) => v < 0 ? context.surfaceTextNegativeNormal : (v > 0 ? context.surfaceTextPositiveNormal : context.surfaceTextNeutralStrong);
