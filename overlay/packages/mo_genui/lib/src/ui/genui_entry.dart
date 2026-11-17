import 'package:flutter/material.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';

import 'package:mo_genui/src/ui/genui_screen.dart';

/// Small "AI" pill for the home header. The only widget the host app embeds.
class GenUiEntryButton extends StatelessWidget {
  const GenUiEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const GenUiScreen())),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: context.actionBackgroundPrimaryDefault,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_awesome, size: 13, color: context.feedbackIconWarningNormal),
            const SizedBox(width: 4),
            Text('AI', style: MOTypography.labelSmallSemiboldAbc.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
