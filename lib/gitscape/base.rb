require "git"


class Gitscape::Base

  def initialize
    # Use the current directory as our target repository
    @repo = Git.open "."

    # Always add a merge commit at the end of a merge
    @merge_options = "--no-ff"
    # Setup additional merge options based on the version of Git we have
    if git_version_at_least "1.7.4.0"
      @merge_options += " -s recursive -Xignore-space-change"
    else
      warn "Ignoring whitespace changes in merges is only available on Git 1.7.4+"
    end
  end

  def branch_names
    @repo.branches.map { |b| b.full }
  end

  def checkout(branch_name)
    begin
      @repo.revparse(branch_name)
    rescue
      raise Exception.new "No branch '#{branch_name}' found"
    end
    puts "Switching to branch '#{branch_name}'..."
    @repo.checkout(branch_name)
  end

  def git_working_copy_is_clean puts_changes=true
    # Check if the working copy is clean, if not, exit
    changes = `git status -uno --ignore-submodules=all --porcelain`
    working_copy_clean = changes.length == 0
    if !working_copy_clean && puts_changes
      puts "Your working copy is not clean, either commit, stash, or reset your changes then try again."
      puts changes
    end

    working_copy_clean
  end

  def live_current_version_number
    current_branch = @repo.current_branch
    live_branch = @repo.branch "live"

    `git checkout #{live_branch.full}` unless current_branch == live_branch

    version_file = File.new("version", "r")
    live_current_version_number = version_file.read.delete("i").to_i

    `git checkout #{current_branch}` unless current_branch == live_branch

    live_current_version_number
  end

  def git_has_conflicts puts_conflicts=true
    conflicts_status = `git status --porcelain`
    has_conflicts = conflicts_status.scan(/[AUD]{2}/).count > 0

    puts conflicts_status if has_conflicts && puts_conflicts

    has_conflicts
  end

  def hotfix_start(hotfix_branch_name=nil)
    checkout "live"

    if hotfix_branch_name.length == 0
      exception_message = "*** Improper Usage ***\nExpected Usage: hotfix_start <hotfix_branch_name>"
      raise exception_message
    end

    hotfix_branch_name = "hotfix/#{hotfix_branch_name}"
    puts "Creating hotfix branch '#{hotfix_branch_name}'..."

    hotfix_branch = @repo.branch(hotfix_branch_name)
    `git checkout -b #{hotfix_branch.full}`
    @repo.checkout(hotfix_branch)
  end

  def hotfix_finish(hotfix_branch_name=nil)
    # TODO:
    # 1. Tag the new live revision with 'live/<branch_name_without_prefix>'

    usage_string = "expected usage: hotfix_finish [<hotfix_branch_name>]
    hotfix_branch_name: the name of the hotfix branch to finish.
      if ommitted, you must currently be on a hotfix branch"

    previous_branch = @repo.current_branch

    if previous_branch.start_with? "hotfix"
      hotfix_branch_name ||= previous_branch
    end

    unless @repo.branches.include? hotfix_branch_name
    end

    merge_master = true
    master_branch = @repo.branch "master"

    if hotfix_branch_name.to_s.empty?
      puts "!!! not currently on a hotfix branch, and no branch name was provided as an argument !!!"
      puts usage_string
      exit 1
    end

    hotfix_branch = @repo.branch hotfix_branch_name
    # TODO The next line breaks at iteration 100
    development_branch = @repo.branches.select {|branch| branch.full.start_with? "release/"}.sort{|a, b| a.name <=> b.name}.last
    development_branch = master_branch if development_branch == nil
    live_branch = @repo.branch "live"

    # Collect the set of branches we'd like to merge the hotfix into
    merge_branches = [development_branch, live_branch]
    merge_branches << master_branch if !(merge_branches.include? master_branch) && merge_master

    # Merge the hotfix into branches
    for branch in merge_branches
      merge_options = @merge_options
      merge_options += " --log" if branch == "master"

      `git checkout #{branch.full}`
      `git merge #{merge_options} #{hotfix_branch.full}`
      exit 1 if !$?.success?
      raise "Merge on #{branch.full} has failed.\nResolve the conflicts and run the script again." if git_has_conflicts
    end

    # Checkout previous branch for user convenience
    `git checkout #{previous_branch}`
  end

  def release_start
    # Switch to master branch
    # puts"About to checkout master"
    `git checkout master`
    # puts"Checkout of master branch successful"

    # Check that the working copy is clean
    exit 1 unless git_working_copy_is_clean

    # Figure out the previous and new version numbers
    version_file = File.new("version", "r")
    previous_version_number = version_file.read.delete("i").to_i
    new_version_number = previous_version_number + 1

    # Get the new release_branch_name
    release_branch_name = "i#{new_version_number}"

    # Cut the branch
    `git checkout -b "release/#{release_branch_name}" master`
    exit 1 unless $?.exitstatus == 0

    # Bump the version number
    `echo "#{release_branch_name}" > ./version`
    exit 1 unless $?.exitstatus == 0

    # Commit the bump
    `git commit -a -m "Begin #{release_branch_name} release candidate"`
    exit 1 unless $?.exitstatus == 0

    # Push to origin
    `git push origin -u "release/#{release_branch_name}"`
    exit 1 unless $?.exitstatus == 0
    `git push origin "release/#{release_branch_name}:qa"`
    exit 1 unless $?.exitstatus == 0
  end

  def release_finish new_version_number=0
    # Check if the working copy is clean, if not, exit
    exit 1 unless git_working_copy_is_clean

    # Get the right release_branch_name to merge
    current_version_number = new_version_number - 1
    if new_version_number == 0
      current_version_number = live_current_version_number
      new_version_number = current_version_number + 1
    end
    release_branch_name = "release/i#{new_version_number}"
    release_branch = @repo.branch release_branch_name

    # Get branch information for checks
    branch_keys = ["name", "revision", "message"]
    branch_values = `git branch -av`.scan(/^[ \*]*([^ \*]+) +([^ ]+) +(.*)$/)
    branches = branch_values.map {|components| Hash[ branch_keys.zip components ] }
    branch_revisions = Hash[ branches.map {|branch| [branch["name"], branch["revision"]] } ]

    # Check if the required branches in sync
    required_synced_branches = [ [release_branch_name, "remotes/origin/qa"], ["master", "remotes/origin/master"], ["live", "remotes/origin/live"] ]
    required_synced_branches.each do |branch_pair|
      if branch_revisions[ branch_pair[0] ] != branch_revisions[ branch_pair[0] ]
        puts "*** ERROR: The #{branch_pair[0]} branch is not the same as the #{branch_pair[1]} branch.
        \tPlease resolve this and try again."
        exit 3
      end
    end

    # Checkout release branch
    puts `git checkout #{release_branch_name}`
    puts `git pull origin #{release_branch_name}`

    # Checkout live
    puts `git checkout live`
    puts `git pull origin live`

    # Record the revision of live used for the rollback tag
    live_rollback_revision = `git log -n1 --oneline`.scan(/(^[^ ]+) .*$/).flatten[0]

    merge_options = "--no-ff -s recursive -Xignore-space-change"

    # Merge the release branch into live
    puts `git merge #{merge_options} #{release_branch_name}`

    # Error and conflict checking
    if !$?.success? then exit 4 end
    if git_has_conflicts then
      puts "Merge conflicts when pulling #{release_branch_name} into live"
      puts "Please bother Xavier if you see this message :)"
      exit 2
    end

    # Ensure there is zero diff between what was tested on origin/qa and the new live
    critical_diff = `git diff --stat live origin/qa`
    if critical_diff.length > 0
      puts "This live merge has code that was not on the qa branch."
      puts critical_diff
      puts "Run the command 'git reset --hard' to undo the merge, and raise this error with Phil and others involved to determine whether the release should happen."
      exit 3
    end

    # Record the revision of live used for the release tag
    live_release_revision = `git log -n1 --oneline`.scan(/(^[^ ]+) .*$/).flatten[0]

    # Merge the release branch into master 
    puts `git checkout master`
    puts `git pull origin master`
    puts `git merge #{merge_options} #{release_branch_name}`

    # Error and conflict checking
    if !$?.success? then exit 4 end
    if git_has_conflicts then
      puts "Merge conflicts when pulling #{release_branch_name} into master"
      puts "Please bother Xavier if you see this message :)"
      exit 2
    end

    # Tag the state of live for both release and rollback
    puts `git tag rollback-to/i#{current_version_number} #{live_rollback_revision}`
    if !$?.success? then
      puts "=== WARNING: Failed to create rollback-to/i#{current_version_number} tag"
    end

    `git tag live/i#{new_version_number}/release #{live_release_revision}`
    if !$?.success? then
      puts "=== WARNING: Failed to create live/i#{new_version_number}/release"
      puts `git tag -d rollback-to/i#{current_version_number}`
      exit 4
    end

    puts `git push origin live --tags`
    puts `git push origin master`
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

  def self.run_script(script, quiet=true)
    IO.popen(script.split("\n").join(" && ")) do |io|
      while (line = io.gets) do
        unless quiet
          puts line
        end
      end
    end
    $?.exitstatus
  end

  def promote_branch(head, upstream)
    run_script <<-EOH
      git fetch
      git stash
      git checkout #{head}
      git reset --hard origin/#{head}
      git push -f origin #{head}:#{upstream}
    EOH
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

  def self.result_ok?(result)
    if result.nil? or result == 0
      puts "done"
      return true
    else
      puts "failed"
      puts "Aborting"
      run_script "git checkout master"
      return false
    end
  end

  def self.start_iteration(iteration, projects=PROJECTS)
    projects.each do |proj|
      print "Cutting branch #{iteration} for #{proj}..."
      result = run_script <<-EOH
        cd /code/#{proj}/
        git fetch
        git branch #{iteration} origin/master
        git push origin #{iteration}
        git push -f origin #{iteration}:qa
      EOH
      return unless result_ok?(result)
    end
  end

  def self.deploy_iteration(iteration, projects=PROJECTS)
    date = `date +%Y%m%d-%H%M`.strip
    tag = "#{iteration}-#{date}"
    puts "Starting deploy of #{iteration}"
    puts "Will tag with '#{tag}'"
    puts

    projects.each do |proj|
      print "Tagging #{proj}..."
      result = run_script <<-EOH
        cd /code/#{proj}/
        git stash
        git checkout qa
        git fetch
        git reset --hard origin/qa
        git tag -a #{tag} -m 'Release to live'
      EOH
      return unless result_ok?(result)
    end

    projects.each do |proj|
      print "Pushing #{proj}..."
      result = run_script <<-EOH
        cd /code/#{proj}/
        git push -f origin qa:live
        git push --tags
        git checkout master
      EOH
      #return unless result_ok?(result)
    end

    puts
    puts "Deploy of #{iteration} completed successfully."
  end
end

