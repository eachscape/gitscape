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

  def live_iteration
    toRet = `git branch -a --merged live`.split("\n").select{|b| /release\/i(\d+)$/.match b}.map{|b| b.scan(/release\/i(\d+)$/).flatten[0].to_i}.sort.last
    toRet
  end

  def current_branch_name
    toRet = `git status --porcelain -b`.scan(/## (.*)/).flatten[0]
    toRet
  end

  def current_release_branch_number
    unmerged_into_live_branch_names = `git branch -a --no-merged live`.split("\n")
    release_branch_regex = /release\/i(\d+)$/

    candidates = unmerged_into_live_branch_names.select{ |b| release_branch_regex.match b}.map{|b| b.scan(release_branch_regex).flatten[0].to_i}.sort
    candidates.last
  end

  def current_release_branch_name
    "release/i#{current_release_branch_number}"
  end

  def git_has_conflicts puts_conflicts=true
    conflicts_status = `git status --porcelain`
    has_conflicts = conflicts_status.scan(/[AUD]{2}/).count > 0

    puts conflicts_status if has_conflicts && puts_conflicts

    has_conflicts
  end

  def hotfix_start(hotfix_branch=nil)
    puts `git checkout live`

    if hotfix_branch.length == 0
      exception_message = "*** Improper Usage ***\nExpected Usage: hotfix_start <hotfix_branch>"
      raise exception_message
    end

    hotfix_branch = "hotfix/#{hotfix_branch}"
    puts "=== Creating hotfix branch '#{hotfix_branch}' ==="

    puts `git checkout -b #{hotfix_branch}`
  end

  def hotfix_finish(hotfix_branch=nil)
    # TODO:
    # 1. Tag the new live revision with 'live/<branch_name_without_prefix>'

    usage_string = "expected usage: hotfix_finish [<hotfix_branch>]
    hotfix_branch: the name of the hotfix branch to finish.
      if ommitted, you must currently be on a hotfix branch"

    previous_branch = current_branch_name

    if previous_branch.start_with? "hotfix"
      hotfix_branch ||= previous_branch
    end

    if hotfix_branch.to_s.empty?
      puts "!!! Not currently on a hotfix branch, and no branch name was provided as an argument !!!"
      puts usage_string
      exit 1
    end

    # Collect the set of branches we'd like to merge the hotfix into
    merge_branches = ["master", current_release_branch_name, "live"]

    # Merge the hotfix into merge_branches
    for branch in merge_branches

      # Calculate merge_options
      merge_options = @merge_options
      merge_options += " --log" if branch == "master"

      # Attempt merge
      `git checkout #{branch}`
      `git merge #{merge_options} #{hotfix_branch}`
      
      # Bail on failures
      exit 1 if !$?.success?
      raise "Merge on #{branch} has failed.\nResolve the conflicts and run the script again." if git_has_conflicts

      # If we just merged the live branch, tag this revision, and push that tag to origin
      if branch == "live"
        `git tag live/i#{live_iteration}/#{hotfix_branch}`
        `git push --tags`
      end

    end

    # Checkout previous branch for user convenience
    `git checkout #{previous_branch}`
  end

  def release_start
    # Switch to master branch
    puts `git checkout master`
    puts `git pull origin master`

    # Check that the working copy is clean
    exit 1 unless git_working_copy_is_clean

    # Figure out the previous and new version numbers
    version_file = File.new("version", "r")
    previous_version_number = version_file.read.delete("i").to_i
    new_version_number = previous_version_number + 1

    # Get the new release_branch_name
    release_branch_name = "i#{new_version_number}"

    # Cut the branch
    puts `git checkout -b "release/#{release_branch_name}" master`
    exit 1 unless $?.exitstatus == 0

    # Bump the version number
    `echo "#{release_branch_name}" > ./version`
    exit 1 unless $?.exitstatus == 0

    # Commit the bump
    puts `git commit -a -m "Begin #{release_branch_name} release candidate"`
    exit 1 unless $?.exitstatus == 0

    # Update qa to the new commit
    puts `git push origin "release/#{release_branch_name}:qa"`
    exit 1 unless $?.exitstatus == 0

    # Push to origin
    puts `git push origin -u "release/#{release_branch_name}"`
    exit 1 unless $?.exitstatus == 0
  end

  def release_finish new_version_number=0
    # Check if the working copy is clean, if not, exit
    exit 1 unless git_working_copy_is_clean

    # Get the right release_branch_name to merge
    current_version_number = new_version_number - 1
    if new_version_number == 0
      current_version_number = live_iteration
      new_version_number = current_version_number + 1
    end
    release_branch_name = "release/i#{new_version_number}"
    release_branch = @repo.branch release_branch_name

    # Fetch in order to have the latest branch revisions

    # Get branch information for checks
    branch_keys = ["name", "revision", "message"]
    branch_values = `git branch -av`.scan(/^[ \*]*([^ \*]+) +([^ ]+) +(.*)$/)
    branches = branch_values.map {|components| Hash[ branch_keys.zip components ] }
    branch_revisions = Hash[ branches.map {|branch| [branch["name"], branch["revision"]] } ]

    # Check if the required branches in sync
    required_synced_branches = [[release_branch_name, "remotes/origin/qa"]]
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

