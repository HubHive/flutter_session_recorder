Pod::Spec.new do |s|
  s.name             = 'flutter_screen_recorder'
  s.version          = '0.0.1'
  s.summary          = 'Flutter session replay plugin with structured native capture.'
  s.description      = <<-DESC
Structured mobile session replay plugin for Flutter with native iOS capture.
                       DESC
  s.homepage         = 'https://hubhive.dev'
  s.license          = { :type => 'Proprietary', :text => 'All rights reserved.' }
  s.author           = { 'HubHive' => 'dev@hubhive.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
