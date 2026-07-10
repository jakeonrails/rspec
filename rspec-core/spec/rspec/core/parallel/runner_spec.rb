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
    # having each worker append a line to a tmpfile. The parent
    # reads the file after the pool returns.

    let(:tmpdir)          { Dir.mktmpdir("rspec-parallel-runner") }
    let(:before_fork_log) { File.join(tmpdir, "before_fork.log") }
    let(:setup_log)       { File.join(tmpdir, "setup.log") }
    let(:teardown_log)    { File.join(tmpdir, "teardown.log") }

    after do
      FileUtils.rm_rf(tmpdir)
    end

    def build_configuration(formatter: 'progress')
      config = RSpec::Core::Configuration.new
      config.output_stream = StringIO.new
      config.error_stream  = StringIO.new
      config.color_mode    = :off
      config.formatter     = formatter
      # Keep specs hermetic: don't read (or write) the cwd's runtime log --
      # a populated log LPT-reorders the queue and breaks specs that rely
      # on dispatch order.
      config.parallel_runtime_log_path = nil
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

    it "fires hooks in parent/worker roles, dispatches across workers, and returns 0 on pass" do
      with_isolated_rspec_state do
        config = build_configuration
        world  = build_world(config)

        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        bf_log = before_fork_log
        su_log = setup_log
        td_log = teardown_log

        config.parallelize_before_fork do
          File.open(bf_log, "a") { |f| f.puts "parent:#{Process.pid}" }
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
      # state instead of inheriting the parent's seed via COW.
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

    # Records parent-reporter notifications so specs can assert on exactly
    # what the user-facing formatter pipeline saw.
    let(:recorder_class) do
      Class.new do
        attr_reader :events

        def initialize
          @events = []
        end

        def example_started(notification)
          @events << [:example_started, notification.example.id]
        end

        def example_finished(notification)
          @events << [:example_finished, notification.example.id]
        end

        def message(notification)
          @events << [:message, notification.message]
        end
      end
    end

    context "worker crash mid-group after events were already emitted" do
      it "discards the crashed attempt's events, retries once, and reports each example exactly once" do
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)

          crash_marker = File.join(tmpdir, "crashed_once")

          crashy = declare(world, "Crashy") do
            it("passes before the crash") {}
            it("kills its worker on the first attempt") do
              unless File.exist?(crash_marker)
                File.write(crash_marker, "1")
                Process.kill(:KILL, Process.pid)
              end
            end
          end
          steady = declare(world, "Steady") { it("passes") {} }
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          recorder = recorder_class.new
          config.reporter.register_listener(recorder, :example_started, :example_finished, :message)

          runner = described_class.new(config, world, 2)
          exit_code = runner.run_specs([crashy, steady])

          # The retry succeeded, so the run passes...
          expect(exit_code).to eq(0)

          # ...but the crash was announced, not swallowed.
          messages = recorder.events.select { |e| e.first == :message }.map(&:last)
          expect(messages.grep(/exited unexpectedly.*requeued/m)).not_to be_empty

          # No duplicate notifications: the crashed attempt's buffered
          # events were voided; only the successful attempt reached the
          # reporter. (Regression: each replayed id used to appear 2-3x,
          # inflating example counts.)
          started = recorder.events.select { |e| e.first == :example_started }.map(&:last)
          expect(started.sort).to eq(started.uniq.sort)
          expect(started).to match_array((crashy.examples + steady.examples).map(&:id))
        end
      end
    end

    context "poison group (crashes on every attempt)" do
      it "caps retries, attributes a visible non-example failure, and honors error_exit_code" do
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)
          config.error_exit_code = 33

          doomed = declare(world, "Doomed") do
            it("kills its worker every time") { Process.kill(:KILL, Process.pid) }
          end
          fine = declare(world, "Fine") { it("passes") {} }
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          recorder = recorder_class.new
          config.reporter.register_listener(recorder, :example_started, :example_finished, :message)

          runner = described_class.new(config, world, 2)
          exit_code = runner.run_specs([doomed, fine])

          # Crashed group == non-example failure (like a failed suite hook).
          expect(world.non_example_failure).to be(true)
          expect(exit_code).to eq(33)

          # The crash is visible in the output with group attribution.
          output = config.output_stream.string
          expect(output).to include("An error occurred while running #{doomed.id.inspect}")
          expect(output).to match(/exited unexpectedly/)

          # The healthy group still ran to completion, exactly once.
          started = recorder.events.select { |e| e.first == :example_started }.map(&:last)
          expect(started).to eq([fine.examples.first.id])
        end
      end
    end

    context "fail-fast across workers" do
      it "stops dispatching new groups once the fail-fast threshold is met" do
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)
          config.fail_fast = true

          ran_log = File.join(tmpdir, "ran.log")

          groups = []
          groups << declare(world, "FailsFirst") do
            it("fails") do
              File.open(ran_log, "a") { |f| f.puts "FailsFirst" }
              expect(1).to eq(2)
            end
          end
          9.times do |i|
            groups << declare(world, "Slow#{i}") do
              it("passes slowly") do
                File.open(ran_log, "a") { |f| f.puts "Slow#{i}" }
                sleep 0.1
              end
            end
          end
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          runner = described_class.new(config, world, 2)
          exit_code = runner.run_specs(groups)

          expect(exit_code).to eq(config.failure_exit_code)
          expect(world.wants_to_quit).to be(true)

          # The failing group plus at most the in-flight group per worker;
          # nothing else was dispatched. (Timing-tolerant: the invariant is
          # "far fewer than all", not an exact count.)
          ran = File.exist?(ran_log) ? File.readlines(ran_log) : []
          expect(ran.size).to be < 5
        end
      end
    end

    context "before(:suite) failure" do
      it "does not fork workers and honors error_exit_code, like a serial run" do
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)
          config.error_exit_code = 21

          setup_marker = File.join(tmpdir, "worker_setup.log")
          config.parallelize_setup { File.write(setup_marker, "forked!") }
          config.before(:suite) { raise "suite boom" }

          group = declare(world, "NeverRuns") { it("passes") {} }
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          runner = described_class.new(config, world, 2)
          exit_code = runner.run_specs([group])

          expect(exit_code).to eq(21)
          expect(world.non_example_failure).to be(true)

          # No worker was ever forked: parallelize_setup never fired.
          expect(File.exist?(setup_marker)).to be(false)
          expect(config.output_stream.string).to include("suite boom")
        end
      end
    end

    context "example status persistence (via Core::Runner)" do
      it "persists real statuses and run times from worker results, so --only-failures works" do
        with_isolated_rspec_state do
          config = build_configuration
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)

          persistence_path = File.join(tmpdir, "statuses.txt")
          config.example_status_persistence_file_path = persistence_path
          config.parallel_workers = 2

          passing = declare(world, "Passes") { it("passes") {} }
          failing = declare(world, "Fails") do
            it("fails") { expect(1).to eq(2) }
          end
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          core_runner = RSpec::Core::Runner.new(
            RSpec::Core::ConfigurationOptions.new([]), config, world
          )
          exit_code = core_runner.run_specs([passing, failing])
          core_runner.send(:persist_example_statuses)

          expect(exit_code).to eq(config.failure_exit_code)

          rows = RSpec::Core::ExampleStatusPersister.load_from(persistence_path)
          statuses = rows.to_h { |row| [row[:example_id], row[:status]] }

          # Regression: these all used to persist as "unknown" (the parent's
          # own Example objects never execute in a parallel run), which made
          # a subsequent --only-failures run filter everything out.
          expect(statuses.fetch(passing.examples.first.id)).to eq("passed")
          expect(statuses.fetch(failing.examples.first.id)).to eq("failed")

          run_times = rows.map { |row| row[:run_time] }
          expect(run_times).to all(match(/\d/))
        end
      end
    end

    context "JSON formatter under parallel" do
      it "emits per-example status and run_time (not blank snapshots from example_started)" do
        with_isolated_rspec_state do
          config = build_configuration(formatter: 'json')
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)

          mixed = declare(world, "Mixed") do
            it("passes") {}
            it("fails") { expect(1).to eq(2) }
            it("is pending") do
              pending("wip")
              raise "not done"
            end
          end
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          runner = described_class.new(config, world, 2)
          runner.run_specs([mixed])

          require 'json'
          payload = JSON.parse(config.output_stream.string)
          examples = payload.fetch("examples")
          expect(examples.size).to eq(3)

          expect(examples.map { |ex| ex["status"] }).to match_array(%w[passed failed pending])
          examples.each do |ex|
            expect(ex["run_time"]).to be_a(Numeric), "expected run_time for #{ex['id']}"
          end
        end
      end
    end

    context "stateful formatter output (documentation)" do
      it "keeps each group's output contiguous even when groups run concurrently" do
        with_isolated_rspec_state do
          config = build_configuration(formatter: 'documentation')
          world  = build_world(config)
          RSpec.instance_variable_set(:@configuration, config)
          RSpec.instance_variable_set(:@world, world)

          group_a = declare(world, "GroupA") do
            3.times { |i| it("a#{i}") { sleep 0.02 } }
          end
          group_b = declare(world, "GroupB") do
            3.times { |i| it("b#{i}") { sleep 0.02 } }
          end
          world.instance_variable_set(:@example_groups_and_filters_loaded, true)

          runner = described_class.new(config, world, 2)
          expect(runner.run_specs([group_a, group_b])).to eq(0)

          lines = config.output_stream.string.lines.map(&:rstrip).reject(&:empty?)
          a_index = lines.index("GroupA")
          b_index = lines.index("GroupB")
          expect(a_index).not_to be_nil
          expect(b_index).not_to be_nil

          # Whole-group flushes mean each header is immediately followed by
          # all of its own examples (in whatever within-group order the
          # seed produced) -- never interleaved with the other worker's
          # output.
          expect(lines[a_index + 1, 3]).to match_array(["  a0", "  a1", "  a2"])
          expect(lines[b_index + 1, 3]).to match_array(["  b0", "  b1", "  b2"])
        end
      end
    end

    context "LPT queue balancing vs. explicit ordering" do
      let(:timings) { { "b" => 9.0, "a" => 1.0 } }
      let(:queue)   { %w[a b] }

      it "reorders the queue slowest-first under the default (random) ordering" do
        config = build_configuration
        runner = described_class.new(config, build_world(config), 2)

        expect(runner.send(:balanced_queue, queue, timings)).to eq(%w[b a])
      end

      it "leaves the queue untouched under --order defined" do
        config = build_configuration
        config.force(:order => 'defined')
        runner = described_class.new(config, build_world(config), 2)

        expect(runner.send(:balanced_queue, queue, timings)).to eq(%w[a b])
      end

      it "leaves the queue untouched under a custom global ordering" do
        config = build_configuration
        config.register_ordering(:global) { |groups| groups }
        runner = described_class.new(config, build_world(config), 2)

        expect(runner.send(:balanced_queue, queue, timings)).to eq(%w[a b])
      end
    end
  end
end
