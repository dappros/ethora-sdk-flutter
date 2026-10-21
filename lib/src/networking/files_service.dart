import 'dart:math' as math;

import 'api_client.dart';

/// One uploaded file of `GET /v2/files` (web `ApiFile`).
class ApiFile {
  const ApiFile({
    required this.id,
    required this.location,
    this.userId = '',
    this.roomName = '',
    this.locationPreview = '',
    this.originalName = '',
    this.filename = '',
    this.mimetype = '',
    this.size,
    this.duration = '',
    this.createdAt = '',
  });

  /// The file's own id (`_id`), also `attachmentId` on the chat message that
  /// carries it.
  final String id;
  final String userId;

  /// The room the file was uploaded for. The backend sends the room's name or
  /// its JID depending on the version, so [belongsToRoom] accepts both.
  final String roomName;
  final String location;
  final String locationPreview;
  final String originalName;
  final String filename;
  final String mimetype;
  final int? size;
  final String duration;
  final String createdAt;

  String get displayName {
    if (originalName.isNotEmpty) return originalName;
    if (filename.isNotEmpty) return filename;
    final segments = Uri.tryParse(location)?.pathSegments ?? const <String>[];
    return segments.isEmpty ? 'File' : segments.last;
  }

  DateTime? get createdAtDate => DateTime.tryParse(createdAt);

  /// True when the file was uploaded for the chat [chatName] (the JID
  /// localpart).
  bool belongsToRoom(String chatName) {
    if (chatName.isEmpty || roomName.isEmpty) return false;
    return roomName == chatName || roomName.split('@').first == chatName;
  }

  factory ApiFile.fromJson(Map<String, dynamic> json) {
    String s(String key) => json[key]?.toString() ?? '';
    return ApiFile(
      id: s('_id'),
      userId: s('userId'),
      roomName: s('roomName'),
      location: s('location'),
      locationPreview: s('locationPreview'),
      originalName: s('originalname'),
      filename: s('filename'),
      mimetype: s('mimetype'),
      size: int.tryParse(s('size')),
      duration: s('duration'),
      createdAt: s('createdAt'),
    );
  }
}

class FilesPage {
  const FilesPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<ApiFile> items;
  final int total;
  final int limit;
  final int offset;
}

/// Reads a files answer whichever envelope the backend used:
/// `{ items | results, pagination: { total, limit, offset }, total ... }`.
FilesPage parseFilesPage(
  Map<String, dynamic> data, {
  required int limit,
  required int offset,
}) {
  final raw = data['items'] ?? data['results'];
  final items = <ApiFile>[
    if (raw is List)
      for (final entry in raw)
        if (entry is Map) ApiFile.fromJson(Map<String, dynamic>.from(entry)),
  ];
  final pagination = data['pagination'] is Map
      ? Map<String, dynamic>.from(data['pagination'] as Map)
      : const <String, dynamic>{};
  int pick(String key, int fallback) =>
      int.tryParse('${pagination[key] ?? data[key] ?? ''}') ?? fallback;
  return FilesPage(
    items: items,
    total: pick('total', items.length),
    limit: pick('limit', limit),
    offset: pick('offset', offset),
  );
}

/// Whether the backend has the files list (web `FilesEndpointSupport`).
enum FilesEndpointSupport { unknown, supported, unsupported }

/// `GET /v2/files` and `DELETE /v2/files/{id}`.
class FilesService {
  FilesService({required this.apiClient});

  final ApiClient apiClient;

  /// The first real list request is the probe: a 404 or 501 means this
  /// backend does not have the route (web `getMyFiles`).
  FilesEndpointSupport support = FilesEndpointSupport.unknown;

  Future<FilesPage> list({int limit = kFilesPageSize, int offset = 0}) async {
    try {
      final body = await apiClient.get(
        '/v2/files',
        query: <String, String>{'limit': '$limit', 'offset': '$offset'},
      );
      support = FilesEndpointSupport.supported;
      return parseFilesPage(body, limit: limit, offset: offset);
    } on ApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 501) {
        support = FilesEndpointSupport.unsupported;
      }
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    await apiClient.delete('/v2/files/${Uri.encodeComponent(id)}');
  }
}

const int kFilesPageSize = 50;

/// The filter chips of the Files panel.
enum FileCategory { media, documents, audio }

/// Category from the mimetype (the one field the backend always sends):
/// images and videos are media, audio is audio, everything else (SVG too,
/// which is not rendered as a picture) is a document.
FileCategory fileCategoryOf(String? mimetype, [String? name]) {
  final type = (mimetype ?? '').toLowerCase();
  if (_isSvg(type, name)) return FileCategory.documents;
  if (type.startsWith('image/') || type.startsWith('video/')) {
    return FileCategory.media;
  }
  if (type.startsWith('audio/')) return FileCategory.audio;
  return FileCategory.documents;
}

bool _isSvg(String type, String? name) =>
    type.contains('svg') || (name ?? '').toLowerCase().endsWith('.svg');

/// Pictures, videos and PDFs open in the in-app viewer; the rest opens in the
/// platform browser.
bool isFilePreviewable(String? mimetype, [String? name]) {
  final type = (mimetype ?? '').toLowerCase();
  if (_isSvg(type, name)) return false;
  return type.startsWith('image/') ||
      type.startsWith('video/') ||
      type == 'application/pdf';
}

const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB'];

/// `formatBytes(1536)` is "1.5 KB".
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '0 B';
  final exponent = math.min(
    (math.log(bytes) / math.log(1024)).floor(),
    _units.length - 1,
  );
  final value = bytes / math.pow(1024, exponent);
  final rounded =
      exponent == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$rounded ${_units[exponent]}';
}

/// The files a room list search matches: by category and by a name fragment.
List<ApiFile> filterFiles(
  List<ApiFile> files, {
  FileCategory? category,
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  return files.where((file) {
    if (category != null &&
        fileCategoryOf(file.mimetype, file.originalName) != category) {
      return false;
    }
    if (needle.isNotEmpty &&
        !file.originalName.toLowerCase().contains(needle)) {
      return false;
    }
    return true;
  }).toList();
}
