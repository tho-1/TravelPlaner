/// The food populate: a generated food profile ->
/// the three Food columns of one destination row.
///
/// The Dart port of `data_utils.update_food`'s
/// write (the workbook cells it sets), mapped onto
/// the app's data layer: "set the Food columns"
/// becomes "build the updated destination" -- the
/// same read-modify-write the flag editors use,
/// with the typed core and the lossless tail
/// updated together. Pure: the caller saves it.
///
/// The columns are the workbook's own, including
/// the legacy's "Spicyness" spelling, and the
/// spiciness is written as a number (the legacy
/// writes `float(spiciness)`), the description and
/// the comma-joined dishes as text.
library;

import '../models/destination.dart';
import 'deepseek_client.dart';

class FoodPopulator {
  final Destination destination;

  const FoodPopulator(this.destination);

  /// Apply the food profile and return the updated
  /// row. Pure: the caller saves it.
  Destination apply(FoodProfile profile) {
    return destination
        .withTail('Food - Spicyness', profile.spiciness)
        .withTail('Food - Description', profile.description)
        .withTail('Food - Main Dishes', profile.dishes.join(', '));
  }
}
