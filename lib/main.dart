import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pipeline.dart';

void main() => runApp(const MaterialApp(home: Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final k = {
    'base': TextEditingController(text: 'https://api.openai.com/v1'),
    'key': TextEditingController(),
    'model': TextEditingController(text: 'gpt-4o-mini'),
    'pexels': TextEditingController(),
    'subject': TextEditingController(),
    'lang': TextEditingController(text: 'Turkish'),
    'tts': TextEditingController(text: 'tr-TR'),
  };
  final logs = <String>[];
  bool busy = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() {
          for (final e in k.entries) { final v = p.getString(e.key); if (v != null) e.value.text = v; }
        }));
  }

  Future<void> go() async {
    final p = await SharedPreferences.getInstance();
    for (final e in k.entries) { await p.setString(e.key, e.value.text); }
    setState(() { busy = true; logs.clear(); });
    try {
      final pl = Pipeline(Cfg(k['base']!.text.trim(), k['key']!.text.trim(), k['model']!.text.trim(), k['pexels']!.text.trim()),
          (s) => setState(() => logs.add(s)));
      final out = await pl.run(k['subject']!.text, k['lang']!.text, k['tts']!.text);
      await Gal.requestAccess();
      await Gal.putVideo(out);
      setState(() => logs.add('Done → saved to gallery (${File(out).lengthSync() ~/ 1024} KB)'));
    } catch (e) {
      setState(() => logs.add('ERROR: $e'));
    } finally {
      setState(() => busy = false);
    }
  }

  Widget f(String id, String label, {bool obscure = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(controller: k[id], obscureText: obscure, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
      );

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('MPT Mobile')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          f('subject', 'Video subject'),
          f('lang', 'Script language (e.g. Turkish)'),
          f('tts', 'Voice locale (e.g. tr-TR)'),
          ExpansionTile(title: const Text('Settings / API keys'), children: [
            f('base', 'LLM base URL (OpenAI-compatible)'),
            f('key', 'LLM API key', obscure: true),
            f('model', 'LLM model'),
            f('pexels', 'Pexels API key', obscure: true),
          ]),
          FilledButton(onPressed: busy ? null : go, child: Text(busy ? 'Working…' : 'Generate video')),
          const SizedBox(height: 12),
          ...logs.map((l) => Text(l)),
        ]),
      );
}
