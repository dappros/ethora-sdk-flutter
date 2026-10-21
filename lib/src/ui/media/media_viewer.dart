import 'package:flutter/material.dart';

import '../../models/media_attachment.dart';
import '../../networking/secure_file_url.dart';
import '../../theme/chat_theme.dart';
import 'file_card.dart';

/// Full-screen viewer over the files of one message. Swiping pages through
/// the message's files (web FilePreviewModal with siblings). Pictures zoom
/// with pinch; videos and other files open in the platform browser.
class MediaViewerPage extends StatefulWidget {
  const MediaViewerPage({
    super.key,
    required this.attachments,
    this.initialIndex = 0,
    this.fileToken,
  });

  /// Attachments that have a location, in message order.
  final List<Map<String, String>> attachments;
  final int initialIndex;
  final String? fileToken;

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  late final PageController _pages;
  late int _index;

  @override
  void initState() {
    super.initState();
    final last = widget.attachments.length - 1;
    _index = widget.initialIndex.clamp(0, last < 0 ? 0 : last);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.attachments.length;
    final current = widget.attachments[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          attachmentName(current),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: ChatUiScope.of(context).strings.t('media.openInBrowser'),
            icon: const Icon(Icons.open_in_new_rounded),
            onPressed: () => openMediaUrl(
              context,
              appendFileToken(current['location'], widget.fileToken),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: total,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) => _ViewerSlide(
                attachment: widget.attachments[index],
                fileToken: widget.fileToken,
              ),
            ),
          ),
          if (total > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: Text(
                '${_index + 1} / $total',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

class _ViewerSlide extends StatelessWidget {
  const _ViewerSlide({required this.attachment, this.fileToken});

  final Map<String, String> attachment;
  final String? fileToken;

  @override
  Widget build(BuildContext context) {
    final name = attachmentName(attachment);
    final url = appendFileToken(attachment['location'], fileToken);
    final kind = mediaKindOf(attachment['mimetype'], name);
    if (kind == MediaKind.image) {
      return _ZoomableImage(url: url);
    }
    final icon = switch (kind) {
      MediaKind.video => Icons.movie_outlined,
      MediaKind.audio => Icons.audiotrack_rounded,
      MediaKind.pdf => Icons.picture_as_pdf_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
    final strings = ChatUiScope.of(context).strings;
    final actionLabel = kind == MediaKind.video
        ? strings.t('media.videoPlay')
        : strings.t('files.action.preview');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              name,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: url.isEmpty ? null : () => openMediaUrl(context, url),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// A picture that zooms with pinch. Panning is only enabled while zoomed, so
/// at normal scale a horizontal drag still pages to the next file.
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({required this.url});

  final String url;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final TransformationController _transform = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 4,
      panEnabled: _zoomed,
      child: Center(
        child: Image.network(
          widget.url,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return const Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: Colors.white54,
            );
          },
        ),
      ),
    );
  }
}
