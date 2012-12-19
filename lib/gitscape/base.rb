require "git"


class Gitscape::Base

  def initialize
    # Use the current directory as our target repository
    @repo = Git.open "."

    # Always add a merge commit at the end of a merge
    @merge_options = "--no-ff"
    # Setup additional merge options based on the version of Git we have
    if git_version_at_least "1.7.4.0"
      @merge_options += "-s recursive -Xignore-space-change"
    else
      warn "Ignoring whitespace changes in merges is only available on Git 1.7.4+"
    end
  end

  def branch_names
    @repo.branches.map { |b| b.full }
  end

  # Get the system's current git version
  def git_version
    @git_version ||= `git --version`.strip.split(" ").last
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

  # Check if the system's git version is at least as recent as the version specified
  def git_version_at_least(min_version)
    def split_version(v)
      v.split(".").map { |x| x.to_i }
    end
    local_version = split_version(git_version)
    min_version = split_version(min_version)

    raise "Git version string must have 4 parts" if min_version.size != 4

    4.times do |i|
      return false unless local_version[i] >= min_version[i]
    end
    true
  end

  def hotfix_start(hotfix_branch_name=nil)
    checkout "master"

    hotfix_branch_name = "hotfix/#{hotfix_branch_name}"
    puts "Creating hotfix branch '#{hotfix_branch_name}'..."
    @repo.checkout(@repo.branch.create(hotfix_branch_name))
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

    if hotfix_branch_name.empty?
      puts "!!! not currently on a hotfix branch, and no branch name was provided as an argument !!!"
      puts usage_string
      exit 1
    end

    hotfix_branch = @repo.branch hotfix_branch_name
    development_branch = @repo.branches.select {|branch| branch.full.start_with? "release/"}.sort.last
    development_branch = @repo.branch "master" if development_branch == nil
    live_branch = @repo.branch "live"

    # Collect the set of branches we'd like to merge the hotfix into
    merge_branches = [development_branch, live_branch]

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

