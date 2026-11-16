import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/light_plan.dart';

Future<List<String>?> showLightNumbers(
  BuildContext context, {
  required String title,
  required Map<String, String> fields,
  required String action,
  Future<void> Function(List<String>)? save,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) => _LightNumbersDialog(
    title: title,
    fields: fields,
    action: action,
    save: save,
  ),
);

class _LightNumbersDialog extends StatefulWidget {
  final String title;
  final Map<String, String> fields;
  final String action;
  final Future<void> Function(List<String>)? save;

  const _LightNumbersDialog({
    required this.title,
    required this.fields,
    required this.action,
    this.save,
  });

  @override
  State<_LightNumbersDialog> createState() => _LightNumbersDialogState();
}

class _LightNumbersDialogState extends State<_LightNumbersDialog> {
  final form = GlobalKey<FormState>();
  late final controllers = [
    for (final value in widget.fields.values)
      TextEditingController(text: value),
  ];
  bool busy = false;
  String? error;

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    final numbers = [for (final controller in controllers) controller.text];
    if (widget.save != null) {
      setState(() {
        busy = true;
        error = null;
      });
      try {
        await widget.save!(numbers);
      } catch (failure) {
        if (mounted) {
          setState(() {
            busy = false;
            error = switch (failure) {
              StateError() => failure.message,
              FormatException() => failure.message,
              _ => 'Could not save the record number. Try again.',
            };
          });
        }
        return;
      }
    }
    if (mounted) Navigator.pop(context, numbers);
  }

  Widget field(int index) => TextFormField(
    controller: controllers[index],
    autofocus: controllers.length == 1,
    enabled: !busy,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    maxLength: lightNumberMaxLength,
    textInputAction: index == controllers.length - 1
        ? TextInputAction.done
        : TextInputAction.next,
    onFieldSubmitted: index == controllers.length - 1 ? (_) => submit() : null,
    decoration: InputDecoration(
      labelText: widget.fields.keys.elementAt(index),
      counterText: '',
    ),
    validator: (text) =>
        parseLightNumber(text) == null ? 'Enter digits only.' : null,
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SizedBox(
        width: controllers.length == 1 ? 320 : 600,
        child: LayoutBuilder(
          builder: (context, bounds) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bounds.maxHeight >= 145)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Form(
                    key: form,
                    child: LayoutBuilder(
                      builder: (context, content) {
                        final count = controllers.length;
                        final width = content.maxWidth >= count * 176
                            ? (content.maxWidth - (count - 1) * 12) / count
                            : content.maxWidth;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (var i = 0; i < count; i++)
                              SizedBox(width: width, child: field(i)),
                            if (error != null)
                              Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(widget.action),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
