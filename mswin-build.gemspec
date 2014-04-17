# coding: utf-8
# -*- Ruby -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'mswin-build/version'

Gem::Specification.new do |spec|
  spec.name          = "mswin-build"
  spec.version       = MswinBuild::VERSION
  spec.authors       = ["U.Nakamura"]
  spec.email         = ["usa@garbagecollect.jp"]
  spec.description   = %q{A low quality clone of https://github.com/akr/chkbuild for mswin.}
  spec.summary       = %q{A low quality clone of https://github.com/akr/chkbuild for mswin.}
  spec.homepage      = "https://github.com/unak/mswin-build"
  spec.license       = "BSD-2-Clause"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "test-unit"
end
