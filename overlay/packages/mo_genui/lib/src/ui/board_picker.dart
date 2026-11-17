import 'package:flutter/material.dart';
import 'package:mo_genui/src/ui/board.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

/// Bottom sheet that lets the user put a card on one or more boards, or make a new board.
/// Returns true when anything changed.
Future<bool> showBoardPicker(BuildContext context, BoardItem item) async {
  var changed = false;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.surfaceBackgroundNeutralNormal,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (sheet) => ValueListenableBuilder<List<Board>>(
      valueListenable: GenUiBoard.boards,
      builder: (context, boards, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Add "${item.title}" to', style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
            MOSpacing.verticalSpace4,
            Text('A card can sit on several boards. Each board keeps its own layout.', style: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
            MOSpacing.verticalSpace8,
            // The list scrolls on small screens; everything else stays put.
            Flexible(
              child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: <Widget>[
                for (final b in boards)
                  CheckboxListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: context.actionBackgroundPrimaryDefault,
                    value: GenUiBoard.isPinned(item.id, boardId: b.id),
                    title: Text(b.name, style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal)),
                    subtitle: Text('${b.items.length} card${b.items.length == 1 ? '' : 's'}${b.id == GenUiBoard.activeId.value ? ' · open now' : ''}',
                        style: MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong)),
                    onChanged: (v) {
                      changed = true;
                      if (v == true) {
                        GenUiBoard.pin(item, boardId: b.id);
                      } else {
                        GenUiBoard.unpin(item.id, boardId: b.id);
                      }
                    },
                  ),
              ]),
            ),
            MOSpacing.verticalSpace8,
            TextButton.icon(
              onPressed: GenUiBoard.canCreate
                  ? () async {
                      final name = await askBoardName(context, title: 'New board');
                      if (name == null || name.trim().isEmpty) return;
                      final b = GenUiBoard.create(name);
                      if (b != null) {
                        GenUiBoard.pin(item, boardId: b.id);
                        changed = true;
                      }
                    }
                  : null,
              icon: const Icon(Icons.add, size: 18),
              label: Text(GenUiBoard.canCreate ? 'New board' : 'New board (limit of $kMaxBoards reached)',
                  style: MOTypography.bodySmallSemibold.copyWith(color: GenUiBoard.canCreate ? context.surfaceTextPrimaryNormal : context.surfaceTextNeutralStrong)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.of(sheet).pop(), child: Text('Done', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPrimaryNormal))),
            ),
          ]),
        ),
      ),
    ),
  );
  return changed;
}

/// Small dialog for a board name (create or rename). Null when cancelled.
Future<String?> askBoardName(BuildContext context, {required String title, String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      backgroundColor: context.surfaceBackgroundNeutralNormal,
      title: Text(title, style: MOTypography.headingSmall.copyWith(color: context.surfaceTextNeutralNormal)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        maxLength: 24,
        textCapitalization: TextCapitalization.sentences,
        style: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralNormal),
        decoration: InputDecoration(
            hintText: 'e.g. Trading, My funds, F&O', hintStyle: MOTypography.bodyMediumRegular.copyWith(color: context.surfaceTextNeutralStrong), isDense: true, border: const OutlineInputBorder()),
        onSubmitted: (v) => Navigator.of(d).pop(v),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(d).pop(), child: Text('Cancel', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralStrong))),
        TextButton(onPressed: () => Navigator.of(d).pop(ctl.text), child: Text('Save', style: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextPrimaryNormal))),
      ],
    ),
  );
}
