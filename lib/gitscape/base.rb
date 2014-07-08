require "git"


class Gitscape::Base

  def initialize

    # Always add a merge commit at the end of a merge
    @merge_options = "--no-ff"
    
    # Setup additional merge options based on the version of Git we have
    if git_version_at_least "1.7.4.0"
      @merge_options += " -s recursive -Xignore-space-change"
    else
      warn "Ignoring whitespace changes in merges is only available on Git 1.7.4+"
    end
    
    @env_branch_by_dev_branch = Hash.new do |h, k|  
      case k
        when "master"
          "staging"
        when /release\/i\d+/
          "qa"
        when "live"
          "live"
      end
    end

  end

  def git_working_copy_is_clean puts_changes=true

    # Check if the working copy is clean, if not, exit
    
    changes = `git status -uno --ignore-submodules=all --porcelain`
    working_copy_clean = changes.length == 0
    if !working_copy_clean && puts_changes
      puts "*** Your working copy is not clean, either commit, stash, or reset your changes then try again. ***"
      puts changes
    end

    working_copy_clean
  end

  # Assume the highest branch already merged into live of the form 
  # release/i[\d]+ is the live branch
  def live_iteration
    toRet = `git tag`.split("\n").select { |tag| live_iteration_tag_regex.match tag }.map { |tag| tag.scan(live_iteration_tag_regex).flatten[0].to_i }.sort.last
    toRet
  end

  def current_branch_name
    toRet = `git branch`.scan(/\* (.*)$/).flatten[0]
    toRet
  end

  def current_release_branch_number
    unmerged_into_live_branch_names = `git branch -a --no-merged origin/live`.split("\n")
    release_branch_regex = /release\/i(\d+)$/

    candidates = unmerged_into_live_branch_names.select{ |b| release_branch_regex.match b}.map{|b| b.scan(release_branch_regex).flatten[0].to_i}.sort
    candidates.last
  end

  def current_release_branch_name
    release_number = current_release_branch_number
    if !release_number.nil?
      "release/i#{current_release_branch_number}"
    else
      nil
    end
  end

  def git_has_conflicts puts_conflicts=true
    conflicts_status = `git status --porcelain`
    has_conflicts = conflicts_status.scan(/[AUD]{2}/).count > 0

    puts conflicts_status if has_conflicts && puts_conflicts

    has_conflicts
  end

  def generic_branch_start branch_type, from_branch, new_branch, options
    # option defaults
    options[:push] = false if options[:push].nil?
    
    # Check that the working copy is clean
    exit 1 unless git_working_copy_is_clean
    
    if new_branch.to_s.length == 0
      raise "*** Improper Usage ***\nExpected Usage: #{branch_type}_start <#{branch_type}_name> [--[no-]push]"
    end

    puts `git checkout live`
    puts `git pull origin`

    new_branch = "#{branch_type}/#{new_branch}"
    puts "=== Creating #{branch_type} branch '#{new_branch}' ==="

    puts `git checkout -b #{new_branch}`
    puts `git push origin #{new_branch}` if options[:push]
  end

  def hotfix_start new_branch=nil, options={:push=>false}
    generic_branch_start 'hotfix', 'live', new_branch, options
  end

  def bugfix_start new_branch=nil, options={:push=>false}
    generic_branch_start 'bugfix', "release/i#{current_release_branch_number}", new_branch, options
  end

  def feature_start new_branch=nil, options={:push=>false}
    generic_branch_start 'feature', 'master', new_branch, options
  end

  def hotfix_finish hotfix_branch=nil, options={:env_depth=>:staging, :push=>true, :update_env=>false}
    # option defaults
    options[:env_depth]   = :staging  if options[:env_depth].nil?
    options[:push]        = true      if options[:push].nil?
    options[:update_env]  = false     if options[:update_env].nil?

    # Check that the working copy is clean
    exit 1 unless git_working_copy_is_clean

    hotfix_branch = "hotfix/#{hotfix_branch}"
    
    previous_branch = current_branch_name
    if previous_branch.to_s.start_with? "hotfix/"
      hotfix_branch = previous_branch
    end

    if hotfix_branch.to_s.empty?
      puts "!!! Not currently on a hotfix branch, and no branch name was provided as an argument !!!"
      puts finish_usage_string('hotfix')
      exit 1
    end

    # Collect the set of branches we'd like to merge the hotfix into
    merge_branches = ["master"]
    merge_branches << current_release_branch_name if [:qa, :live].include?(options[:env_depth])
    merge_branches << "live" if options[:env_depth] == :live

    # Merge the hotfix into merge_branches
    puts "=== Merging hotfix into branches #{merge_branches} ==="
    for branch in merge_branches

      # Calculate merge_options
      merge_options = @merge_options
      merge_options += " --log" if branch == "master"

      # Attempt merge
      puts `git checkout #{branch}`
      puts `git pull`
      puts `git merge #{merge_options} #{hotfix_branch}`
      
      # Bail on failures
      exit 1 if !$?.success?
      raise "Merge failure(s) on #{branch}.\nResolve conflicts, and run the script again." if git_has_conflicts
      
      puts `git push origin #{branch}` if options[:push]
      puts `git push origin #{branch}:#{@env_branch_by_dev_branch[branch]}` if options[:update_env]
      
      # If we just merged the live branch, tag this revision, and push that tag to origin
      if branch == "live"
        puts `git tag live/i#{live_iteration}/#{hotfix_branch}`
        puts `git push --tags`
      end

    end

    # Checkout previous branch for user convenience
    `git checkout #{previous_branch}`
  end

  def release_start options={:push=>true, :update_env=>true}
    # Handle default options
    options[:push]        = true  if options[:push].nil?
    options[:update_env]  = true  if options[:update_env].nil?
    
    # Switch to master branch
    puts `git checkout master`
    puts `git pull origin master`

    # Check that the working copy is clean
    exit 1 unless git_working_copy_is_clean

    new_version_number = live_iteration + 1
    release_branch_name = "release/i#{new_version_number}"

    # Cut the branch
    puts `git checkout -b "#{release_branch_name}" master`
    exit 1 unless $?.exitstatus == 0

    # Bump the version number
    `echo "i#{new_version_number}" > ./version`
    exit 1 unless $?.exitstatus == 0

    # Commit the bump
    puts `git commit -a -m "Begin i#{new_version_number} release candidate"`
    exit 1 unless $?.exitstatus == 0
    
    # Push to origin
    if options[:push]
      puts `git push origin -u "#{release_branch_name}"`
      exit 1 unless $?.exitstatus == 0
    end

    # Update qa to the new commit
    if options[:update_env]
      puts `git push origin "#{release_branch_name}:qa"`
      exit 1 unless $?.exitstatus == 0
    end
  end

  def release_finish options={:push=>true, :update_env=>true}
    # Handle default options
    options[:push]        = true  if options[:push].nil?
    options[:update_env]  = true  if options[:update_env].nil?
    
    # Check if the working copy is clean, if not, exit
    exit 1 unless git_working_copy_is_clean

    # Do a git fetch to ensure everything all refs are sync with origin
    puts `git fetch`

    # Get the right release_branch_name to merge
    current_version_number = live_iteration
    new_version_number = current_version_number + 1
    
    release_branch = "release/i#{new_version_number}"

    # Fetch in order to have the latest branch revisions

    # Get branch information for checks
    branch_keys = ["name", "revision", "message"]
    branch_values = `git branch -av`.scan(/^[ \*]*([^ \*]+) +([^ ]+) +(.*)$/)
    branches = branch_values.map {|components| Hash[ branch_keys.zip components ] }
    branch_revisions = Hash[ branches.map {|branch| [branch["name"], branch["revision"]] } ]

    # Check if the required branches in sync
    required_synced_branches = [[release_branch, "remotes/origin/qa"]]
    required_synced_branches.each do |branch_pair|
      if branch_revisions[ branch_pair[0] ] != branch_revisions[ branch_pair[0] ]
        puts "*** ERROR: The #{branch_pair[0]} branch is not the same as the #{branch_pair[1]} branch.
        \tPlease resolve this and try again."
        exit 3
      end
    end

    # Checkout and pull release_branch
    puts `git checkout #{release_branch}`
    puts `git pull origin #{release_branch}`

    # Checkout and pull live
    puts `git checkout live`
    puts `git pull origin live`

    merge_options = "--no-ff -s recursive -Xignore-space-change"

    # Merge the release branch into live
    puts `git merge #{merge_options} #{release_branch}`

    # Error and conflict checking
    if !$?.success? then exit 4 end
    if git_has_conflicts then
      puts "Merge conflicts when pulling #{release_branch} into live"
      puts "Please report a problem if you see this message :)"
      exit 2
    end

    # Ensure there is zero diff between what was tested on origin/qa and the new live
    critical_diff = `git diff live origin/qa`
    if critical_diff.length > 0
      puts "\n!!! This live merge has code that was not on the qa branch !!!\nDiff:"
      puts critical_diff
      puts "!!! Run the command 'git reset --hard' to undo the merge, and raise this error with QA and others involved to determine next step !!!"
      exit 3
    end

    # Record the revision of live used for the release tag
    live_release_revision = `git log -n1 --oneline`.scan(/(^[^ ]+) .*$/).flatten[0]

    # Merge the release branch into master 
    puts `git checkout master`
    puts `git pull origin master`
    puts `git merge #{merge_options} #{release_branch}`

    # Error and conflict checking
    if !$?.success? then exit 4 end
    if git_has_conflicts then
      puts "Merge conflicts when pulling #{release_branch} into master"
      puts "Please report a problem if you see this message :)"
      exit 2
    end

    # Tag the state of live for both release and rollback
    puts `git tag rollback-to/i#{current_version_number} live~`
    if !$?.success? then
      puts "=== WARNING: Failed to create rollback-to/i#{current_version_number} tag"
    end

    `git tag live/i#{new_version_number}/release #{live_release_revision}`
    if !$?.success? then
      puts "=== WARNING: Failed to create live/i#{new_version_number}/release"
      puts `git tag -d rollback-to/i#{current_version_number}`
      exit 4
    end
    
    if options[:push] && options[:update_env]
      puts `git push origin live --tags`
      puts `git push origin master`
    end
  end
  
  def tag_cleanup options
    # Handle default options
    options[:push] = false if options[:push].nil?
    
    # Do a fetch in order to ensure we have all the latest tags
    `git fetch`
    
    # Select which tags to keep.
    # We currently keep tags which fulfill any of the following
    # 1. starts with 'service/'
    # 2. starts with 'rollback-to/' or 'live/', and has an iteration number >= the live_iteration number - 3
    tags = `git tag`.split "\n" 
    tags_to_delete = tags.select { |tag| !(!/^service\//.match(tag).nil? || /^(?:live|rollback-to)\/i(\d+)/.match(tag).to_a[1].to_i >= live_iteration - 3) }
    
    puts "Deleting the following tags.\nThese changes #{options[:push] ? "will" : "will not"} be pushed to origin.\n"
    
    tags_to_delete.each { |tag| puts `git tag -d #{tag}` }
    tags_to_delete.each { |tag| puts `git push origin :refs/tags/#{tag}` } if options[:push]
  end

  # Returns true if the supplied Git commit hash or reference exists
  def self.commit_exists?(commit_id)
    `git rev-parse #{commit_id}`
    if $? == 0
      true
    else
      raise "Invalid commit/ref ID: #{commit_id}"
    end
  end

  # Get the system's current git version
  def git_version
    @git_version ||= `git --version`.strip.split(" ").last
  end

  # Check if the system's git version is at least as recent as the version specified
  def git_version_at_least(min_version)
    def split_version(v)
      v.split(".").map { |x| x.to_i }
    end
    local_version = split_version(git_version)
    min_version = split_version(min_version)

    raise "Git version string must have 4 parts" if min_version.size != 4

    4.times do |i|
      next if local_version[i] == min_version[i]
      return local_version[i] > min_version[i]
    end
    true # If you get all the way here, all 4 positions match precisely
  end

  def finish_usage_string(branch_type)
    "expected usage: #{branch_type}_finish [<#{branch_type}_branch>]
    #{branch_type}_branch: the name of the #{branch_type} branch to finish.
      if omitted, you must currently be on a #{branch_type} branch"
  end
end

