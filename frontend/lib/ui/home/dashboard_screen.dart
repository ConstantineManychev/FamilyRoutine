import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../finance/cashflow_card.dart';
import '../routine/dash_card.dart';
import '../routine/family_list_card.dart';
import '../routine/family_timeline_card.dart';
import '../routine/my_status_card.dart';

const String _selectedPref = 'dashboard.selected';

enum _WidgetAction { moveUp, moveDown, remove }

class _WidgetSpec
{
  final String? id;
  final WidgetKind kind;
  final String? familyId;
  final String? familyName;
  final bool isAvailable;

  const _WidgetSpec({this.id, required this.kind, this.familyId, this.familyName, this.isAvailable = true});

  factory _WidgetSpec.from(WidgetDto aWidget) => _WidgetSpec(
        id: aWidget.id,
        kind: aWidget.kind,
        familyId: aWidget.familyId,
        familyName: aWidget.familyName,
        isAvailable: aWidget.isAvailable,
      );

  String get key => id ?? '${kind.wire}:${familyId ?? ''}';

  bool sameAs(WidgetDto aWidget) => aWidget.kind == kind && aWidget.familyId == familyId;
}

class _NewWidget
{
  final WidgetKind kind;
  final String? familyId;

  const _NewWidget(this.kind, this.familyId);
}

