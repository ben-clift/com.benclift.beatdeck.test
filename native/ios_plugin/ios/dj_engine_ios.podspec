Pod::Spec.new do |s|
  s.name             = 'dj_engine_ios'
  s.version          = '0.0.1'
  s.summary          = 'BeatDeck DJ engine for iPhone'
  s.description      = 'The C++ DJ engine, built in CI into libs/libdj_engine_all.a, plus small iPhone helpers.'
  s.homepage         = 'https://github.com/ben-clift'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'BeatDeck' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.5'
  s.swift_version    = '5.0'
  s.vendored_libraries = 'libs/libdj_engine_all.a'
  s.frameworks       = 'AudioToolbox', 'AVFoundation', 'CoreFoundation', 'Accelerate'
  s.libraries        = 'c++'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  # The engine is looked up by name at run time (dart:ffi), so keep every
  # symbol of the library and do not strip them.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_ROOT}/../.symlinks/plugins/dj_engine_ios/ios/libs/libdj_engine_all.a"',
    'STRIP_STYLE' => 'non-global'
  }
end
