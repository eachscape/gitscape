# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "gitscape/version"


Gem::Specification.new do |s|
  s.name        = "gitscape"
  s.version     = Gitscape::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Xavier Matos"]
  s.email	      = ["gitscape@eachscape.com"]
  s.homepage	  = "https://github.com/eachscape/gitscape"
  s.summary     = "Various Git utilities for workflows."
  s.description = "Various Git utilities for workflows."

  s.add_dependency "git", "~> 1.2.5"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
