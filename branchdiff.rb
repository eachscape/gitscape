#!/usr/bin/env ruby

upstream = ARGV[1]
head = ARGV[2]

puts "#" * 80
puts "# Commits on #{head} not on #{upstream}"
puts "#" * 80
puts
`git cherry #{upstream} #{head}`.split("\n").select { |x| x.start_with? "+" }.each do |x|
  puts `git show -s --format=medium #{x.split(" ").last}`
  puts
  puts "-" * 80
  puts
end
