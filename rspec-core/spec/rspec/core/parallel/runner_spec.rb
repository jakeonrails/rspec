require 'tmpdir'
require 'rspec/core/parallel/runner'

module RSpec::Core::Parallel
  RSpec.describe Runner, :if => Process.respond_to?(:fork) do
    # These tests drive the real fork pipeline end-to-end: forks
    # workers, runs groups, ships events back, reaps cleanly.
    # Kept short (2 workers, 2 groups) so CI time stays manageable.
    #
    # Hook invocations that happen inside a worker are observed by
    # having each worker append a line to a tmpfile. The master
    # reads the file after the pool returns.

    let(:tmpdir)          { Dir.mktmpdir("rspec-parallel-runner") }
    let(:before_fork_log) { File.join(tmpdir, "before_fork.log") }
    let(:setup_log)       { File.join(tmpdir, "setup.log") }
    let(:teardown_log)    { File.join(tmpdir, "teardown.log") }

    after do
      FileUtils.rm_rf(tmpdir)
    end

    def build_configuration
      config = RSpec::Core::Configuration.new
      config.output_stream = StringIO.new
      config.error_stream  = StringIO.new
      config.color_mode    = :off
      config.formatter     = 'progress'
      config
    end

    def build_world(configuration)
      RSpec::Core::World.new(configuration)
    end

    def with_isolated_rspec_state
      saved_config   = RSpec.configuration
      saved_world    = RSpec.instance_variable_get(:@world)
      yield
    ensure
      RSpec.instance_variable_set(:@configuration, saved_config)
      RSpec.instance_variable_set(:@world, saved_world)
    end

    it "fires hooks in master/worker roles, dispatches across workers, and returns 0 on pass" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)

        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        bf_log = before_fork_log; su_log = setup_log; td_log = teardown_log

        config.parallelize_before_fork do
          File.open(bf_log, "a") { |f| f.puts "master:#{Process.pid}" }
        end
        config.parallelize_setup do |n|
          File.open(su_log, "a") { |f| f.puts "worker:#{n}:#{Process.pid}" }
        end
        config.parallelize_teardown do |n|
          File.open(td_log, "a") { |f| f.puts "worker:#{n}:#{Process.pid}" }
        end

        group_a = RSpec::Core::ExampleGroup.describe("A") { it("passes a") {} }
        group_b = RSpec::Core::ExampleGroup.describe("B") { it("passes b") {} }
        [group_a, group_b].each { |g| world.record(g) }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = described_class.new(config, world, 2)
        exit_code = runner.run_specs([group_a, group_b])

        expect(exit_code).to eq(0)

        expect(File.readlines(bf_log).size).to eq(1)

        setup_lines    = File.readlines(su_log)
        teardown_lines = File.readlines(td_log)
        expect(setup_lines.size).to    eq(2)
        expect(teardown_lines.size).to eq(2)
        expect(setup_lines.map    { |l| l[/worker:(\d)/, 1] }.sort).to eq(%w[0 1])
        expect(teardown_lines.map { |l| l[/worker:(\d)/, 1] }.sort).to eq(%w[0 1])
      end
    end

    it "returns failure_exit_code when any group has a failing example" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        passing = RSpec::Core::ExampleGroup.describe("Pass") { it("passes") {} }
        failing = RSpec::Core::ExampleGroup.describe("Fail") do
          it("fails") { expect(1).to eq(2) }
        end
        [passing, failing].each { |g| world.record(g) }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = described_class.new(config, world, 2)
        expect(runner.run_specs([passing, failing])).to eq(config.failure_exit_code)
      end
    end

    it "cleanly completes an empty run" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        runner = described_class.new(config, world, 2)
        expect(runner.run_specs([])).to eq(0)
      end
    end
  end
end
