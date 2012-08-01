class GitScape
  PROJECTS=%w{android-client builder ios-client rails3 web-client}

  # Returns true if the supplied Git commit hash or reference exists
  def self.commit_exists?(commit_id)
    `git rev-parse #{commit_id}`
    if $? == 0
      true
    else
      raise "Invalid commit/ref ID: #{commit_id}"
    end
  end

  def self.compare(upstream, head)
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

  def promote_commit(commit_id, upstream)
    commit_exists? commit_id
    run_script <<-EOH
      git stash
      git checkout master
      git pull
      git checkout staging
      git reset --hard origin/staging
      git cherry-pick #{commit_id}
      git push origin staging
    EOH
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

