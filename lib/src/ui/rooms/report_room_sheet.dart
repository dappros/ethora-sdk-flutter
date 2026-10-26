import 'package:flutter/material.dart';

import 'room_ui.dart';

/// One report reason. [id] is what the API gets as `category` (a contract,
/// not UI text, so it stays English in every language); [labelKey] is the
/// caption.
class ReportCategory {
  const ReportCategory(this.id, this.labelKey);
  final String id;
  final String labelKey;
}

const List<ReportCategory> kReportCategories = <ReportCategory>[
  ReportCategory('Spam', 'report.category.spam'),
  ReportCategory('Violence', 'report.category.violence'),
  ReportCategory('Child Abuse', 'report.category.childAbuse'),
  ReportCategory('Pornography', 'report.category.pornography'),
  ReportCategory('Personal Details', 'report.category.personalDetails'),
  ReportCategory('Illegal Drugs', 'report.category.illegalDrugs'),
  ReportCategory('Other', 'report.category.other'),
];

/// What the reader chose in the report sheet.
class ReportRoomResult {
  const ReportRoomResult({required this.category, required this.text});
  final String category;
  final String text;
}

/// True when a report with this category and text may be sent: a category is
/// chosen, and "Other" also needs details.
bool canSubmitReport(String? category, String text) {
  if (category == null || category.isEmpty) return false;
  if (category == 'Other') return text.trim().isNotEmpty;
  return true;
}

/// The report sheet of a chat. Resolves with the choice, or null when
/// dismissed.
Future<ReportRoomResult?> showReportRoomSheet(
  BuildContext context, {
  required String roomTitle,
}) {
  return showChatSheet<ReportRoomResult>(
    context,
    builder: (_) => _ReportRoomSheet(roomTitle: roomTitle),
  );
}

class _ReportRoomSheet extends StatefulWidget {
  const _ReportRoomSheet({required this.roomTitle});

  final String roomTitle;

  @override
  State<_ReportRoomSheet> createState() => _ReportRoomSheetState();
}

class _ReportRoomSheetState extends State<_ReportRoomSheet> {
  final TextEditingController _text = TextEditingController();
  String? _category;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final ready = canSubmitReport(_category, _text.text);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChatSheetTitleBar(title: strings.t('modal.report.chatTitle')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.roomTitle,
                style: TextStyle(color: theme.textSecondary),
              ),
            ),
            for (final category in kReportCategories)
              ListTile(
                dense: true,
                selected: _category == category.id,
                selectedColor: theme.primaryText,
                leading: Icon(
                  _category == category.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: _category == category.id
                      ? theme.primary
                      : theme.textMuted,
                ),
                title: Text(
                  strings.t(category.labelKey),
                  style: TextStyle(color: theme.text),
                ),
                onTap: () => setState(() => _category = category.id),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _text,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: strings.t('modal.report.otherDetails'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: ready
                      ? () => Navigator.of(context).pop(
                            ReportRoomResult(
                              category: _category!,
                              text: _text.text.trim(),
                            ),
                          )
                      : null,
                  child: Text(strings.t('action.submit')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
