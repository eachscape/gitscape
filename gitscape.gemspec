# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "gitscape/version"


Gem::Specification.new do |s|
  s.name        = "gitscape"
  s.version     = GitScape::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Jon Botelho"]
  s.email	= ["gitscape@eachscape.com"]
  s.homepage	= ""
  s.summary     = "Various Git utilities for cherry-pick/rebase workflows."
  s.description = "Various Git utilities for cherry-pick/rebase workflows."

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
