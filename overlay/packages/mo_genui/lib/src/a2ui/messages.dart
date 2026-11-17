/// A2UI-shaped messages (https://a2ui.org). The POC produces the same four
/// message kinds the Flutter GenUI SDK consumes, so the renderer can later be
/// swapped for `package:genui` without changing the router or the catalog.
class A2uiMessage {
  const A2uiMessage._(this.type, this.body);

  /// `createSurface`, `updateComponents`, `updateDataModel` or `deleteSurface`.
  final String type;
  final Map<String, dynamic> body;

  String get surfaceId => body['surfaceId'] as String;

  /// Our catalog component for this surface (only for `createSurface`).
  String get component => body['component'] as String;

  Map<String, dynamic> get data =>
      (body['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

  factory A2uiMessage.createSurface({
    required String surfaceId,
    required String component,
    Map<String, dynamic> data = const <String, dynamic>{},
  }) =>
      A2uiMessage._('createSurface', <String, dynamic>{
        'surfaceId': surfaceId,
        'component': component,
        'data': data,
      });

  factory A2uiMessage.updateDataModel({
    required String surfaceId,
    required Map<String, dynamic> data,
  }) =>
      A2uiMessage._('updateDataModel', <String, dynamic>{
        'surfaceId': surfaceId,
        'data': data,
      });

  factory A2uiMessage.deleteSurface(String surfaceId) =>
      A2uiMessage._('deleteSurface', <String, dynamic>{'surfaceId': surfaceId});

  Map<String, dynamic> toJson() => <String, dynamic>{type: body};

  @override
  String toString() => 'A2uiMessage($type ${body['surfaceId']} ${body['component'] ?? ''})';
}
