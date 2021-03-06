#!/usr/bin/env ruby
# This script contains helpers for running tests

require 'fileutils'
require 'open3'
require 'securerandom'
require 'shellwords'
require 'tmpdir'

# Global options, similar to shopts
$opts = { errexit: true, xtrace: true }

# Set global options.  If a block is given, the options are only active in that
# block.
def set(opts={})
    if block_given?
        old_opts = $opts.dup
        $opts.merge! opts
        yield
        $opts.merge! old_opts
    else
        $opts.merge! opts
    end
end

# Append a random suffix to a string.  If a second argument is given, the prefix
# is overridden by the given string.
def random_suffix(name, env_var=nil)
    return "#{name}-#{SecureRandom.hex(2)}" if env_var.nil?
    "#{ENV.fetch(env_var, name)}-#{SecureRandom.hex(2)}"
end

# Internal helper: print a command line in the log.
def _print_command(*args)
    cmd = args.dup
    cmd.shift if cmd.first.is_a? Hash
    cmd.pop if cmd.last.is_a? Hash
    STDERR.puts "\e[0;1m+ #{cmd.join(" ")}\e[0m" if $opts[:xtrace]
end

# Run the given command line, and return the exit status (as a Process::Status)
def run_with_status(*args)
    _print_command(*args)
    pid = Process.spawn(*args)
    return Process.wait2(pid).last
end

# Run the given command line.  If errexit is set, an error is raised on failure.
def run(*args)
    status = run_with_status(*args)
    return unless $opts[:errexit]
    unless status.success?
        # Print an error at the failure site
        puts "\e[1;31mCommand exited with #{status.exitstatus}\e[0m"
        fail "Command exited with #{status.exitstatus}"
    end
end

# Run the given command line, and return the output (stdout).  If errexit is
# set, an error is raised on failure.
def capture(*args)
    _print_command(*args)
    stdout, status = Open3.capture2(*args)
    if $opts[:errexit]
        unless status.success?
            # Print an error at the failure site
            puts "\e[1;31mCommand exited with #{status.exitstatus}\e[0m"
            fail "Command exited with #{status.exitstatus}"
        end
    end
    stdout.chomp
end

# Log in to the CF installation under test
def login
    run "cf api --skip-ssl-validation api.#{ENV['CF_DOMAIN']}"
    run "cf auth #{ENV['CF_USERNAME']} #{ENV['CF_PASSWORD']}"
end

# Set up temporary org / space in the CF installation under test.
# The org / space will be deleted on exit.
# The org name is available as $CF_ORG.
# The space name is available as $CF_SPACE.
def setup_org_space
    $CF_ORG = random_suffix('org', 'CF_ORG')
    $CF_SPACE = random_suffix('space', 'CF_SPACE')
    at_exit do
        set errexit: false do
            run "cf delete-space -f #{$CF_SPACE}"
            run "cf delete-org -f #{$CF_ORG}"
        end
    end
    run "cf create-org #{$CF_ORG}"
    run "cf target -o #{$CF_ORG}"
    run "cf create-space #{$CF_SPACE}"
    run "cf target -s #{$CF_SPACE}"
end

# Return the path to a test resource (in the `test-resources` directory)
def resource_path(*parts)
    File.join(File.dirname(__dir__), 'test-resources', *parts)
end

# Create a temporary directory and return its name.  The directory will be
# deleted when the test exits.
def mktmpdir
    prefix = File.basename($0).sub(/\.rb$/, '-')
    dir = Dir.mktmpdir(prefix)
    at_exit do
        FileUtils.rm_rf dir, secure: true
    end
    dir
end

# Run a block, retrying the given number of times at a given interval
# The block will be retried if a RuntimeError occurs.
def run_with_retry(retries, interval)
    last_error = nil
    retries.times do
        begin
            yield
            return
        rescue => e
            last_error = e
            sleep interval
        end
    end
    fail RuntimeError, "Command failed after #{retries} times: #{last_error}", last_error.backtrace
end

# Poll the status of a Kubernetes namespace, until all the pods in that
# namespace are ready and all the jobs have run
def wait_for_namespace(namespace, sleep_duration=10)
    loop do
        output = capture("kubectl get pods --namespace #{namespace} --no-headers")
        ready = !output.empty?
        output.each_line do |line|
            name, readiness, status, restarts, age = line.split
            next if status == 'Completed'
            next if status == 'Running' && /^(\d+)\/\1$/ =~ readiness
            ready = false
        end
        break if ready
        sleep sleep_duration
    end
end
