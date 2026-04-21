require 'rspec/core/parallel/worker_pool'

module RSpec::Core::Parallel
  RSpec.describe WorkerPool do
    before { skip "fork not available on this platform" unless Process.respond_to?(:fork) }

    # Minimal runner double: the pool only needs #configuration, #world.
    # Our test workers don't call .run_specs -- they're replaced by a
    # test-only Worker substitute that echoes work back as events.
    let(:runner) { instance_double("RSpec::Core::Runner", :configuration => nil, :world => nil) }

    # Replace Worker inside the pool's fork block with a test shim that
    # echoes each received work item back as two events, then exits on EOF.
    before do
      stub_const("RSpec::Core::Parallel::Worker", Class.new do
        def initialize(_runner, channel, worker_number)
          @channel = channel
          @worker_number = worker_number
        end

        def run
          loop do
            msg = @channel.receive_from_parent
            break if msg.nil?
            _, key = msg
            @channel.send_to_parent([:event, :example_finished, @worker_number, [:raw, { :key => key }]])
            @channel.send_to_parent([:group_finished, key, :ok])
          end
          @channel.send_to_parent([:worker_exit, @worker_number])
          @channel.close
        end
      end)
    end

    it "distributes work across workers and yields every event to the block" do
      pool  = described_class.new(runner, 2)
      queue = ["spec/a_spec.rb:1", "spec/b_spec.rb:1", "spec/c_spec.rb:1", "spec/d_spec.rb:1"]
      events = []

      pool.run(queue) { |msg| events << msg }

      group_finished = events.select { |e| e.first == :group_finished }
      expect(group_finished.map { |e| e[1] }).to match_array(queue)

      example_finished = events.select { |e| e.first == :event && e[1] == :example_finished }
      expect(example_finished.size).to eq(4)

      # Both workers participated (neither starved).
      workers_used = example_finished.map { |e| e[2] }.uniq
      expect(workers_used.size).to eq(2)

      worker_exits = events.select { |e| e.first == :worker_exit }.map { |e| e[1] }
      expect(worker_exits).to match_array([0, 1])
    end

    it "handles the case where there are fewer work units than workers" do
      pool = described_class.new(runner, 4)
      events = []

      pool.run(["spec/only_spec.rb:1"]) { |msg| events << msg }

      group_finished = events.select { |e| e.first == :group_finished }
      expect(group_finished.size).to eq(1)

      worker_exits = events.select { |e| e.first == :worker_exit }
      expect(worker_exits.size).to eq(4)
    end

    it "completes cleanly with an empty queue (no workers get work, all exit)" do
      pool = described_class.new(runner, 2)
      events = []

      pool.run([]) { |msg| events << msg }

      expect(events.select { |e| e.first == :group_finished }).to be_empty
      expect(events.select { |e| e.first == :worker_exit }.size).to eq(2)
    end

    context "at_exit hooks in workers" do
      # Regression: `exit!(0)` in the worker fork block used to skip at_exit,
      # which leaked Capybara/Selenium headless-browser processes in real
      # Rails suites (one at_exit per worker, N workers, N * (chromedriver +
      # helpers) surviving). Workers now exit via Kernel#exit; this spec
      # locks in the contract by registering a tmpfile-touching at_exit
      # inside the worker shim and asserting it ran.
      it "runs Kernel at_exit hooks registered inside workers before the process terminates" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-parallel-at-exit")
        begin
          stub_const("RSpec::Core::Parallel::Worker", Class.new do
            def initialize(_runner, channel, worker_number)
              @channel = channel
              @worker_number = worker_number
              @marker = File.join(ENV.fetch("RSPEC_PARALLEL_AT_EXIT_DIR"), "worker-#{worker_number}.touched")
              at_exit { File.write(@marker, "ok") }
            end

            def run
              loop do
                msg = @channel.receive_from_parent
                break if msg.nil?
              end
              @channel.send_to_parent([:worker_exit, @worker_number])
              @channel.close
            end
          end)

          ENV["RSPEC_PARALLEL_AT_EXIT_DIR"] = dir
          pool = described_class.new(runner, 2)
          pool.run([]) { |_| }

          # Workers are detached; give them a brief moment to exit through
          # at_exit on a loaded CI machine before we check markers.
          deadline = Time.now + 5
          until Time.now > deadline &&
                File.exist?(File.join(dir, "worker-0.touched")) &&
                File.exist?(File.join(dir, "worker-1.touched"))
            break if File.exist?(File.join(dir, "worker-0.touched")) &&
                     File.exist?(File.join(dir, "worker-1.touched"))
            sleep 0.05
          end

          expect(File).to exist(File.join(dir, "worker-0.touched"))
          expect(File).to exist(File.join(dir, "worker-1.touched"))
        ensure
          ENV.delete("RSPEC_PARALLEL_AT_EXIT_DIR")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "worker crash mid-group" do
      # Shim whose first worker to receive the sentinel key hard-exits. A
      # filesystem marker enforces "crash exactly once" -- the requeue lands
      # on a different worker, which then completes the key normally. This
      # models a segfault / OOM-kill mid-group.
      it "requeues the in-flight key and completes with another worker" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-crash-test")
        marker = File.join(dir, "crashed_once")
        ENV["RSPEC_CRASH_MARKER"] = marker

        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          def run
            loop do
              msg = @channel.receive_from_parent
              break if msg.nil?
              _, key = msg
              if key == "CRASH_ME" && !File.exist?(ENV.fetch("RSPEC_CRASH_MARKER"))
                File.write(ENV.fetch("RSPEC_CRASH_MARKER"), "1")
                # exit! skips at_exit and doesn't send :group_finished --
                # the pipe closes abruptly, simulating a segfault.
                Kernel.exit!(0)
              end
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = ["spec/a_spec.rb:1", "CRASH_ME", "spec/b_spec.rb:1", "spec/c_spec.rb:1"]
        events = []

        begin
          pool.run(queue) { |msg| events << msg }

          finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
          expect(finished_keys).to match_array(queue)

          crash_events = events.select { |e| e.first == :worker_crashed }
          expect(crash_events.size).to eq(1)
          expect(crash_events.first[2]).to eq("CRASH_ME")
        ensure
          ENV.delete("RSPEC_CRASH_MARKER")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "all workers exit with work still queued" do
      # Regression: if every worker crashes (or otherwise exits) while
      # remaining.any?, the run loop used to spin forever on empty
      # IO.selects -- no readable fds, no writable fds, `done?` never
      # true. Now we detect that condition, emit a synthetic
      # :worker_crashed per remaining key, and break.
      it "emits :worker_crashed for every remaining key and returns within bounded time" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-all-crash")
        ENV["RSPEC_ALL_CRASH_DIR"] = dir

        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          # Crash on the very first dispatched key. Both workers will
          # crash -- leaving the rest of the queue undrained -- which is
          # precisely the condition that used to hang the parent.
          def run
            msg = @channel.receive_from_parent
            Kernel.exit!(0) unless msg.nil?
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = Array.new(5) { |i| "spec/q_#{i}_spec.rb:1" }
        events = []

        begin
          start = Time.now
          pool.run(queue) { |msg| events << msg }
          duration = Time.now - start

          # Contract: the run loop exits rather than spinning forever.
          # Without the fail-fast guard, duration would be unbounded.
          expect(duration).to be < 10

          # Every queued key surfaces at least one :worker_crashed event
          # so the caller can count it as "didn't complete." Keys that
          # were dispatched then crashed may surface twice (once from
          # the mid-group-crash requeue path, once from the fail-fast
          # drain); that's harmless over-notification, so we assert
          # coverage rather than equality.
          crashed_keys = events.select { |e| e.first == :worker_crashed }.map { |e| e[2] }.uniq
          expect(crashed_keys).to match_array(queue)

          # Nothing completed successfully -- no :group_finished for any key.
          finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
          expect(finished_keys).to be_empty
        ensure
          ENV.delete("RSPEC_ALL_CRASH_DIR")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "SIGINT handling" do
      # Worker shim that sleeps on each item, simulating slow work --
      # ensures the parent can interrupt mid-run without a race.
      before do
        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          def run
            loop do
              msg = @channel.receive_from_parent
              break if msg.nil?
              _, key = msg
              sleep 5
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)
      end

      # Raise the parent-side trap synchronously via a background thread
      # that fires SIGINT once the pool is inside IO.select. Ruby delivers
      # the trap on the main thread -- the next select iteration sets
      # @aborting and the run loop breaks.
      def trigger_sigint_after(seconds)
        main = Thread.current
        Thread.new do
          sleep seconds
          Process.kill(:INT, Process.pid)
          main # keep reference
        end
      end

      it "stops dispatching, terminates workers, and returns when SIGINT arrives mid-run" do
        pool  = described_class.new(runner, 2)
        queue = Array.new(10) { |i| "spec/long_#{i}_spec.rb:1" }
        events = []

        trigger_sigint_after(0.3)

        start = Time.now
        pool.run(queue) { |msg| events << msg }
        duration = Time.now - start

        # Pool exited well before all 10 * 5s items could finish, and
        # within the KILL_TIMEOUT stages (5s TERM wait + 5s KILL).
        expect(duration).to be < 15

        # Not all queued work was consumed -- confirms we aborted
        # rather than draining the whole queue.
        finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
        expect(finished_keys.size).to be < queue.size

        # All forked workers are reaped, no stragglers alive.
        pool.instance_variable_get(:@workers).each do |w|
          alive = begin
            Process.kill(0, w.pid)
            true
          rescue Errno::ESRCH, Errno::EPERM
            false
          end
          expect(alive).to be(false)
        end
      end

      it "refuses to dispatch any work when SIGINT arrives before the first select" do
        pool  = described_class.new(runner, 2)
        queue = Array.new(4) { |i| "spec/s_#{i}_spec.rb:1" }
        events = []

        # Force @aborting true before the run loop starts by overriding
        # install_signal_traps to also set the flag synchronously. This
        # simulates "SIGINT delivered during spawn" without racing a
        # real signal.
        def pool.install_signal_traps
          super
          @aborting = true
        end

        start_pids = nil
        pool.run(queue) do |msg|
          events << msg
          start_pids ||= @workers.map(&:pid) # rubocop friendly
        end

        # No group_finished events: we bailed before any worker got work.
        expect(events.select { |e| e.first == :group_finished }).to be_empty

        # Workers are reaped cleanly.
        pool.instance_variable_get(:@workers).each do |w|
          alive = begin
            Process.kill(0, w.pid)
            true
          rescue Errno::ESRCH, Errno::EPERM
            false
          end
          expect(alive).to be(false)
        end
      end
    end
  end
end
