import 'package:flutter/material.dart';

import 'app/reader_theme.dart';
import 'storage/app_store.dart';
import 'ui/reader_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  runApp(ReaderApp(store: store));
}

class ReaderApp extends StatelessWidget {
  final AppStore store;
  final Widget? home;
  const ReaderApp({super.key, required this.store, this.home});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => MaterialApp(
      title: '清阅',
      debugShowCheckedModeBanner: false,
      theme: ReaderTheme.theme(false),
      darkTheme: ReaderTheme.theme(true),
      themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
      home: home ?? ReaderShell(store: store),
    ),
  );
}
