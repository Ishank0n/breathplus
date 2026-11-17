
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GardenFlower {
  final String id;
  final String name;
  final String emoji;

  const GardenFlower({
    required this.id,
    required this.name,
    required this.emoji,
  });
}

class GardenPage extends StatefulWidget {
  const GardenPage({super.key});

  @override
  State<GardenPage> createState() => _GardenPageState();
}

class _GardenPageState extends State<GardenPage> {
  static const String _gardenKey = 'breathling_garden';
  static const String _activeFlowerKey = 'breathling_active_flower';

  // Temporary flower collection. We'll replace emojis with artwork later.
  static const List<GardenFlower> flowers = [
    GardenFlower(id: 'rose', name: 'Rose', emoji: '🌹'),
    GardenFlower(id: 'sunflower', name: 'Sunflower', emoji: '🌻'),
    GardenFlower(id: 'tulip', name: 'Tulip', emoji: '🌷'),
    GardenFlower(id: 'daisy', name: 'Daisy', emoji: '🌼'),
    GardenFlower(id: 'cherry', name: 'Cherry Blossom', emoji: '🌸'),
    GardenFlower(id: 'lavender', name: 'Lavender', emoji: '🪻'),
    GardenFlower(id: 'hibiscus', name: 'Hibiscus', emoji: '🌺'),
    GardenFlower(id: 'blossom', name: 'Blossom', emoji: '💮'),
    GardenFlower(id: 'lotus', name: 'Lotus', emoji: '🪷'),
  ];

  // Slot number -> selected flower.
  final Map<int, GardenFlower> _selectedFlowers = {};

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGarden();
  }

  Future<void> _loadGarden() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_gardenKey);

    if (saved != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(saved);

        for (final entry in data.entries) {
          final flower = flowers.cast<GardenFlower?>().firstWhere(
                (f) => f?.id == entry.value,
                orElse: () => null,
              );

          if (flower != null) {
            _selectedFlowers[int.parse(entry.key)] = flower;
          }
        }
      } catch (e) {
        debugPrint('Could not load garden: $e');
      }
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveGarden() async {
    final prefs = await SharedPreferences.getInstance();

    final data = _selectedFlowers.map(
      (slot, flower) => MapEntry(slot.toString(), flower.id),
    );

    await prefs.setString(_gardenKey, jsonEncode(data));
  }

  Future<void> _selectFlower(int slot, GardenFlower flower) async {
    setState(() {
      _selectedFlowers[slot] = flower;
    });

    final prefs = await SharedPreferences.getInstance();

    await _saveGarden();

    // The breathing session can retrieve this flower later.
    await prefs.setString(
      _activeFlowerKey,
      jsonEncode({
        'id': flower.id,
        'name': flower.name,
        'emoji': flower.emoji,
        'slot': slot,
      }),
    );
  }

  Future<void> _removeFlower(int slot) async {
    setState(() {
      _selectedFlowers.remove(slot);
    });

    await _saveGarden();
  }

  void _openFlowerSelector(int slot) {
    final existingFlower = _selectedFlowers[slot];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
          decoration: const BoxDecoration(
            color: Color(0xFF183D2B),
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(28),
            ),
            border: Border(
              top: BorderSide(
                color: Color(0xFF477454),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF71947A),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

                const SizedBox(height: 22),

                Text(
                  'Choose your flower',
                  style: const TextStyle(
                    fontFamily: 'Georgia',
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF3F7F2),
                  ),
                ),

                const SizedBox(height: 7),

                Text(
                  'Choose a flower to grow in pot ${slot + 1}',
                  style: const TextStyle(
                    color: Color(0xFFA6DDB8),
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 24),

                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: flowers.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.05,
                  ),
                  itemBuilder: (context, index) {
                    final flower = flowers[index];
                    final selected = existingFlower?.id == flower.id;

                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        _selectFlower(slot, flower);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF315B40)
                              : const Color(0xFF214A34),
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF8FE3A5)
                                : const Color(0xFF3E684B),
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              flower.emoji,
                              style: const TextStyle(fontSize: 34),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              flower.name,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFF3F7F2),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                if (existingFlower != null) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _removeFlower(slot);
                    },
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFD98B5F),
                    ),
                    label: const Text(
                      'Remove flower from this pot',
                      style: TextStyle(
                        color: Color(0xFFD98B5F),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // Coordinates are percentages of the background image.
  // Three columns x three rows.
  static const List<Offset> _potPositions = [
    Offset(0.211, 0.300),
    Offset(0.500, 0.300),
    Offset(0.789, 0.300),

    Offset(0.211, 0.508),
    Offset(0.500, 0.508),
    Offset(0.789, 0.508),

    Offset(0.211, 0.713),
    Offset(0.500, 0.713),
    Offset(0.789, 0.713),
  ];

  Widget _buildPot(int index, double width, double height) {
    final flower = _selectedFlowers[index];

    return Positioned(
      left: width * _potPositions[index].dx - width * 0.105,
      top: height * _potPositions[index].dy - height * 0.055,
      width: width * 0.21,
      height: height * 0.11,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openFlowerSelector(index),
        child: AnimatedScale(
          scale: 1,
          duration: const Duration(milliseconds: 200),
          child: Center(
            child: flower == null
                ? const SizedBox.expand()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        flower.emoji,
                        style: TextStyle(
                          fontSize: width * 0.105,
                          shadows: const [
                            Shadow(
                              color: Colors.black45,
                              blurRadius: 5,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        flower.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFE7C4),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(
                              color: Colors.black87,
                              blurRadius: 4,
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Barn garden background.
            Image.asset(
              'assets/images/garden-wall.png',
              fit: BoxFit.fill,
              errorBuilder: (_, error, stack) {
                return Container(
                  color: const Color(0xFF58351F),
                  alignment: Alignment.center,
                  child: const Text(
                    'Garden background not found',
                    style: TextStyle(color: Colors.white),
                  ),
                );
              },
            ),

            // Garden title.
            Positioned(
              top: height * 0.035,
              left: 0,
              right: 0,
              child: const Text(
                'My Garden',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 27,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFFE9C8),
                  shadows: [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 7,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),

            // Nine interactive pot areas.
            for (int i = 0; i < 9; i++)
              _buildPot(i, width, height),

            if (_loading)
              const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF8FE3A5),
                ),
              ),
          ],
        );
      },
    );
  }
}
