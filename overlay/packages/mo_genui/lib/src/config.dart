/// Build-time configuration. All values come from `--dart-define`, so nothing
/// secret is ever written into the repo. In a release build these are empty and
/// the router falls back to the offline keyword matcher.
class GenUiConfig {
  GenUiConfig._();

  /// Short-term Bedrock API key (bearer token, expires in <= 12 h). Dev only.
  static const String bedrockKey = String.fromEnvironment('GENUI_BEDROCK_KEY');

  /// Bedrock model id or inference profile id used for routing.
  static const String model = String.fromEnvironment(
    'GENUI_MODEL',
    defaultValue: 'qwen.qwen3-32b-v1:0',
  );

  static const String region = String.fromEnvironment(
    'GENUI_REGION',
    defaultValue: 'ap-south-1',
  );

  /// Later: a Lambda Function URL that holds the long-term key server-side.
  /// When set, the app calls this instead of Bedrock directly.
  static const String aiServiceUrl = String.fromEnvironment('GENUI_AI_URL');

  /// Shared token the router service expects in `x-genui-token`. Not an AWS credential.
  static const String aiToken = String.fromEnvironment('GENUI_AI_TOKEN');

  static bool get hasLlm => bedrockKey.isNotEmpty || aiServiceUrl.isNotEmpty;

  static String get routerName {
    if (aiServiceUrl.isNotEmpty) return 'service · ${model.split('.').skip(1).join('.')}';
    if (bedrockKey.isNotEmpty) return model.split('.').skip(1).join('.');
    return 'offline rules';
  }
}
