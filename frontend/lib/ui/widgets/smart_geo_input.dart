import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SmartGeoInput extends StatefulWidget
{
  final String label;
  final String? initialValue;
  final List<String> options;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onCreateRequested;

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

class _SmartGeoInputState extends State<SmartGeoInput>
{
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState()
  {
    super.initState();
    _ctrl.text = widget.initialValue ?? '';
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant SmartGeoInput aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    final value = widget.initialValue;
    if (value != null && value != aOldWidget.initialValue && value != _ctrl.text)
    {
      _ctrl.text = value;
    }
  }

  void _onFocusChanged()
  {
    if (_focus.hasFocus)
    {
      return;
    }

    final value = _ctrl.text.trim();
    if (value.isEmpty || value == widget.initialValue)
    {
      return;
    }

    final match = widget.options.where((aOption) => aOption.toLowerCase() == value.toLowerCase()).firstOrNull;
    if (match != null)
    {
      _ctrl.text = match;
      widget.onSelected(match);
    }
    else
    {
      widget.onCreateRequested(value);
    }
  }

  @override
  void dispose()
  {
    _focus.removeListener(_onFocusChanged);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return RawAutocomplete<String>(
      textEditingController: _ctrl,
      focusNode: _focus,
      optionsBuilder: (aValue)
      {
        final query = aValue.text.toLowerCase();
        return query.isEmpty
            ? widget.options
            : widget.options.where((aOption) => aOption.toLowerCase().contains(query));
      },
      onSelected: (aValue)
      {
        widget.onSelected(aValue);
        _focus.unfocus();
      },
      fieldViewBuilder: (_, aCtrl, aFocus, aOnSubmitted)
      {
        return TextField(
          controller: aCtrl,
          focusNode: aFocus,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: InputDecoration(labelText: widget.label, border: const OutlineInputBorder()),
          onSubmitted: (_) => aOnSubmitted(),
        );
      },
      optionsViewBuilder: (_, aOnSelected, aOptions)
      {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: aOptions.length,
                itemBuilder: (_, aIndex)
                {
                  final option = aOptions.elementAt(aIndex);
                  return ListTile(title: Text(option), onTap: () => aOnSelected(option));
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
