import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class Cfg {
  String llmBase, llmKey, llmModel, pexelsKey;
  Cfg(this.llmBase, this.llmKey, this.llmModel, this.pexelsKey);
}

typedef Log = void Function(String);

class Pipeline {
  final Cfg c;
  final Log log;
  Pipeline(this.c, this.log);

  // 1) LLM -------------------------------------------------------------
  Future<String> _chat(String prompt) async {
    final r = await http.post(Uri.parse('${c.llmBase}/chat/completions'),
        headers: {'Authorization': 'Bearer ${c.llmKey}', 'Content-Type': 'application/json'},
        body: jsonEncode({'model': c.llmModel, 'messages': [{'role': 'user', 'content': prompt}]}));
    if (r.statusCode != 200) throw Exception('LLM ${r.statusCode}: ${r.body}');
    return jsonDecode(utf8.decode(r.bodyBytes))['choices'][0]['message']['content'];
  }

  Future<String> script(String subject, String lang, int paras) => _chat(
      'Write a short-video narration script about "$subject" in $lang, $paras paragraphs. '
      'Plain spoken text only: no markdown, titles, or stage directions.');

  Future<List<String>> terms(String subject, String script, int n) async {
    final t = await _chat('Give $n English stock-footage search terms (1-3 words each) for a video about '
        '"$subject". Script:\n$script\nReturn ONLY a JSON array of strings.');
    return List<String>.from(jsonDecode(RegExp(r'\[.*\]', dotAll: true).firstMatch(t)!.group(0)!));
  }

  // 2) Footage (Pexels) ------------------------------------------------
  Future<List<String>> footage(List<String> terms, String dir) async {
    final out = <String>[];
    for (final t in terms) {
      final r = await http.get(
          Uri.parse('https://api.pexels.com/videos/search?query=${Uri.encodeQueryComponent(t)}&per_page=5&orientation=portrait'),
          headers: {'Authorization': c.pexelsKey});
      if (r.statusCode != 200) { log('Pexels $t: ${r.statusCode}'); continue; }
      final vids = jsonDecode(r.body)['videos'] as List;
      if (vids.isEmpty) continue;
      final files = (vids.first['video_files'] as List).where((f) => f['file_type'] == 'video/mp4').toList();
      if (files.isEmpty) continue;
      final f = files.firstWhere((f) => (f['width'] ?? 0) >= 720 && (f['width'] ?? 0) <= 1080, orElse: () => files.first);
      final p = '$dir/clip_${out.length}.mp4';
      await File(p).writeAsBytes((await http.get(Uri.parse(f['link']))).bodyBytes);
      out.add(p);
      log('Downloaded clip for "$t"');
    }
    return out;
  }

  // 3) Voice (Android system TTS; Edge TTS comes in milestone 2) -------
  Future<String> voice(String text, String lang, String dir) async {
    final tts = FlutterTts();
    await tts.setLanguage(lang);
    await tts.awaitSynthCompletion(true);
    final p = '$dir/voice.wav';
    await tts.synthesizeToFile(text, p, true);
    return p;
  }

  Future<double> duration(String path) async {
    final i = await FFprobeKit.getMediaInformation(path);
    return double.parse(i.getMediaInformation()!.getDuration()!);
  }

  // 4) Subtitles: sentence timing proportional to length ---------------
  String srt(String script, double total) {
    final s = script.split(RegExp(r'(?<=[.!?。！？])\s+')).where((e) => e.trim().isNotEmpty).toList();
    final len = s.fold<int>(0, (a, e) => a + e.length);
    String ts(double x) {
      final ms = (x * 1000).round();
      String p(int v, int n) => v.toString().padLeft(n, '0');
      return '${p(ms ~/ 3600000, 2)}:${p(ms ~/ 60000 % 60, 2)}:${p(ms ~/ 1000 % 60, 2)},${p(ms % 1000, 3)}';
    }
    var t = 0.0; final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final d = total * s[i].length / len;
      b.writeln('${i + 1}\n${ts(t)} --> ${ts(t + d)}\n${s[i].trim()}\n');
      t += d;
    }
    return b.toString();
  }

  // 5) Compose ---------------------------------------------------------
  Future<void> _ff(String cmd) async {
    final s = await FFmpegKit.execute(cmd);
    if (!(await s.getReturnCode())!.isValueSuccess()) {
      throw Exception('ffmpeg failed: ${(await s.getOutput() ?? '').split('\n').reversed.take(8).toList().reversed.join('\n')}');
    }
  }

  Future<String> compose(List<String> clips, String voicePath, String script, String dir) async {
    final total = await duration(voicePath);
    const seg = 4.0;
    final n = (total / seg).ceil();
    final list = StringBuffer();
    for (var i = 0; i < n; i++) {
      final d = (i == n - 1) ? total - seg * i : seg;
      final o = '$dir/seg_$i.mp4';
      await _ff('-y -stream_loop -1 -i ${clips[i % clips.length]} -t ${d.toStringAsFixed(2)} '
          '-vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,setsar=1" '
          '-an -c:v libx264 -preset ultrafast -crf 23 $o');
      list.writeln("file '$o'");
      log('Segment ${i + 1}/$n');
    }
    await File('$dir/list.txt').writeAsString(list.toString());
    await File('$dir/sub.srt').writeAsString(srt(script, total));
    final fd = Directory('$dir/fonts')..createSync();
    await File('${fd.path}/font.ttf').writeAsBytes((await rootBundle.load('assets/fonts/font.ttf')).buffer.asUint8List());
    final out = '$dir/final.mp4';
    await _ff('-y -f concat -safe 0 -i $dir/list.txt -i $voicePath '
        '-vf "subtitles=$dir/sub.srt:fontsdir=${fd.path}:force_style=\'FontName=DejaVu Sans,FontSize=14,Alignment=2,MarginV=160,Outline=2\'" '
        '-map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac -shortest $out');
    return out;
  }

  // Full run -----------------------------------------------------------
  Future<String> run(String subject, String lang, String ttsLang) async {
    final dir = (await getTemporaryDirectory()).path + '/job_${DateTime.now().millisecondsSinceEpoch}';
    Directory(dir).createSync(recursive: true);
    log('Writing script…');
    final sc = await script(subject, lang, 3);
    log('Finding search terms…');
    final tm = await terms(subject, sc, 5);
    log('Downloading footage: ${tm.join(", ")}');
    final clips = await footage(tm, dir);
    if (clips.isEmpty) throw Exception('No footage found');
    log('Synthesizing voice…');
    final v = await voice(sc, ttsLang, dir);
    log('Rendering video…');
    return compose(clips, v, sc, dir);
  }
}
