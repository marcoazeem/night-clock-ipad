// Renders the panel's icons (Material and Hugeicons) and the app icon's
// digits to PNGs for the iPad build (ipad/): the app tints and draws the
// icon images. Flutter's test renderer (Skia) draws them for real. Run from
// the repo root:
//   ~/FlutterDev/flutter/bin/flutter test ipad/tool/glyphs_test.dart
// Output: ipad/build/glyphs/icon_*.png and digits_24.png.
// (It rendered the clock's characters too while the clock was a colour
// font, which iOS 10 can't draw; the clock, in Chakra Petch, is drawn by
// UIKit.)

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hugeicons/hugeicons.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(bytes.buffer)));
  await loader.load();
}

Future<void> savePng(ui.Picture picture, int w, int h, String path) async {
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

/// A Hugeicons icon as a white 24×24 SVG (as the HugeIcon widget builds it).
String hugeSvg(List<List<dynamic>> icon) {
  final b = StringBuffer(
    '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">',
  );
  for (final [tag as String, attrs as Map<String, dynamic>] in icon) {
    b.write('<$tag');
    for (final MapEntry(:key, :value) in attrs.entries) {
      if (key == 'key') continue;
      final name = key.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');
      b.write(' $name="${value == 'currentColor' ? '#ffffff' : value}"');
    }
    b.write('/>');
  }
  return '$b</svg>';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render glyphs', () async {
    final home = Platform.environment['HOME']!;
    await loadFont(
      'MaterialIcons',
      '$home/FlutterDev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await loadFont('Chakra Petch', 'fonts/ChakraPetch-Bold.ttf');
    // A clean slate: outputs no longer rendered mustn't linger (build.sh
    // copies the whole set of icons).
    final out = Directory('ipad/build/glyphs');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);

    // Weather and dashboard icons, white; the iPad tints them.
    final icons = {
      'sun': Icons.wb_sunny_rounded,
      'moon': Icons.nightlight_round,
      'cloud': Icons.cloud_rounded,
      'drop': Icons.water_drop_rounded,
      'bright': Icons.brightness_6_rounded,
      // Dashboard.
      'home': Icons.home_rounded,
      'bedtime': Icons.bedtime_rounded,
      'sunny': Icons.wb_sunny_rounded,
      'power': Icons.power_settings_new_rounded,
      'wifioff': Icons.wifi_off_rounded,
      'wifi': Icons.wifi_rounded,
      'bulb': Icons.lightbulb_rounded,
      'bulboff': Icons.lightbulb_outline_rounded,
      'shield': Icons.shield_rounded,
      'warning': Icons.warning_amber_rounded,
      'sync': Icons.sync_rounded,
      'bed': Icons.bed_rounded,
      'sofa': Icons.weekend_rounded,
      'kitchen': Icons.kitchen_rounded,
      'lock': Icons.lock_rounded,
      'backspace': Icons.backspace_outlined,
      'minus': Icons.remove_rounded,
      'plus': Icons.add_rounded,
      'thermostat': Icons.thermostat_rounded,
      'mode0': Icons.autorenew_rounded,
      'mode1': Icons.ac_unit_rounded,
      'mode2': Icons.water_drop_rounded,
      'mode3': Icons.air_rounded,
      'mode4': Icons.local_fire_department_rounded,
      'tv': Icons.tv_rounded,
      'volume': Icons.volume_up_rounded,
      'flame': Icons.local_fire_department_rounded,
      'bolt': Icons.bolt_rounded,
    };
    for (final MapEntry(:key, :value) in icons.entries) {
      const s = 256.0;
      final pb =
          ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: 'MaterialIcons', fontSize: s, height: 1))
            ..pushStyle(ui.TextStyle(
              fontFamily: 'MaterialIcons',
              fontSize: s,
              height: 1,
              color: const Color(0xFFFFFFFF),
            ))
            ..addText(String.fromCharCode(value.codePoint));
      final p = pb.build()..layout(const ui.ParagraphConstraints(width: 1000));
      final rec = ui.PictureRecorder();
      Canvas(rec).drawParagraph(p, Offset.zero);
      await savePng(rec.endRecording(), s.toInt(), s.toInt(), '${out.path}/icon_$key.png');
    }

    // Hugeicons (the Sonoff switch tiles), from their SVG paths.
    final huge = {
      'fan': HugeIcons.strokeRoundedFan01,
      'ceiling': HugeIcons.strokeRoundedLampCeiling,
      'hanging': HugeIcons.strokeRoundedLamp02,
      'walllight': HugeIcons.strokeRoundedLampWallDown,
      'cabinet': HugeIcons.strokeRoundedCabinet01,
      'lamp': HugeIcons.strokeRoundedBulb,
    };
    for (final MapEntry(:key, :value) in huge.entries) {
      const s = 256.0;
      final info = await vg.loadPicture(SvgStringLoader(hugeSvg(value)), null);
      final rec = ui.PictureRecorder();
      Canvas(rec)
        ..scale(s / 24)
        ..drawPicture(info.picture);
      await savePng(rec.endRecording(), s.toInt(), s.toInt(), '${out.path}/icon_$key.png');
    }

    // Meteocons weather icons (assets/weather, MIT), in full colour.
    for (final f in Directory('assets/weather').listSync()) {
      if (!f.path.endsWith('.svg')) continue;
      const s = 256.0;
      final name = f.uri.pathSegments.last.replaceAll('.svg', '');
      final info = await vg.loadPicture(SvgStringLoader(File(f.path).readAsStringSync()), null);
      final rec = ui.PictureRecorder();
      Canvas(rec)
        ..scale(s / 64)
        ..drawPicture(info.picture);
      await savePng(rec.endRecording(), s.toInt(), s.toInt(), '${out.path}/wx_$name.png');
    }

    // The app icon's "24": the clock's Chakra Petch Bold in its daytime
    // yellow.
    // Written last — build.sh takes it as the stamp of a finished render.
    {
      const s = 400.0;
      final pb =
          ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: 'Chakra Petch', fontSize: s, height: 1))
            ..pushStyle(ui.TextStyle(
              fontFamily: 'Chakra Petch',
              fontSize: s,
              height: 1,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFFFD23F),
            ))
            ..addText('24');
      final p = pb.build()..layout(const ui.ParagraphConstraints(width: 10000));
      final rec = ui.PictureRecorder();
      Canvas(rec).drawParagraph(p, Offset.zero);
      await savePng(rec.endRecording(), p.maxIntrinsicWidth.ceil(), s.toInt(), '${out.path}/digits_24.png');
    }
  });
}
