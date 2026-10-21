import 'package:flutter/material.dart';

import '../../theme/chat_theme.dart';

/// Message composer: attach, text field, send. Shows an edit banner while a
/// message is being edited. Typing is reported through [onTyping].
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.textController,
    required this.onSubmit,
    this.onAttach,
    this.onTyping,
    this.hint,
    this.editingLabel,
    this.onCancelEdit,
    this.footer,
    this.focusNode,
  });

  final TextEditingController textController;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onAttach;
  final ValueChanged<bool>? onTyping;
  final String? hint;

  /// Non-null shows the edit banner with this label.
  final String? editingLabel;
  final VoidCallback? onCancelEdit;

  /// Extra row under the field (for example "Also send to room").
  final Widget? footer;
  final FocusNode? focusNode;

  void _submit() {
    final text = textController.text.trim();
    if (text.isEmpty) return;
    onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final theme = ui.theme;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: theme.bg,
          border: Border(top: BorderSide(color: theme.border)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (editingLabel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 0, 6),
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 16, color: theme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        editingLabel!,
                        style: TextStyle(
                          color: theme.primaryText,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: onCancelEdit,
                      icon: Icon(Icons.close, size: 18, color: theme.textMuted),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (onAttach != null)
                  IconButton(
                    tooltip: ui.strings.t('action.attachFile'),
                    onPressed: onAttach,
                    icon: Icon(Icons.attach_file_rounded, color: theme.icons),
                  ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.inputBackground,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: theme.border),
                    ),
                    child: TextField(
                      controller: textController,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (_) => onTyping?.call(true),
                      style: TextStyle(color: theme.text),
                      decoration: InputDecoration(
                        hintText: hint ?? ui.strings.t('input.placeholder'),
                        hintStyle: TextStyle(color: theme.textMuted),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: ui.strings.t('action.send'),
                  onPressed: _submit,
                  style: IconButton.styleFrom(
                    backgroundColor: theme.primary,
                    foregroundColor: theme.textOnPrimary,
                  ),
                  icon: Icon(editingLabel != null
                      ? Icons.check_rounded
                      : Icons.send_rounded),
                ),
              ],
            ),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}
