#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "optparse"
require "open3"
require "pathname"

class WorkflowRunInterpreter
  def initialize(workflow_path:, job_id: nil, default_workdir: ".", verbose: true)
    @workflow_path = workflow_path
    @job_id = job_id
    @default_workdir = default_workdir
    @verbose = verbose
    @failed = false
  end

  def run!
    wf = YAML.load_file(@workflow_path)
    jobs = wf.fetch("jobs")

    job_key = @job_id || infer_single_job_id(jobs)
    raise "Job not found: #{job_key}" unless jobs.key?(job_key)

    job = jobs.fetch(job_key)
    steps = job.fetch("steps")

    job_env = normalize_hash(job["env"])

    log "Interpreting workflow=#{@workflow_path} job=#{job_key}"

    steps.each_with_index do |step, idx|
      next unless step.is_a?(Hash)

      name = step["name"] || "(unnamed step #{idx + 1})"
      if_cond = step["if"]
      run_cmd = step["run"]

      if run_cmd.nil?
        # Option A: we only execute run: steps. Everything else is skipped.
        next
      end

      should_run = should_run_step?(if_cond)
      log "==> #{name} (if: #{if_cond || 'none'}) #{should_run ? '' : '[SKIPPED]'}"
      next unless should_run

      shell = (step["shell"] || default_shell).to_s
      step_env = job_env.merge(normalize_hash(step["env"]))
      continue_on_error = !!step["continue-on-error"]

      step_env = expand_expressions_in_env(step_env)
      expanded_cmd = expand_expressions(run_cmd.to_s, step_env)

      workdir = resolve_workdir(step["working-directory"])
      status = exec_step(expanded_cmd, shell: shell, workdir: workdir, env: step_env)

      if status.success?
        next
      end

      @failed = true
      if continue_on_error
        log "Step failed but continue-on-error=true; continuing."
        next
      end

      raise "Step failed: #{name}"
    end
  end

  private

  def infer_single_job_id(jobs)
    keys = jobs.keys
    return keys.first if keys.length == 1
    raise "Multiple jobs present; pass --job. Jobs: #{keys.join(', ')}"
  end

  def normalize_hash(obj)
    return {} if obj.nil?
    raise "Expected mapping, got #{obj.class}" unless obj.is_a?(Hash)
    obj.transform_keys(&:to_s).transform_values { |v| v.to_s }
  end

  def default_shell
    # GitHub-hosted runners typically have:
    # - ubuntu/macos: bash
    # - windows: pwsh
    Gem.win_platform? ? "pwsh" : "bash"
  end

  def resolve_workdir(step_workdir)
    wd = step_workdir.to_s.strip
    base = @default_workdir.to_s.strip
    base = "." if base.empty?

    if wd.empty?
      File.expand_path(base)
    elsif Pathname.new(wd).absolute?
      wd
    else
      File.expand_path(File.join(base, wd))
    end
  end

  def should_run_step?(if_cond)
    return true if if_cond.nil?
    cond = if_cond.to_s.strip

    # Minimal support. Anything else is skipped (Option A stays simple).
    return true if cond == "always()"
    return !@failed if cond == "success()"
    return @failed if cond == "failure()"

    log "Skipping step due to unsupported if: #{cond.inspect}"
    false
  end

  def exec_step(cmd, shell:, workdir:, env:)
    log "workdir=#{workdir}"
    log "shell=#{shell}"
    log "command=#{cmd.inspect}"

    stdout_str = +""
    stderr_str = +""

    status = nil

    if shell.start_with?("pwsh") || shell.start_with?("powershell")
      # -Command accepts multi-line scripts fine.
      Open3.popen3(env, "pwsh", "-NoProfile", "-NonInteractive", "-Command", cmd, chdir: workdir) do |_stdin, stdout, stderr, wait_thr|
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
      end
    else
      # Use bash with strict-ish behavior. We keep it simple and let the script decide.
      Open3.popen3(env, "bash", "-lc", cmd, chdir: workdir) do |_stdin, stdout, stderr, wait_thr|
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
      end
    end

    $stdout.write(stdout_str) unless stdout_str.empty?
    $stderr.write(stderr_str) unless stderr_str.empty?

    status
  end

  def expand_expressions_in_env(env_hash)
    env_hash.transform_values { |v| expand_expressions(v.to_s, env_hash) }
  end

  def expand_expressions(str, local_env)
    s = str.dup

    # Replace ${{ secrets.NAME }} with ENV["NAME"] (must be provided by wrapper workflow).
    s.gsub!(/\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}/) do
      key = Regexp.last_match(1)
      val = ENV[key]
      raise "Secret #{key} referenced but not available. Export it in wrapper workflow env: #{key}: ${{ secrets.#{key} }}" if val.nil? || val.empty?
      val
    end

    # Replace ${{ env.NAME }} with local env or process env.
    s.gsub!(/\$\{\{\s*env\.([A-Za-z0-9_]+)\s*\}\}/) do
      key = Regexp.last_match(1)
      val = local_env[key] || ENV[key]
      raise "env.#{key} referenced but not available" if val.nil? || val.empty?
      val
    end

    s
  end

  def log(msg)
    return unless @verbose
    $stderr.puts(msg)
  end
end

options = {
  workflow: nil,
  job: nil,
  default_workdir: ".",
  verbose: true,
}

OptionParser.new do |opts|
  opts.banner = "Usage: run_workflow_run_steps.rb --workflow PATH [--job JOB_ID] [--default-working-directory DIR]"

  opts.on("--workflow PATH", "Path to workflow YAML to interpret") { |v| options[:workflow] = v }
  opts.on("--job JOB_ID", "Job id to run (required if workflow has multiple jobs)") { |v| options[:job] = v }
  opts.on("--default-working-directory DIR", "Default working directory for run steps (e.g. repo)") { |v| options[:default_workdir] = v }
  opts.on("--[no-]verbose", "Verbose logging (default: true)") { |v| options[:verbose] = v }
end.parse!

raise "--workflow is required" if options[:workflow].nil? || options[:workflow].strip.empty?

interpreter = WorkflowRunInterpreter.new(
  workflow_path: options[:workflow],
  job_id: options[:job],
  default_workdir: options[:default_workdir],
  verbose: options[:verbose],
)

interpreter.run!