class DashboardScreen extends ConsumerStatefulWidget
{
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
{
  List<DashboardDto>? _dashboards;
  String? _selectedId;
  Object? _error;
  bool _isBusy = false;

  DashboardDto? get _selected
  {
    final dashboards = _dashboards ?? const <DashboardDto>[];
    for (final dashboard in dashboards)
    {
      if (dashboard.id == _selectedId)
      {
        return dashboard;
      }
    }
    return dashboards.firstOrNull;
  }

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<SharedPreferences?> _prefs() async
  {
    try
    {
      return await SharedPreferences.getInstance();
    }
    on Exception
    {
      return null;
    }
  }

  Future<void> _load() async
  {
    try
    {
      final dashboards = await ref.read(apiProv).getDashboards();
      final prefs = await _prefs();
      if (!mounted)
      {
        return;
      }
      setState(()
      {
        _dashboards = dashboards;
        _selectedId = prefs?.getString(_selectedPref);
        _error = null;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  Future<void> _select(String aId) async
  {
    if (mounted)
    {
      setState(() => _selectedId = aId);
    }
    final prefs = await _prefs();
    await prefs?.setString(_selectedPref, aId);
  }

  void _replace(DashboardDto aDashboard)
  {
    if (!mounted)
    {
      return;
    }
    final dashboards = [...?_dashboards];
    final index = dashboards.indexWhere((aItem) => aItem.id == aDashboard.id);
    if (index < 0)
    {
      dashboards.add(aDashboard);
    }
    else
    {
      dashboards[index] = aDashboard;
    }
    setState(() => _dashboards = dashboards);
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<DashboardDto> _ensureDashboard() async
  {
    final selected = _selected;
    if (selected != null)
    {
      return selected;
    }
    final created = await ref.read(apiProv).createDashboard('dashboard.default_name'.tr(), aIsPrefilled: true);
    _replace(created);
    await _select(created.id);
    return created;
  }

  List<_WidgetSpec> _specs(DashboardDto? aDashboard, List<FamDto> aFams)
  {
    if (aDashboard != null)
    {
      return aDashboard.widgets.map(_WidgetSpec.from).toList();
    }
    return [
      const _WidgetSpec(kind: WidgetKind.myStatus),
      ...aFams.map((aFam) => _WidgetSpec(kind: WidgetKind.familyTimeline, familyId: aFam.id, familyName: aFam.name)),
      const _WidgetSpec(kind: WidgetKind.cashflow),
    ];
  }

  Future<void> _addWidget(List<_WidgetSpec> aCurrent) async
  {
    final fams = ref.read(famsProv).valueOrNull ?? const <FamDto>[];
    final shown = aCurrent.where((aSpec) => aSpec.familyId != null).map((aSpec) => aSpec.familyId!).toSet();
    final choice = await showDialog<_NewWidget>(
      context: context,
      builder: (_) => _AddWidgetDialog(fams: fams, shownFamilyIds: shown),
    );
    if (choice == null)
    {
      return;
    }

    await _run(() async
    {
      final dashboard = await _ensureDashboard();
      final updated = await ref.read(apiProv).addWidget(dashboard.id, choice.kind, aFamilyId: choice.familyId);
      _replace(updated);
    });
  }

  Future<void> _onWidgetAction(_WidgetSpec aSpec, _WidgetAction aAction) async
  {
    await _run(() async
    {
      final api = ref.read(apiProv);
      final dashboard = await _ensureDashboard();
      final widgets = [...dashboard.widgets];
      final index = widgets.indexWhere((aWidget) => aWidget.id == aSpec.id || (aSpec.id == null && aSpec.sameAs(aWidget)));
      if (index < 0)
      {
        return;
      }

      switch (aAction)
      {
        case _WidgetAction.remove:
          await api.deleteWidget(dashboard.id, widgets[index].id);
          widgets.removeAt(index);
          _replace(DashboardDto(id: dashboard.id, name: dashboard.name, widgets: widgets));
        case _WidgetAction.moveUp:
        case _WidgetAction.moveDown:
          final target = index + (aAction == _WidgetAction.moveUp ? -1 : 1);
          if (target < 0 || target >= widgets.length)
          {
            return;
          }
          final moved = widgets.removeAt(index);
          widgets.insert(target, moved);
          _replace(DashboardDto(id: dashboard.id, name: dashboard.name, widgets: widgets));
          _replace(await api.reorderWidgets(dashboard.id, widgets.map((aWidget) => aWidget.id).toList()));
      }
    });
  }

  Future<void> _createDashboard() async
  {
    final draft = await showDialog<(String, bool)>(context: context, builder: (_) => const _DashboardNameDialog());
    if (draft == null)
    {
      return;
    }
    await _run(() async
    {
      if (_selected == null && (_dashboards ?? const []).isEmpty)
      {
        await _ensureDashboard();
      }
      final created = await ref.read(apiProv).createDashboard(draft.$1, aIsPrefilled: draft.$2);
      _replace(created);
      await _select(created.id);
    });
  }

  Future<void> _renameDashboard(DashboardDto aDashboard) async
  {
    final draft = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _DashboardNameDialog(initialName: aDashboard.name),
    );
    if (draft == null)
    {
      return;
    }
    await _run(() async => _replace(await ref.read(apiProv).renameDashboard(aDashboard.id, draft.$1)));
  }

  Future<void> _deleteDashboard(DashboardDto aDashboard) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'dashboard.delete_title'.tr(),
      aMessage: 'dashboard.delete_confirm'.tr(args: [aDashboard.name]),
    );
    if (!isConfirmed)
    {
      return;
    }
    await _run(() async
    {
      await ref.read(apiProv).deleteDashboard(aDashboard.id);
      if (mounted)
      {
        setState(() => _dashboards = [...?_dashboards]..removeWhere((aItem) => aItem.id == aDashboard.id));
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final user = ref.watch(authProv.select((aState) => aState.user));
    final fams = ref.watch(famsProv).valueOrNull ?? const <FamDto>[];
    final dashboards = _dashboards;

    return SingleChildScrollView(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${'dashboard.welcome'.tr()}, ${user?.fName ?? ''}!',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: inkPrimary),
          ),
          const SizedBox(height: 24),
          if (dashboards == null)
            _error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : const Center(child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()))
          else
            ..._buildDashboard(aContext, dashboards, fams),
        ],
      ),
    );
  }

  List<Widget> _buildDashboard(BuildContext aContext, List<DashboardDto> aDashboards, List<FamDto> aFams)
  {
    final selected = _selected;
    final specs = _specs(selected, aFams);

    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (aDashboards.isEmpty)
            ChoiceChip(
              showCheckmark: false,
              avatar: const Icon(AppIcons.layoutDashboard, size: 16),
              label: Text('dashboard.default_name'.tr()),
              selected: true,
              onSelected: (_) {},
            ),
          for (final dashboard in aDashboards)
            ChoiceChip(
              showCheckmark: false,
              avatar: const Icon(AppIcons.layoutDashboard, size: 16),
              label: Text(dashboard.name),
              selected: dashboard.id == selected?.id,
              onSelected: (_) => _select(dashboard.id),
            ),
          IconButton(
            tooltip: 'dashboard.new_dashboard'.tr(),
            onPressed: _isBusy ? null : _createDashboard,
            icon: const Icon(AppIcons.plus, size: 18),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _isBusy ? null : () => _addWidget(specs),
            icon: const Icon(AppIcons.plusCircle, size: 18),
            label: Text('dashboard.add_widget'.tr()),
          ),
          if (selected != null)
            PopupMenuButton<bool>(
              tooltip: 'common.actions'.tr(),
              icon: const Icon(AppIcons.moreVertical, size: 18),
              onSelected: (aIsDelete) => aIsDelete ? _deleteDashboard(selected) : _renameDashboard(selected),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: false,
                  child: ListTile(leading: const Icon(AppIcons.pencil, size: 18), title: Text('dashboard.rename'.tr())),
                ),
                PopupMenuItem(
                  value: true,
                  child: ListTile(leading: const Icon(AppIcons.trash2, size: 18), title: Text('dashboard.delete_title'.tr())),
                ),
              ],
            ),
          if (_isBusy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
      const SizedBox(height: 24),
      if (specs.isEmpty)
        DashCard(
          title: Text('dashboard.empty_title'.tr()),
          child: Text('dashboard.empty_hint'.tr(), style: const TextStyle(color: inkMuted)),
        ),
      for (var index = 0; index < specs.length; index++) ...[
        KeyedSubtree(
          key: ValueKey(specs[index].key),
          child: _buildWidget(specs[index], _buildMenu(specs[index], index, specs.length)),
        ),
        const SizedBox(height: 24),
      ],
    ];
  }

