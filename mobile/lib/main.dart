// The app entry point: `flutter run` targets lib/main.dart by
// default, so this thin forwarder exists only to make the default
// target work. Everything real lives in lib/ui/main.dart.
library;

import 'ui/main.dart' as app;

Future<void> main() async => app.main();
