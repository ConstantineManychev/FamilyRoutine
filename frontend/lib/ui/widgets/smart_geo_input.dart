import 'package:flutter/material.dart';

class SmartGeoInput extends StatefulWidget {
  final String label;
  final String? initialValue;
  final List<String> options;
  final void Function(String) onSelected;
  final void Function(String) onCreateRequested;

  const SmartGeoInput({
    super.key,
    required this.label,
    this.initialValue,
    required this.options,
    required this.onSelected,
    required this.onCreateRequested,
  });

  @override
  State<SmartGeoInput> createState() => _SmartGeoInputState();
}

class _SmartGeoInputState extends State<SmartGeoInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.initialValue != null) _ctrl.text = widget.initialValue!;
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant SmartGeoInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != null && widget.initialValue != _ctrl.text) {
      _ctrl.text = widget.initialValue!;
    }
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) {
      final val = _ctrl.text.trim();
      if (val.isEmpty) return;
      
      final match = widget.options.where((e) => e.toLowerCase() == val.toLowerCase()).firstOrNull;
      if (match != null) {
        widget.onSelected(match);
        _ctrl.text = match;
      } else {
        widget.onCreateRequested(val);
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: _ctrl,
      focusNode: _focus,
      optionsBuilder: (val) {
        if (val.text.isEmpty) return widget.options;
        return widget.options.where((e) => e.toLowerCase().contains(val.text.toLowerCase()));
      },
      onSelected: (val) {
        widget.onSelected(val);
        _focus.unfocus();
      },
      fieldViewBuilder: (ctx, ctrl, focus, onFieldSubmitted) {
        return TextField(
          controller: ctrl,
          focusNode: focus,
          decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (ctx, onSelected, opts) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: SizedBox(
              height: 200,
              width: 300,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: opts.length,
                itemBuilder: (ctx, i) {
                  final opt = opts.elementAt(i);
                  return ListTile(title: Text(opt), onTap: () => onSelected(opt));
                },
              ),
            ),
          ),
        );
      },
    );
  }
}