  Widget _buildMenu(_WidgetSpec aSpec, int aIndex, int aCount)
  {
    return PopupMenuButton<_WidgetAction>(
      tooltip: 'common.actions'.tr(),
      icon: const Icon(AppIcons.moreVertical, size: 18),
      enabled: !_isBusy,
      onSelected: (aAction) => _onWidgetAction(aSpec, aAction),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _WidgetAction.moveUp,
          enabled: aIndex > 0,
          child: ListTile(leading: const Icon(AppIcons.arrowUp, size: 18), title: Text('dashboard.move_up'.tr())),
        ),
        PopupMenuItem(
          value: _WidgetAction.moveDown,
          enabled: aIndex < aCount - 1,
          child: ListTile(leading: const Icon(AppIcons.arrowDown, size: 18), title: Text('dashboard.move_down'.tr())),
        ),
        PopupMenuItem(
          value: _WidgetAction.remove,
          child: ListTile(leading: const Icon(AppIcons.x, size: 18), title: Text('dashboard.remove_widget'.tr())),
        ),
      ],
    );
  }

  Widget _buildWidget(_WidgetSpec aSpec, Widget aMenu)
  {
    if (!aSpec.isAvailable)
    {
      return DashCard(
        title: Text('dashboard.unavailable_title'.tr()),
        menu: aMenu,
        child: Text('dashboard.unavailable_hint'.tr(), style: const TextStyle(color: inkMuted)),
      );
    }

    return switch (aSpec.kind)
    {
      WidgetKind.myStatus => MyStatusCard(menu: aMenu),
      WidgetKind.familyTimeline => FamilyTimelineCard(familyId: aSpec.familyId, title: aSpec.familyName, menu: aMenu),
      WidgetKind.cashflow => CashflowCard(menu: aMenu),
      WidgetKind.familyList => FamilyListCard(menu: aMenu),
    };
  }
}

