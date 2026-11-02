# Native side of the Flutter plugin: reads the APNs token and the notification settings (lib/src/native_push.dart).
Pod::Spec.new do |s|
  s.name             = 'hermetica'
  s.version          = '0.1.0'
  s.summary          = 'Hermetica SDK for Flutter: native push token capture.'
  s.homepage         = 'https://github.com/hermeticacomms/hermetica-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Hermetica' => 'https://github.com/hermeticacomms' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
