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
          expect(crash_events.first[3]).to eq(:requeued)
        ensure
          ENV.delete("RSPEC_CRASH_MARKER")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "poison group (crashes every worker it lands on)" do
      # Without the attempt cap, a group that reliably kills its host
      # worker would be requeued forever, crashing workers one by one
      # until the pool collapsed and every other group surfaced as
      # crashed too.
      it "gives up after MAX_ATTEMPTS and lets surviving workers finish the rest" do
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
              Kernel.exit!(0) if key == "POISON"
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 3)
        queue = ["POISON", "spec/a_spec.rb:1", "spec/b_spec.rb:1", "spec/c_spec.rb:1"]
        events = []

        pool.run(queue) { |msg| events << msg }

        poison_crashes = events.select { |e| e.first == :worker_crashed && e[2] == "POISON" }
        expect(poison_crashes.map { |e| e[3] }).to eq([:requeued, :gave_up])

        finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
        expect(finished_keys).to match_array(queue - ["POISON"])
      end
    end

    context "worker announces :worker_exit while a group is in flight" do
      # Models a spec calling `exit`: SystemExit unwinds Worker#run, whose
      # ensure block sends :worker_exit -- but no :group_finished ever
      # arrives for the dispatched key. The key used to silently vanish.
      it "recovers the in-flight key exactly like a pipe-EOF crash" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-exit-test")
        marker = File.join(dir, "exited_once")
        ENV["RSPEC_EXIT_MARKER"] = marker

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
              if key == "EXIT_ME" && !File.exist?(ENV.fetch("RSPEC_EXIT_MARKER"))
                File.write(ENV.fetch("RSPEC_EXIT_MARKER"), "1")
                @channel.send_to_parent([:worker_exit, @worker_number])
                @channel.close
                Kernel.exit!(0)
              end
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = ["spec/a_spec.rb:1", "EXIT_ME", "spec/b_spec.rb:1"]
        events = []

        begin
          pool.run(queue) { |msg| events << msg }

          finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
          expect(finished_keys).to match_array(queue)

          crash_events = events.select { |e| e.first == :worker_crashed }
          expect(crash_events.size).to eq(1)
          expect(crash_events.first[2]).to eq("EXIT_ME")
          expect(crash_events.first[3]).to eq(:requeued)
        ensure
          ENV.delete("RSPEC_EXIT_MARKER")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "corrupt frame from a worker" do
      # A worker killed mid-write leaves a truncated/garbage frame in the
      # up-pipe. The parent must fold that into the normal crash/requeue
      # path -- not raise a Marshal error at the user.
      it "treats the sender as crashed and completes the key elsewhere" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-garble-test")
        marker = File.join(dir, "garbled_once")
        ENV["RSPEC_GARBLE_MARKER"] = marker

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
              if key == "GARBLE" && !File.exist?(ENV.fetch("RSPEC_GARBLE_MARKER"))
                File.write(ENV.fetch("RSPEC_GARBLE_MARKER"), "1")
                io = @channel.instance_variable_get(:@up_write)
                io.write("12\nnot marshal!")
                io.flush
                Kernel.exit!(0)
              end
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = ["spec/a_spec.rb:1", "GARBLE", "spec/b_spec.rb:1"]
        events = []

        begin
          expect { pool.run(queue) { |msg| events << msg } }.not_to raise_error

          finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
          expect(finished_keys).to match_array(queue)

          crash_events = events.select { |e| e.first == :worker_crashed }
          expect(crash_events.map { |e| e[2] }).to eq(["GARBLE"])
        ensure
          ENV.delete("RSPEC_GARBLE_MARKER")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "EPIPE on dispatch (worker died while idle)" do
      # A worker that dies between groups leaves its down-pipe with no
      # reader; the next dispatch write raises Errno::EPIPE. The parent
      # must fold that into the crash path (requeue the key, reap the
      # record) rather than aborting the run with a broken-pipe backtrace.
      # Exercised directly (no fork): racing a real worker's close against
      # the parent's dispatch is inherently nondeterministic.
      it "requeues the key and reaps the worker instead of raising" do
        pool    = described_class.new(runner, 0)
        channel = Channel.new
        channel.instance_variable_get(:@down_read).close # no reader anywhere -> EPIPE on write

        dead_pid = Process.fork { exit!(0) }
        Process.waitpid(dead_pid)

        record = described_class::WorkerRecord.new(7, dead_pid, channel, :idle, nil)
        pool.instance_variable_get(:@workers) << record
        remaining = ["spec/a_spec.rb:1"]

        expect { pool.send(:dispatch_to, record, remaining) }.not_to raise_error

        expect(remaining).to eq(["spec/a_spec.rb:1"]) # key back in the queue
        expect(record.exited?).to be(true)
        expect(record.current_key).to be_nil
      end
    end

    context "stop_dispatching! (parent-coordinated fail-fast)" do
      # The caller flips the pool into drain mode from inside the event
      # block (as Parallel::Runner does when the fail-fast threshold is
      # met): in-flight groups finish and report, undispatched keys are
      # simply never run -- and never misreported as crashes.
      it "finishes in-flight groups, skips the rest, and shuts down cleanly" do
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
              sleep 0.05
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = Array.new(8) { |i| "spec/ff_#{i}_spec.rb:1" }
        events = []

        pool.run(queue) do |msg|
          events << msg
          pool.stop_dispatching! if msg.first == :group_finished
        end

        finished = events.select { |e| e.first == :group_finished }
        # The two in-flight groups (one per worker) complete; nothing else
        # is dispatched after the first :group_finished flips drain mode.
        expect(finished.size).to be_between(1, 2)

        expect(events.select { |e| e.first == :worker_crashed }).to be_empty
        expect(events.select { |e| e.first == :worker_exit }.map { |e| e[1] }).to match_array([0, 1])
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
        with_isolated_stderr { pool.run(queue) { |msg| events << msg } }
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

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    context "graceful SIGTERM shutdown of workers" do
      # Worker shim that mimics Worker#run's structure: an ensure block
      # standing in for `parallelize_teardown` hooks, plus a Kernel
      # at_exit hook. When the abort path TERMs the worker mid-group,
      # both must still run -- the worker traps TERM and exits via
      # SystemExit rather than being killed raw.
      before do
        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
            dir = ENV.fetch("RSPEC_TERM_MARKER_DIR")
            @teardown_marker = File.join(dir, "teardown-#{worker_number}.touched")
            at_exit { File.write(File.join(dir, "at-exit-#{worker_number}.touched"), "ok") }
          end

          def run
            loop do
              msg = @channel.receive_from_parent
              break if msg.nil?
              sleep 30 # long enough that TERM always lands mid-group
            end
          ensure
            File.write(@teardown_marker, "ok")
          end
        end)
      end

      def trigger_sigterm_after(seconds)
        Thread.new do
          sleep seconds
          Process.kill(:TERM, Process.pid)
        end
      end

      it "runs the worker's teardown (ensure) and at_exit hooks when the abort path TERMs it" do
        require 'tmpdir'
        dir = Dir.mktmpdir("rspec-parallel-term")
        ENV["RSPEC_TERM_MARKER_DIR"] = dir

        begin
          pool  = described_class.new(runner, 2)
          queue = Array.new(4) { |i| "spec/t_#{i}_spec.rb:1" }

          trigger_sigterm_after(0.3)

          start = Time.now
          with_isolated_stderr { pool.run(queue) { |_msg| } }
          duration = Time.now - start

          # Well under the TERM-then-KILL escalation window: the workers
          # exited from the graceful trap, not from the SIGKILL backstop.
          expect(duration).to be < 10

          2.times do |n|
            expect(File).to exist(File.join(dir, "teardown-#{n}.touched"))
            expect(File).to exist(File.join(dir, "at-exit-#{n}.touched"))
          end

          pool.instance_variable_get(:@workers).each do |w|
            expect(process_alive?(w.pid)).to be(false)
          end
        ensure
          ENV.delete("RSPEC_TERM_MARKER_DIR")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "SIGINT delivered directly to workers" do
      # A terminal Ctrl-C hits the whole foreground process group, so
      # every worker receives SIGINT alongside the parent. Workers must
      # ignore it -- the parent coordinates shutdown via SIGTERM -- or
      # each Ctrl-C would kill workers mid-group and misreport crashes.
      it "is ignored: workers finish their in-flight groups normally" do
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
              sleep 1
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = ["spec/a_spec.rb:1", "spec/b_spec.rb:1"]
        events = []

        # Send INT straight to the workers (not the parent) once they
        # are mid-group.
        Thread.new do
          sleep 0.3
          pool.instance_variable_get(:@workers).each do |w|
            begin
              Process.kill(:INT, w.pid)
            rescue Errno::ESRCH
              nil
            end
          end
        end

        pool.run(queue) { |msg| events << msg }

        expect(events.select { |e| e.first == :worker_crashed }).to be_empty
        finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
        expect(finished_keys).to match_array(queue)
      end
    end

    context "second interrupt escalation" do
      # RSpec's documented contract: a second Ctrl-C force quits. The
      # first signal flips the pool into abort mode; the second KILLs
      # every live worker and exits the parent immediately via `exit!`.
      it "KILLs workers and force-exits the parent on the second signal" do
        pool = described_class.new(runner, 0)
        allow(pool).to receive(:exit!)

        sleeper_pid = Process.fork do
          Signal.trap(:TERM, "DEFAULT")
          sleep 600
          exit!(0)
        end
        Process.detach(sleeper_pid)

        begin
          record = described_class::WorkerRecord.new(0, sleeper_pid, nil, :busy, nil)
          pool.instance_variable_get(:@workers) << record

          with_isolated_stderr do
            pool.send(:abort_or_force_quit, "INT") # first: abort mode, no exit
          end
          expect(pool.instance_variable_get(:@aborting)).to be(true)
          expect(pool).not_to have_received(:exit!)
          expect(process_alive?(sleeper_pid)).to be(true)

          pool.send(:abort_or_force_quit, "INT") # second: force quit
          expect(pool).to have_received(:exit!).with(1)

          deadline = Time.now + 5
          sleep 0.05 while process_alive?(sleeper_pid) && Time.now < deadline
          expect(process_alive?(sleeper_pid)).to be(false)
        ensure
          begin
            Process.kill(:KILL, sleeper_pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end

      it "announces abort mode on the first INT, truthfully describing teardown and the escape hatch" do
        pool = described_class.new(runner, 0)
        stderr_output = nil

        with_isolated_stderr do
          pool.send(:abort_or_force_quit, "INT")
          stderr_output = $stderr.string
        end

        expect(stderr_output).to include("Received INT")
        # Truthfulness: in-flight work is abandoned (not "finished"), and
        # what actually runs is the teardown hooks.
        expect(stderr_output).to include("abandoned")
        expect(stderr_output).to include("`parallelize_teardown`")
        expect(stderr_output).to include("Interrupt again to force quit")
      end

      it "does not say 'Interrupt again' for TERM, which usually isn't keyboard-driven" do
        pool = described_class.new(runner, 0)
        stderr_output = nil

        with_isolated_stderr do
          pool.send(:abort_or_force_quit, "TERM")
          stderr_output = $stderr.string
        end

        expect(stderr_output).to include("Received TERM")
        expect(stderr_output).to include("Send TERM again to force quit")
        expect(stderr_output).not_to include("Interrupt again")
      end
    end

    context "signal trap restoration" do
      it "restores the pre-existing trap handlers after a run" do
        custom = proc { }
        original_int = Signal.trap(:INT, custom)
        begin
          pool = described_class.new(runner, 2)
          pool.run([]) { |_msg| }

          # Reading the current handler back returns what the pool restored.
          expect(Signal.trap(:INT, custom)).to equal(custom)
        ensure
          Signal.trap(:INT, original_int || "DEFAULT")
        end
      end

      it "restores DEFAULT (not the pool's trap) when the prior handler was reported as nil" do
        # Signal.trap returns nil for handlers installed from C extensions;
        # a truthiness-guarded restore would leak the pool's Proc trap into
        # the rest of the process.
        original_int  = Signal.trap(:INT,  "DEFAULT")
        original_term = Signal.trap(:TERM, "DEFAULT")

        begin
          pool = described_class.new(runner, 0)
          pool.send(:install_signal_traps)
          pool.instance_variable_set(:@old_int, nil)
          pool.instance_variable_set(:@old_term, nil)
          pool.send(:restore_signal_traps)

          int_handler  = Signal.trap(:INT,  "DEFAULT")
          term_handler = Signal.trap(:TERM, "DEFAULT")
          expect(int_handler).not_to be_a(Proc)
          expect(term_handler).not_to be_a(Proc)
        ensure
          Signal.trap(:INT,  original_int  || "DEFAULT")
          Signal.trap(:TERM, original_term || "DEFAULT")
        end
      end
    end

    context "fork failure mid-spawn" do
      # Errno::EAGAIN from fork(2) when the process table (or the user's
      # process limit) is exhausted. Workers forked before the failure
      # must not leak as orphans.
      it "terminates the already-forked workers and re-raises" do
        real_fork = Process.method(:fork)
        fork_calls = 0
        allow(Process).to receive(:fork) do |&block|
          fork_calls += 1
          raise Errno::EAGAIN, "fork(2)" if fork_calls == 2
          real_fork.call(&block)
        end

        pool = described_class.new(runner, 2)

        expect {
          pool.run(["spec/a_spec.rb:1"]) { |_msg| }
        }.to raise_error(Errno::EAGAIN)

        workers = pool.instance_variable_get(:@workers)
        expect(workers.size).to eq(1)
        workers.each do |w|
          expect(process_alive?(w.pid)).to be(false)
        end
      end
    end

    context "slow parallelize_teardown during clean shutdown" do
      # The clean-shutdown drain must give workers far longer than the
      # crash-path KILL_TIMEOUT: `parallelize_teardown` legitimately does
      # slow work (dropping per-worker databases). With KILL_TIMEOUT
      # shrunk below the teardown duration, only the generous
      # SHUTDOWN_TIMEOUT keeps the worker alive long enough to finish.
      it "waits past KILL_TIMEOUT for teardown to complete before escalating" do
        require 'tmpdir'
        stub_const("RSpec::Core::Parallel::WorkerPool::KILL_TIMEOUT", 0.2)

        dir = Dir.mktmpdir("rspec-parallel-slow-teardown")
        ENV["RSPEC_SLOW_TEARDOWN_DIR"] = dir

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
              @channel.send_to_parent([:group_finished, key, :ok])
            end
            sleep 1.0 # slow teardown, longer than the stubbed KILL_TIMEOUT
            File.write(File.join(ENV.fetch("RSPEC_SLOW_TEARDOWN_DIR"), "teardown-#{@worker_number}.done"), "ok")
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        begin
          pool  = described_class.new(runner, 2)
          events = []
          pool.run(["spec/a_spec.rb:1", "spec/b_spec.rb:1"]) { |msg| events << msg }

          worker_exits = events.select { |e| e.first == :worker_exit }.map { |e| e[1] }
          expect(worker_exits).to match_array([0, 1])

          2.times do |n|
            expect(File).to exist(File.join(dir, "teardown-#{n}.done"))
          end
        ensure
          ENV.delete("RSPEC_SLOW_TEARDOWN_DIR")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "slow parallelize_teardown during a user-initiated abort (first Ctrl-C)" do
      # The first INT/TERM must give workers the same generous
      # SHUTDOWN_TIMEOUT window as a clean shutdown -- a teardown that
      # outlives the tight crash-path KILL_TIMEOUT (e.g. a 6s DB drop)
      # has to survive a single Ctrl-C. The user keeps the escape hatch:
      # a second signal force-quits immediately. With KILL_TIMEOUT
      # stubbed below the teardown duration, this spec fails against the
      # old behavior (worker SIGKILLed mid-teardown, no marker written).
      it "waits past KILL_TIMEOUT for teardown to complete before escalating" do
        require 'tmpdir'
        stub_const("RSpec::Core::Parallel::WorkerPool::KILL_TIMEOUT", 0.2)

        dir = Dir.mktmpdir("rspec-parallel-abort-teardown")
        ENV["RSPEC_ABORT_TEARDOWN_DIR"] = dir

        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          def run
            loop do
              msg = @channel.receive_from_parent
              break if msg.nil?
              sleep 30 # long enough that the INT always lands mid-group
            end
          ensure
            sleep 1.0 # slow teardown, longer than the stubbed KILL_TIMEOUT
            File.write(File.join(ENV.fetch("RSPEC_ABORT_TEARDOWN_DIR"), "teardown-#{@worker_number}.done"), "ok")
          end
        end)

        begin
          pool  = described_class.new(runner, 2)
          queue = Array.new(4) { |i| "spec/abort_#{i}_spec.rb:1" }

          Thread.new do
            sleep 0.3
            Process.kill(:INT, Process.pid)
          end

          with_isolated_stderr { pool.run(queue) { |_msg| } }

          2.times do |n|
            expect(File).to exist(File.join(dir, "teardown-#{n}.done"))
          end

          pool.instance_variable_get(:@workers).each do |w|
            expect(process_alive?(w.pid)).to be(false)
          end
        ensure
          ENV.delete("RSPEC_ABORT_TEARDOWN_DIR")
          FileUtils.remove_entry(dir) if File.directory?(dir)
        end
      end
    end

    context "worker announces :worker_setup_failed" do
      # Models a raising `parallelize_setup` hook: the worker ships the
      # distinguishable failure event, then exits through the normal
      # handshake. The pool must pass the event through untouched and
      # recover the worker's in-flight key (if any) so the surviving
      # worker still drains the whole queue.
      it "yields the event to the caller and completes every key on the surviving worker" do
        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          def run
            if @worker_number == 1
              @channel.send_to_parent([:worker_setup_failed, @worker_number, "setup boom"])
            else
              loop do
                msg = @channel.receive_from_parent
                break if msg.nil?
                _, key = msg
                @channel.send_to_parent([:group_finished, key, :ok])
              end
            end
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          end
        end)

        pool  = described_class.new(runner, 2)
        queue = Array.new(4) { |i| "spec/sf_#{i}_spec.rb:1" }
        events = []

        pool.run(queue) { |msg| events << msg }

        setup_failures = events.select { |e| e.first == :worker_setup_failed }
        expect(setup_failures).to eq([[:worker_setup_failed, 1, "setup boom"]])

        # Every key still completed -- worker 0 absorbed the queue,
        # including any key that had already been dispatched to worker 1
        # (recovered by the :worker_exit-while-busy requeue path).
        finished_keys = events.select { |e| e.first == :group_finished }.map { |e| e[1] }
        expect(finished_keys).to match_array(queue)

        expect(events.select { |e| e.first == :worker_exit }.map { |e| e[1] }).to match_array([0, 1])
      end
    end

    context "caller's event block raises" do
      # WorkerPool#run's block belongs to the caller (Parallel::Runner's
      # event dispatch) and can raise -- a formatter bug, a Rehydrator
      # error. The pool must not strand its N forked workers until parent
      # exit (fatal for embedded runners): the ensure path reaps them and
      # closes every channel, while the exception still propagates.
      it "reaps all workers, closes channels, and re-raises" do
        pool  = described_class.new(runner, 2)
        queue = Array.new(4) { |i| "spec/raise_#{i}_spec.rb:1" }

        expect {
          pool.run(queue) { |_msg| raise ArgumentError, "listener exploded" }
        }.to raise_error(ArgumentError, "listener exploded")

        workers = pool.instance_variable_get(:@workers)
        expect(workers.size).to eq(2)

        workers.each do |w|
          expect(process_alive?(w.pid)).to be(false)
          expect(w.channel.up_read).to be_closed
          expect(w.channel.down_write).to be_closed
        end
      end
    end
  end
end
