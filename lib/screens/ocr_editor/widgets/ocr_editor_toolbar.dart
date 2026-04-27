import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/scan_document.dart';
import '../ocr_editor_notifier.dart';
import '../ocr_editor_state.dart';

class OcrEditorToolbar extends ConsumerWidget {
  final ScanDocument document;

  const OcrEditorToolbar({
    super.key,
    required this.document,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ocrEditorStateProvider(document));
    final controller = ref.read(ocrEditorControllerProvider(document));

    if (!state.boxEditMode) return const SizedBox.shrink();

    return Card(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionButton(
              icon: Icons.open_with,
              label: 'Verschieben',
              isActive: state.activeFabMode == FabMode.move,
              onPressed: () => controller.setFabMode(FabMode.move),
            ),
            _ActionButton(
              icon: Icons.zoom_out_map,
              label: 'Skalieren',
              isActive: state.activeFabMode == FabMode.scale,
              onPressed: () => controller.setFabMode(FabMode.scale),
            ),
            _ActionButton(
              icon: Icons.text_fields,
              label: 'Text',
              onPressed: () => _showEditDialog(context, ref, controller, state),
            ),
            _ActionButton(
              icon: Icons.delete,
              label: 'Löschen',
              onPressed: controller.deleteSelectedElement,
            ),
            const Divider(height: 24),
            _ActionButton(
              icon: Icons.close,
              label: 'Abbrechen',
              onPressed: controller.exitBoxEditModeCancel,
            ),
            _ActionButton(
              icon: Icons.check,
              label: 'Fertig',
              color: Colors.green,
              onPressed: controller.exitBoxEditModeOk,
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, OcrEditorController controller, OcrEditorState state) {
    final sel = state.selection;
    if (sel == null) return;
    
    final block = state.textBlocks[sel.pageIdx][sel.blockIdx];
    final elem = block.lines[sel.lineIdx].elements[sel.elemIdx];
    
    final textController = TextEditingController(text: elem.text);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Text bearbeiten'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Erkannter Text'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton(
            onPressed: () {
              controller.updateElementText(textController.text);
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool isActive;
  final Color? color;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isActive = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = color ?? theme.colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: isActive ? activeColor.withValues(alpha: 0.15) : null,
            borderRadius: BorderRadius.circular(12),
            border: isActive ? Border.all(color: activeColor.withValues(alpha: 0.3)) : null,
          ),
          child: IconButton(
            icon: Icon(icon),
            color: isActive ? activeColor : theme.colorScheme.onSurfaceVariant,
            onPressed: onPressed,
            tooltip: label,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive ? activeColor : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
