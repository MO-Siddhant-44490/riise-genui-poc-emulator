# mo_genui (GenUI proof of concept)

Local POC package. Everything GenUI lives here; the rest of the app is touched in two places only
(`apps/super_app/pubspec.yaml` adds this package, `landingpage_header.dart` adds the AI entry button).

Flow: question → `RouterClient` (LLM on Bedrock, or offline keyword fallback) → `RouterDecision`
→ `A2uiMessage.createSurface` (A2UI-shaped) → `GenUiCatalog` renders the matching card → the card
loads live UAT data through the app's existing repositories (same session, same auth).

The LLM never sees account data and never produces numbers: it only picks a catalog action.

Run (debug, emulator), key never stored in the repo or APK source:

```
flutter run --flavor uat -t lib/main_uat.dart \
  --dart-define=GENUI_BEDROCK_KEY=$(cat <path to short-term key>) \
  --dart-define=GENUI_MODEL=qwen.qwen3-32b-v1:0
```

Without `GENUI_BEDROCK_KEY` the router falls back to keyword matching so the screen still works.