class _AddWidgetDialog extends StatefulWidget
{
  final List<FamDto> fams;
  final Set<String> shownFamilyIds;

  const _AddWidgetDialog({required this.fams, required this.shownFamilyIds});

  @override
  State<_AddWidgetDialog> createState() => _AddWidgetDialogState();
}

class _AddWidgetDialogState extends State<_AddWidgetDialog>
{
  WidgetKind _kind = WidgetKind.familyTimeline;
  String? _familyId;

  @override
  void initState()
  {
    super.initState();
    _familyId = widget.fams.where((aFam) => !widget.shownFamilyIds.contains(aFam.id)).firstOrNull?.id ?? widget.fams.firstOrNull?.id;
    if (widget.fams.isEmpty)
    {
      _kind = WidgetKind.myStatus;
    }
  }

  IconData _icon(WidgetKind aKind) => switch (aKind)
  {
    WidgetKind.myStatus => AppIcons.circleDot,
    WidgetKind.familyTimeline => AppIcons.calendarClock,
    WidgetKind.cashflow => AppIcons.chartColumn,
    WidgetKind.familyList => AppIcons.users,
  };

  @override
  Widget build(BuildContext aContext)
  {
    final canSave = _kind != WidgetKind.familyTimeline || _familyId != null;

    return AlertDialog(
      title: Text('dashboard.add_widget'.tr()),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<WidgetKind>(
              groupValue: _kind,
              onChanged: (aValue) => setState(() => _kind = aValue ?? _kind),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final kind in WidgetKind.values)
                    RadioListTile<WidgetKind>(
                      value: kind,
                      enabled: kind != WidgetKind.familyTimeline || widget.fams.isNotEmpty,
                      secondary: Icon(_icon(kind)),
                      title: Text('dashboard.widget_${kind.wire}'.tr()),
                      subtitle: Text('dashboard.widget_${kind.wire}_hint'.tr()),
                    ),
                ],
              ),
            ),
            if (_kind == WidgetKind.familyTimeline) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _familyId,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'dashboard.family'.tr(), border: const OutlineInputBorder()),
                items: widget.fams
                    .map((aFam) => DropdownMenuItem(
                          value: aFam.id,
                          child: Text(
                            widget.shownFamilyIds.contains(aFam.id) ? '${aFam.name} ✓' : aFam.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: (aValue) => setState(() => _familyId = aValue),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: canSave
              ? () => Navigator.of(aContext).pop(
                    _NewWidget(_kind, _kind == WidgetKind.familyTimeline ? _familyId : null),
                  )
              : null,
          child: Text('dashboard.add'.tr()),
        ),
      ],
    );
  }
}

class _DashboardNameDialog extends StatefulWidget
{
  final String? initialName;

  const _DashboardNameDialog({this.initialName});

  @override
  State<_DashboardNameDialog> createState() => _DashboardNameDialogState();
}

class _DashboardNameDialogState extends State<_DashboardNameDialog>
{
  late final TextEditingController _nameCtrl = TextEditingController(text: widget.initialName ?? '');
  bool _isPrefilled = true;

  bool get _isNew => widget.initialName == null;

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit()
  {
    final name = _nameCtrl.text.trim();
    if (name.isNotEmpty)
    {
      Navigator.of(context).pop((name, _isNew && _isPrefilled));
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text(_isNew ? 'dashboard.new_dashboard'.tr() : 'dashboard.rename'.tr()),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              inputFormatters: [LengthLimitingTextInputFormatter(100)],
              decoration: InputDecoration(labelText: 'dashboard.name'.tr(), border: const OutlineInputBorder()),
              onSubmitted: (_) => _submit(),
            ),
            if (_isNew)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _isPrefilled,
                onChanged: (aValue) => setState(() => _isPrefilled = aValue ?? false),
                title: Text('dashboard.prefill'.tr()),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _submit, child: Text('common.save'.tr())),
      ],
    );
  }
}
