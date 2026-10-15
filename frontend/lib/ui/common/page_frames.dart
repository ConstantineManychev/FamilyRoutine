import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/route_guard.dart';
import 'app_icons.dart';
import 'app_theme.dart';

const double contentMaxWidth = 1100;
const double fabClearance = 88;

EdgeInsets tabPadding(BuildContext aContext)
{
  final width = MediaQuery.sizeOf(aContext).width;
  final side = math.max(width < 600 ? 12.0 : 24.0, (width - contentMaxWidth) / 2);
  return EdgeInsets.fromLTRB(side, 16, side, fabClearance);
}

void closePage(BuildContext aContext)
{
  if (aContext.canPop())
  {
    aContext.pop();
  }
  else
  {
    aContext.go(homePath);
  }
}

double dialogListHeight(BuildContext aContext, double aPreferred)
{
  final media = MediaQuery.of(aContext);
  final available = media.size.height - media.viewInsets.bottom - media.padding.vertical - 220;
  return math.max(160.0, math.min(aPreferred, available));
}

void finishPage(BuildContext aContext, String aFallback)
{
  if (aContext.canPop())
  {
    aContext.pop(true);
  }
  else
  {
    aContext.go(aFallback);
  }
}

class ClosePageButton extends StatelessWidget
{
  const ClosePageButton({super.key});

  @override
  Widget build(BuildContext aContext)
  {
    return IconButton(
      tooltip: 'common.close'.tr(),
      icon: const Icon(AppIcons.x),
      onPressed: () => closePage(aContext),
    );
  }
}

class SubPage extends StatelessWidget
{
  final Widget child;
  final String? title;
  final List<Widget> actions;

  const SubPage({super.key, required this.child, this.title, this.actions = const []});

  @override
  Widget build(BuildContext aContext)
  {
    return Scaffold(
      appBar: AppBar(
        leading: const ClosePageButton(),
        title: title == null ? null : Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis),
        titleSpacing: 0,
        actions: actions,
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}

class ListPage extends StatefulWidget
{
  final String title;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final ValueChanged<String>? onSearch;
  final String? initialQuery;
  final String? searchHint;
  final List<Widget> actions;
  final Widget? child;
  final Widget Function(BuildContext aContext, String aQuery)? builder;

  const ListPage({
    super.key,
    required this.title,
    this.child,
    this.builder,
    this.onAdd,
    this.addTooltip,
    this.onSearch,
    this.initialQuery,
    this.searchHint,
    this.actions = const [],
  });

  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage>
{
  late final _searchCtrl = TextEditingController(text: widget.initialQuery ?? '');
  final _searchFocus = FocusNode();
  late bool _isSearching = (widget.initialQuery ?? '').isNotEmpty;
  late String _query = widget.initialQuery ?? '';

  void _changeQuery(String aQuery)
  {
    widget.onSearch?.call(aQuery);
    if (widget.builder != null)
    {
      setState(() => _query = aQuery.trim().toLowerCase());
    }
  }

  @override
  void dispose()
  {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch()
  {
    setState(() => _isSearching = !_isSearching);
    if (_isSearching)
    {
      _searchFocus.requestFocus();
    }
    else if (_searchCtrl.text.isNotEmpty)
    {
      _searchCtrl.clear();
      _changeQuery('');
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isSearchable = widget.onSearch != null || widget.builder != null;

    return Scaffold(
      appBar: AppBar(
        leading: const ClosePageButton(),
        titleSpacing: 0,
        title: Row(
          children: [
            Flexible(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (widget.onAdd != null)
              IconButton(
                tooltip: widget.addTooltip ?? 'common.add'.tr(),
                icon: const Icon(AppIcons.plus),
                onPressed: widget.onAdd,
              ),
          ],
        ),
        actions: [
          ...widget.actions,
          if (isSearchable)
            IconButton(
              tooltip: _isSearching ? 'common.close_search'.tr() : 'common.search'.tr(),
              icon: Icon(_isSearching ? AppIcons.x : AppIcons.search),
              onPressed: _toggleSearch,
            ),
          const SizedBox(width: 4),
        ],
        bottom: !isSearchable || !_isSearching
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(60),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Semantics(
                    container: true,
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      textInputAction: TextInputAction.search,
                      inputFormatters: [LengthLimitingTextInputFormatter(100)],
                      onChanged: _changeQuery,
                      decoration: InputDecoration(
                        hintText: widget.searchHint ?? 'common.search'.tr(),
                        prefixIcon: const Icon(AppIcons.search, size: 18),
                        isDense: true,
                        filled: true,
                        fillColor: aContext.palette.surfaceMuted,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: SafeArea(top: false, child: widget.builder?.call(aContext, _query) ?? widget.child ?? const SizedBox.shrink()),
    );
  }
}

class BlockCard extends StatelessWidget
{
  final String title;
  final VoidCallback? onAdd;
  final String? addTooltip;
  final VoidCallback? onExpand;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const BlockCard({
    super.key,
    required this.title,
    required this.child,
    this.onAdd,
    this.addTooltip,
    this.onExpand,
    this.padding = const EdgeInsets.fromLTRB(4, 4, 4, 8),
  });

  @override
  Widget build(BuildContext aContext)
  {
    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (onAdd != null)
                  IconButton(
                    tooltip: addTooltip ?? 'common.add'.tr(),
                    icon: Icon(AppIcons.plus, color: aContext.colors.primary),
                    onPressed: onAdd,
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: aContext.palette.inkPrimary),
                  ),
                ),
                if (onExpand != null)
                  IconButton(
                    tooltip: 'common.show_all'.tr(),
                    icon: const Icon(AppIcons.chevronRight),
                    onPressed: onExpand,
                  ),
              ],
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class BlockEmpty extends StatelessWidget
{
  final String text;

  const BlockEmpty(this.text, {super.key});

  @override
  Widget build(BuildContext aContext)
  {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(text, style: TextStyle(color: aContext.palette.inkMuted)),
    );
  }
}
