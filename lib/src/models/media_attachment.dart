import 'dart:convert';

import 'chat_message.dart';

/// Web MAX_ATTACHMENTS_PER_MESSAGE: the hard cap on files in one message.
const int kMaxAttachmentsPerMessage = 10;

/// Web MEDIA_UPLOAD_CONCURRENCY: files of one message uploaded at a time.
const int kMediaUploadConcurrency = 4;

/// One file the caller wants to send with [ChatComponentController.sendMediaFiles].
class MediaFileInput {
  const MediaFileInput({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final List<int> bytes;
  final String filename;
  final String mimeType;
}

/// Maps one `results` entry of POST /v2/files/secure (or /v1/files/) to the
/// attachment map a message carries, like web toUploadedAttachment. The API
/// spells `originalname` and `filename` in lowercase; the wire does not care.
Map<String, String> attachmentFromUploadResult(Map<String, dynamic> raw) {
  String f(String key) => raw[key]?.toString() ?? '';
  return <String, String>{
    if (f('_id').isNotEmpty) 'attachmentId': f('_id'),
    'location': f('location'),
    if (f('locationPreview').isNotEmpty)
      'locationPreview': f('locationPreview'),
    'mimetype': f('mimetype'),
    'originalName': f('originalname'),
    'fileName': f('filename'),
    'size': f('size'),
    if (f('duration').isNotEmpty) 'duration': f('duration'),
  };
}

/// The `attachments` JSON attribute of a multi-file message, like web
/// serializeAttachments: only the fields a receiver renders.
String serializeAttachments(List<Map<String, String>> attachments) {
  return jsonEncode(
    attachments.take(kMaxAttachmentsPerMessage).map((item) {
      return <String, String>{
        if ((item['attachmentId'] ?? '').isNotEmpty)
          'attachmentId': item['attachmentId']!,
        'location': item['location'] ?? '',
        if ((item['locationPreview'] ?? '').isNotEmpty)
          'locationPreview': item['locationPreview']!,
        'mimetype': item['mimetype'] ?? '',
        'originalName': item['originalName'] ?? '',
        'fileName': item['fileName'] ?? '',
        'size': item['size'] ?? '',
        if ((item['duration'] ?? '').isNotEmpty) 'duration': item['duration']!,
      };
    }).toList(),
  );
}

/// The files of a message. Multi-file messages carry `attachments`; every
/// other message (older web clients, single file) is read from its flat
/// `<data>` fields, which describe one file.
List<Map<String, String>> messageAttachments(ChatMessage message) {
  if (message.attachments.isNotEmpty) return message.attachments;
  final location = message.mediaUrl ?? message.data['location'] ?? '';
  if (location.isEmpty) return const <Map<String, String>>[];
  final data = message.data;
  return <Map<String, String>>[
    <String, String>{
      'location': location,
      if ((data['locationPreview'] ?? '').isNotEmpty)
        'locationPreview': data['locationPreview']!,
      'mimetype': message.mimeType ?? data['mimetype'] ?? '',
      'originalName': data['originalName'] ?? '',
      'fileName': data['fileName'] ?? '',
      'size': data['size'] ?? '',
      if ((data['duration'] ?? '').isNotEmpty) 'duration': data['duration']!,
    },
  ];
}

/// Name to show for an attachment, with the URL tail as the last resort.
String attachmentName(Map<String, String> attachment) {
  final original = attachment['originalName'] ?? '';
  if (original.isNotEmpty) return original;
  final name = attachment['fileName'] ?? '';
  if (name.isNotEmpty) return name;
  final location = attachment['location'] ?? '';
  final segments = Uri.tryParse(location)?.pathSegments ?? const <String>[];
  final tail = segments.isEmpty ? '' : segments.last;
  return tail.isEmpty ? 'File' : tail;
}

/// The coarse kind a tile or card renders as, from the mimetype and then the
/// file extension when the mimetype says nothing (web helpers/fileKind).
enum MediaKind { image, video, audio, pdf, file }

const Map<String, String> _extensionMime = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'pdf': 'application/pdf',
};

MediaKind mediaKindOf(String? mimetype, String name) {
  var mime = (mimetype ?? '').toLowerCase().split(';').first.trim();
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (mime.isEmpty || mime == 'application/octet-stream') {
    mime = _extensionMime[ext] ?? mime;
  }
  if (mime == 'application/pdf' || ext == 'pdf') return MediaKind.pdf;
  if (mime.startsWith('image/') && !mime.contains('svg')) {
    return MediaKind.image;
  }
  if (mime.startsWith('video/')) return MediaKind.video;
  if (mime.startsWith('audio/')) return MediaKind.audio;
  return MediaKind.file;
}

/// Guesses the mimetype from the file name, like web composer fallback.
String mimeTypeForFilename(String filename) {
  final ext =
      filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
  return _extensionMime[ext] ?? 'application/octet-stream';
}
