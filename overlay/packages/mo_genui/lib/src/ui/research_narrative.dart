import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:mo_research_assistant/research_assistant/data/mo_research_assistant_impl.dart';
import 'package:mo_research_assistant/research_assistant/domain/model/chat_screen/stream_response_model.dart';
import 'package:mofsl_ui_library/mofsl_ui_library.dart';
import 'package:mosl_security/prefs/rise_shared_preference.dart';

/// The research desk's words on a question, streamed from the Motilal Oswal research
/// assistant and drawn under a card's own numbers. The card stays useful if the assistant
/// is slow or silent: this block only ever adds to it.
class ResearchNarrative extends StatefulWidget {
  const ResearchNarrative({super.key, required this.question, this.heading = "Research desk's view", this.timeout = const Duration(seconds: 90)});
  final String question;
  final String heading;
  final Duration timeout;

  @override
  State<ResearchNarrative> createState() => _ResearchNarrativeState();
}

class _ResearchNarrativeState extends State<ResearchNarrative> {
  final MoResearchAssistantImpl _repo = MoResearchAssistantImpl();
  StreamSubscription<StreamChatResponse>? _sub;
  Timer? _timer;
  String _status = '';
  String _text = '';
  String? _err;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(ResearchNarrative old) {
    super.didUpdateWidget(old);
    if (old.question != widget.question) _ask();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _ask() async {
    await _sub?.cancel();
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _status = '';
      _text = '';
      _err = null;
      _done = false;
    });
    // Past the wait we show a note but keep listening: a late answer still replaces it.
    _timer = Timer(widget.timeout, () {
      if (mounted && !_done && _text.isEmpty) setState(() => _err = 'The research assistant is taking longer than usual.');
    });
    try {
      final profile = await SecureSharedPreference.getprofile() ?? '{}';
      final clientId = '${(jsonDecode(profile) as Map<String, dynamic>)['client_id'] ?? ''}';
      final s = await _repo.startSession(clientId);
      var sessionId = s.data?.sessionId ?? '';
      final req = StreamChatRequest(text: widget.question, sessionId: sessionId, requestId: DateTime.now().millisecondsSinceEpoch.toString());
      _sub = _repo.getStreamChatResponse(sessionId: sessionId, request: req).listen((r) {
        if (!mounted) return;
        setState(() {
          if ((r.data?.sessionId ?? '').isNotEmpty) sessionId = r.data!.sessionId!;
          final secs = r.data?.msg?.sections ?? const [];
          if (r.isFinalResponse) {
            _err = null;
            if (secs.isNotEmpty) {
              _text = secs.map((x) => '${(x.title ?? '').isNotEmpty ? '**${x.title}**\n\n' : ''}${x.content ?? ''}').where((t) => t.trim().isNotEmpty).join('\n\n');
            }
            // The assistant's polite refusal is not a view; show the "nothing to add" line instead.
            if (RegExp(r'apolog|not (able|fulfil|fullfil)|cannot (help|assist)', caseSensitive: false).hasMatch(_text) && _text.length < 240) _text = '';
            _done = true;
          } else if (r.isStreamingChunk) {
            final chunk = secs.isNotEmpty ? secs.map((x) => x.content ?? '').join() : r.message;
            if (chunk.trim().isNotEmpty && chunk != 'chunk') _status = chunk.trim();
          } else if (r.status.toLowerCase().contains('error') || r.code >= 400) {
            _err = r.message.isEmpty ? 'The research assistant returned an error.' : r.message;
            _done = true;
          }
        });
      }, onError: (Object e) {
        if (mounted) {
          setState(() {
            _err = '$e'.replaceFirst('Exception: ', '');
            _done = true;
          });
        }
      }, onDone: () {
        if (mounted) setState(() => _done = true);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = '$e'.replaceFirst('Exception: ', '');
          _done = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = MOTypography.bodyXsmallRegular.copyWith(color: context.surfaceTextNeutralStrong);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: MOSpacing.paddingAll12,
      decoration: BoxDecoration(color: context.surfaceBackgroundNeutralSubtle, borderRadius: BorderRadius.circular(MOSpacing.spacing8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.auto_stories_outlined, size: 14, color: context.surfaceTextPrimaryNormal),
          MOSpacing.horizontalSpace6,
          Text(widget.heading, style: MOTypography.labelSmallSemiboldAbc.copyWith(color: context.surfaceTextPrimaryNormal, letterSpacing: .4)),
          const Spacer(),
          Text('MO Research AI', style: sub),
        ]),
        MOSpacing.verticalSpace6,
        if (_text.isNotEmpty)
          MarkdownBody(
            data: _text,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal),
              h1: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal),
              h2: MOTypography.bodyMediumSemibold.copyWith(color: context.surfaceTextNeutralNormal),
              h3: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal),
              strong: MOTypography.bodySmallSemibold.copyWith(color: context.surfaceTextNeutralNormal),
              listBullet: MOTypography.bodySmallRegular.copyWith(color: context.surfaceTextNeutralNormal),
            ),
          )
        else if (_err != null)
          Text('$_err The text above is the app\'s own.', style: sub)
        else if (!_done)
          Row(children: <Widget>[
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            MOSpacing.horizontalSpace8,
            Expanded(child: Text(_status.isEmpty ? 'Asking the research desk…' : _status.replaceAll(RegExp(r'\.{3,}$'), '…'), maxLines: 2, overflow: TextOverflow.ellipsis, style: sub)),
          ])
        else
          Text('The research desk had nothing to add.', style: sub),
      ]),
    );
  }
}
