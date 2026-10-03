Pod::Spec.new do |s|
  s.name = 'focubili_apple'
  s.version = '0.1.0'
  s.summary = 'FocuBili Apple platform integration'
  s.description = s.summary
  s.homepage = 'https://github.com/L1Xu4n/FocuBili'
  s.license = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author = { 'FocuBili' => 'https://github.com/L1Xu4n' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
