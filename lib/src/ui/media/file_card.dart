import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/media_attachment.dart';
import '../../theme/chat_theme.dart';

/// A PDF, audio or other file in a message: icon, name, size, and a tap that
/// opens the (token-appended) URL in the platform browser, like web
/// FileDownload and PdfMessage.
class MediaFileCard extends StatelessWidget {
  const MediaFileCard({
    super.key,
    required this.name,
    required this.url,
    required this.kind,
    this.size,
  });

  final String name;

  /// Already carries `ft` for secure URLs. Empty while the file is not up.
  final String url;
  final MediaKind kind;
  final String? size;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    final icon = switch (kind) {
      MediaKind.pdf => Icons.picture_as_pdf_rounded,
      MediaKind.audio => Icons.audiotrack_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
    final sizeLabel = formatFileSize(size);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: url.isEmpty ? null : () => openMediaUrl(context, url),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.bgSubtle,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.border),
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.icons, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: theme.text,
                      ),
                    ),
                    if (sizeLabel != null)
                      Text(
                        sizeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                url.isEmpty
                    ? Icons.hourglass_empty_rounded
                    : Icons.open_in_new_rounded,
                size: 18,
                color: theme.icons,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens an http(s) URL outside the app. Other schemes are ignored.
Future<void> openMediaUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (uri == null || (scheme != 'https' && scheme != 'http')) return;
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(ChatUiScope.of(context).strings.t('media.openFailed')),
      ),
    );
  }
}

/// "1.4 MB" style label, or null when the size is missing or not a number.
String? formatFileSize(String? raw) {
  final bytes = num.tryParse(raw ?? '');
  if (bytes == null || bytes <= 0) return null;
  if (bytes < 1024) return '${bytes.toInt()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
