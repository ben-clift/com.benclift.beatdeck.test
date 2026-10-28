import 'package:flutter_test/flutter_test.dart';
import 'package:sidedeck/ui/milkdrop_view.dart';

void main() {
  test('settings JS carries brightness, speed and flip for the projector', () {
    final m = MilkdropSettings.instance;
    m.intensity = 0.5;
    m.fps = 20;
    m.dim = 0.4;
    m.autoSecs = 60;
    m.flipH = true;
    m.flipV = false;
    m.blend = true;
    m.speed = 0.25;
    m.fade = 20;
    m.randSpeed = true;
    m.randFade = false;
    m.randIntensity = true;
    m.photoStrength = 0.5;
    m.photoSecs = 30;
    m.preset = null;
    final js = milkdropSettingsJs(m);
    expect(js, contains('window.setGain'));
    expect(js, contains('window.setFps&&window.setFps(20)'));
    expect(js, contains('window.setDim&&window.setDim(0.40)'));
    expect(js, contains('window.setAuto&&window.setAuto(60)'));
    expect(js, contains('window.setFlip&&window.setFlip(true,false)'));
    expect(js, contains('window.setBlend&&window.setBlend(true)'));
    expect(js, contains('window.setPace&&window.setPace(0.25,20)'));
    expect(js, contains('window.setRandom&&window.setRandom(true,false,true)'));
    expect(js, contains('window.setPhotos&&window.setPhotos(0.50,30)'));
    expect(js, contains('window.loadName&&window.loadName(null)'));
  });

  test('level JS clamps to 0..1', () {
    expect(milkdropLevelsJs([-1, 0.5, 2]), 'window.setLevels&&window.setLevels([0.00,0.50,1.00])');
  });
}
