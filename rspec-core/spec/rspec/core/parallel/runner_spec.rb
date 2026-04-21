require 'tmpdir'
require 'rspec/core/parallel/runner'

module RSpec::Core::Parallel
  RSpec.describe Runner do
    before { skip "fork not available on this platform" unless Process.respond_to?(:fork) }

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

    # ExampleGroup#id is derived from `world.num_example_groups_defined_in(file)`,
    # which only increments on `world.record(group)` -- NOT on describe return.
    # In real usage RSpec.describe records in between top-level describes via
    # DSL; these test fixtures use ExampleGroup.describe directly, so we must
    # record each group before declaring the next, or both will get scoped_id=1
    # and collide on id.
    def declare(world, name, &block)
      group = RSpec::Core::ExampleGroup.describe(name, &block)
      world.record(group)
      group
    end

    it "fires hooks in master/worker roles, dispatches across workers, and returns 0 on pass" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)

        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        bf_log = before_fork_log
        su_log = setup_log
        td_log = teardown_log

        config.parallelize_before_fork do
          File.open(bf_log, "a") { |f| f.puts "master:#{Process.pid}" }
        end
        config.parallelize_setup do |n|
          File.open(su_log, "a") { |f| f.puts "worker:#{n}:#{Process.pid}" }
        end
        config.parallelize_teardown do |n|
          File.open(td_log, "a") { |f| f.puts "worker:#{n}:#{Process.pid}" }
        end

        group_a = declare(world, "A") { it("passes a") {} }
        group_b = declare(world, "B") { it("passes b") {} }
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

        passing = declare(world, "Pass") { it("passes") {} }
        failing = declare(world, "Fail") do
          it("fails") { expect(1).to eq(2) }
        end
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

    it "returns failure_exit_code on an empty run when fail_if_no_examples is set" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)
        config.fail_if_no_examples = true

        runner = described_class.new(config, world, 2)
        expect(runner.run_specs([])).to eq(config.failure_exit_code)
      end
    end

    it "orders examples within a group reproducibly across parallel runs given the same seed" do
      # Contract: output *order across workers* is non-deterministic, but
      # for a fixed seed, each group's *within-group* example order is
      # reproducible. Catches regressions where a worker re-seeds after
      # fork or the ordering strategy is re-evaluated with fresh random
      # state instead of inheriting the master's seed via COW.
      order_log_a = File.join(tmpdir, "order_a.log")
      order_log_b = File.join(tmpdir, "order_b.log")

      run = lambda do |log, seed|
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)
          config.seed = seed

          path = log
          group = declare(world, "Ordered") do
            20.times do |i|
              it("example #{i}") { File.open(path, "a") { |f| f.puts i } }
            end
          end
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          runner = described_class.new(config, world, 2)
          runner.run_specs([group])
        end
      end

      run.call(order_log_a, 1234)
      run.call(order_log_b, 1234)

      expect(File.readlines(order_log_a)).to eq(File.readlines(order_log_b))
    end

    it "runs every group when multiple top-level describes share a source line" do
      # Regression: we used to key the queue by metadata[:location] (file:line),
      # which collides when describes are generated in a loop or eval'd from
      # the same line. The first group would run twice and the later groups
      # would silently disappear -- failures in them would never surface.
      #
      # We simulate the collision by forcing two groups to advertise the same
      # :location metadata. ExampleGroup#id still differs (scoped_id is a
      # per-file declaration-index path), so both must run.
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        ran_log = File.join(tmpdir, "ran.log")
        path_for_closure = ran_log

        group_one = declare(world, "One") do
          it("runs one") { File.open(path_for_closure, "a") { |f| f.puts "one" } }
        end
        group_two = declare(world, "Two") do
          it("fails two") do
            File.open(path_for_closure, "a") { |f| f.puts "two" }
            expect(1).to eq(2)
          end
        end

        # Force location collision: both groups claim the same file:line.
        collision_location = "./spec/collides_spec.rb:1"
        group_one.metadata[:location] = collision_location
        group_two.metadata[:location] = collision_location

        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = described_class.new(config, world, 2)
        exit_code = runner.run_specs([group_one, group_two])

        expect(File.readlines(ran_log).map(&:chomp)).to match_array(%w[one two])
        expect(exit_code).to eq(config.failure_exit_code)
      end
    end

    it "updates the runtime log with timings for groups that ran, preserving untouched keys" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        log_path = File.join(tmpdir, "runtime.log")
        config.parallel_runtime_log_path = log_path

        group_a = declare(world, "A") { it("passes a") {} }
        group_b = declare(world, "B") { it("passes b") {} }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        # Seed a prior log entry for a spec that isn't in this run --
        # it must survive (filtered-run preservation).
        File.write(log_path, "./spec/filtered_spec.rb:1\t9.999\n")

        runner = described_class.new(config, world, 2)
        expect(runner.run_specs([group_a, group_b])).to eq(0)

        timings = Balancer.read_log(log_path)
        expect(timings["./spec/filtered_spec.rb:1"]).to eq(9.999)
        expect(timings[group_a.id]).to be_a(Float).and(be > 0)
        expect(timings[group_b.id]).to be_a(Float).and(be > 0)
      end
    end
  end
end
