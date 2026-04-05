import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class PlacesScreen extends ConsumerStatefulWidget {
  const PlacesScreen({super.key});

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  List<PlaceDto> _places = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    setState(() => _isLoading = true);
    try {
      final places = await ref.read(apiProv).getPlaces();
      if (mounted) setState(() => _places = places);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('sidebar.places'.tr()),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            onPressed: () => context.go('/app/places/new'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _places.isEmpty
              ? Center(child: Text('common.no_data'.tr()))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _places.length,
                  itemBuilder: (context, index) {
                    final place = _places[index];
                    final mainAddr = place.addrs.where((a) => a.isMain).firstOrNull;
                    
                    String subtitleText = 'places.no_address'.tr();
                    if (mainAddr != null) {
                      subtitleText = '${mainAddr.zip}, ${'places.house'.tr()} ${mainAddr.houseNum}';
                      if (mainAddr.apt != null && mainAddr.apt!.isNotEmpty) {
                        subtitleText += ', ${'places.apt'.tr()} ${mainAddr.apt}';
                      }
                    }

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(LucideIcons.mapPin, color: Colors.blue),
                        title: Text(place.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(subtitleText),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () {
                          context.go('/app/places/${place.id}');
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.go('/app/places/new'),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }
}