import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/media_attachment.dart';
import '../../networking/secure_file_url.dart';
import '../../theme/chat_theme.dart';
import 'file_card.dart';
import 'media_viewer.dart';

const double _albumWidth = 280;
const double _albumGap = 2;
const int _albumVisibleTiles = 4;

/// The files of one media message, like web AttachmentList: pictures and
/// videos as an album grid, PDFs and other files as cards. A tap on a
/// picture or video opens the full-screen viewer, which swipes across every
/// file of the message. Every URL gets the viewer's own `ft` for secure files.
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({
    super.key,
    required this.attachments,
    this.fileToken,
  });

  final List<Map<String, String>> attachments;
  final String? fileToken;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) {
      return Text(
        ChatUiScope.of(context).strings.t('media.unsupported'),
        style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
      );
    }

    final visual = <int>[];
    final cards = <int>[];
    for (var i = 0; i < attachments.length; i++) {
      final kind = _kindOf(attachments[i]);
      if (kind == MediaKind.image || kind == MediaKind.video) {
        visual.add(i);
      } else {
        cards.add(i);
      }
    }

    // The viewer pages over files that can be opened, in message order.
    final openable = <int>[
      for (var i = 0; i < attachments.length; i++)
        if ((attachments[i]['location'] ?? '').isNotEmpty) i,
    ];

    void open(int index) {
      final position = openable.indexOf(index);
      if (position < 0) return;
      // The route sits outside the chat widget, so carry the scope along.
      final scope = ChatUiScope.of(context);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatUiScope(
            theme: scope.theme,
            strings: scope.strings,
            child: MediaViewerPage(
              attachments: [for (final i in openable) attachments[i]],
              initialIndex: position,
              fileToken: fileToken,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (visual.isNotEmpty)
          _Album(
            indices: visual,
            attachments: attachments,
            fileToken: fileToken,
            onOpen: open,
          ),
        for (final index in cards)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: _albumWidth,
              child: MediaFileCard(
                name: attachmentName(attachments[index]),
                url: appendFileToken(attachments[index]['location'], fileToken),
                kind: _kindOf(attachments[index]),
                size: attachments[index]['size'],
              ),
            ),
          ),
      ],
    );
  }
}

MediaKind _kindOf(Map<String, String> attachment) {
  return mediaKindOf(attachment['mimetype'], attachmentName(attachment));
}

/// One picture: full width at 4:3. Two or more: a 2-column grid of squares,
/// showing up to four tiles, the last one carrying "+N" for the rest.
class _Album extends StatelessWidget {
  const _Album({
    required this.indices,
    required this.attachments,
    required this.fileToken,
    required this.onOpen,
  });

  final List<int> indices;
  final List<Map<String, String>> attachments;
  final String? fileToken;
  final void Function(int index) onOpen;

  @override
  Widget build(BuildContext context) {
    if (indices.length == 1) {
      return _tile(
        indices.first,
        width: _albumWidth,
        height: _albumWidth * 3 / 4,
        moreCount: 0,
      );
    }

    final visible = math.min(indices.length, _albumVisibleTiles);
    final hidden = indices.length - visible;
    final cell = (_albumWidth - _albumGap) / 2;
    final rows = <Widget>[];
    for (var start = 0; start < visible; start += 2) {
      final rowChildren = <Widget>[];
      for (var position = start;
          position < start + 2 && position < visible;
          position++) {
        if (rowChildren.isNotEmpty) {
          rowChildren.add(const SizedBox(width: _albumGap));
        }
        final isLast = position == visible - 1;
        rowChildren.add(
          _tile(
            indices[position],
            width: cell,
            height: cell,
            moreCount: isLast && hidden > 0 ? hidden : 0,
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: _albumGap));
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: rowChildren));
    }

    return SizedBox(
      width: _albumWidth,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }

  Widget _tile(
    int index, {
    required double width,
    required double height,
    required int moreCount,
  }) {
    final attachment = attachments[index];
    return _MediaTile(
      attachment: attachment,
      fileToken: fileToken,
      width: width,
      height: height,
      moreCount: moreCount,
      onTap: () => onOpen(index),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.attachment,
    required this.fileToken,
    required this.width,
    required this.height,
    required this.moreCount,
    required this.onTap,
  });

  final Map<String, String> attachment;
  final String? fileToken;
  final double width;
  final double height;
  final int moreCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = attachmentName(attachment);
    final kind = mediaKindOf(attachment['mimetype'], name);
    final location = attachment['location'] ?? '';
    final preview = (attachment['locationPreview'] ?? '').isNotEmpty
        ? attachment['locationPreview']
        : (kind == MediaKind.image ? location : null);
    final url = appendFileToken(preview, fileToken);

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isEmpty)
                _placeholder(
                  context,
                  icon: kind == MediaKind.video
                      ? Icons.movie_outlined
                      : Icons.image_outlined,
                )
              else
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return _placeholder(context, loading: true);
                  },
                  errorBuilder: (context, error, stackTrace) {
                    return _placeholder(context, icon: Icons.broken_image_outlined);
                  },
                ),
              if (kind == MediaKind.video)
                const Center(
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.black45,
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                  ),
                ),
              if (moreCount > 0)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: Text(
                    '+$moreCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(
    BuildContext context, {
    IconData? icon,
    bool loading = false,
  }) {
    return ColoredBox(
      color: ChatUiScope.of(context).theme.bgSubtle,
      child: Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon ?? Icons.image_outlined, color: Colors.grey.shade500),
      ),
    );
  }
}
