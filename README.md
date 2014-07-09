Various Git utilities for controlling 3 timestreams (development, QA and deployment).
This is similar to "git flow" but it supports 3 parallel branches rather than two and
knows about certain naming conventions for branches.


Note to anyone maintaining this:

To test, you must build and install the new version locally

  gem build gitscape.gemspec
  gem install gitscape-1.7.0.gem

Note that the "bundle" command is configured to install the gem from the local copy.

You must use "bundle exec gitscape" to test locally.