/// The fly-to search of the world map.
///
/// A field over the names the page can fly to (its plotted
/// cities and the countries that hold them): type, pick, and
/// the page does the rest.
///
/// **Not** Flutter's [Autocomplete]. That widget keeps the
/// last pick as its `_selection`, and `RawAutocomplete._select`
/// returns early when the picked option *equals* the current
/// selection — so a second pick of the same suggestion is
/// silently dropped. Correct for a value field, wrong for a
/// command: searching Okinawa, opening it, coming back and
/// tapping Okinawa again did nothing, and retyping the query
/// did not help either (the report, 2026-10-28). This field
/// keeps its own match list, so every pick is an event, and
/// the query stays in the field after a pick.
library;

import 'package:flutter/material.dart';

class FlyToField extends StatefulWidget {
  /// The city names to offer, in any order.
  final List<String> cities;

  /// The country names to offer.
  final List<String> countries;

  /// Called with the picked name. A city wins over a country
  /// of the same name, because opening a destination is what
  /// the reader is after.
  final void Function(String name) onPick;

  const FlyToField({
    super.key,
    required this.cities,
    required this.countries,
    required this.onPick,
  });

  @override
  State<FlyToField> createState() => _FlyToFieldState();
}

class _FlyToFieldState extends State<FlyToField> {
  final _query = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Both drive the match list, so both need a rebuild.
    _query.addListener(_rebuild);
    _focus.addListener(_rebuild);
  }

  @override
  void dispose() {
    _query.removeListener(_rebuild);
    _focus.removeListener(_rebuild);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// The suggestions for the current query, in name order.
  List<String> get _matches {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final options = <String>{...widget.cities, ...widget.countries}.toList()
      ..sort();
    return options
        .where((option) => option.toLowerCase().contains(query))
        .take(12)
        .toList();
  }

  /// Whether the suggestion list is on screen: the field has
  /// focus and there is something to offer.
  bool get _showMatches => _focus.hasFocus && _matches.isNotEmpty;

  void _pick(String value) {
    widget.onPick(value);
    // A pick is done: keep the query (so the reader can see
    // what was searched and pick it again) and drop the
    // focus, which closes the list over the map.
    setState(() => _focus.unfocus());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _query,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) {
            final matches = _matches;
            if (matches.isEmpty) return;
            // The exact match first, so typing a full name
            // and pressing search does the obvious thing.
            final query = _query.text.trim();
            _pick(matches.contains(query) ? query : matches.first);
          },
          decoration: InputDecoration(
            labelText: 'Fly to',
            hintText: 'Bucharest, Romania…',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _query.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear the search',
                    onPressed: () {
                      _query.clear();
                      _focus.requestFocus();
                    },
                  ),
          ),
        ),
        // The list is inline rather than an overlay: it sits
        // in the page's scroll view, so it cannot be clipped
        // by it and it needs no Overlay plumbing.
        if (_showMatches)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  children: [
                    for (final match in _matches)
                      ListTile(
                        dense: true,
                        title: Text(match),
                        onTap: () => _pick(match),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
