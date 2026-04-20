require 'rspec/core/parallel/worker_pool'

module RSpec::Core::Parallel
  RSpec.describe WorkerPool, :if => Process.respond_to?(:fork) do
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
            msg = @channel.receive_from_master
            break if msg.nil?
            _, key = msg
            @channel.send_to_master([:event, :example_finished, @worker_number, [:raw, { :key => key }]])
            @channel.send_to_master([:group_finished, key, :ok])
          end
          @channel.send_to_master([:worker_exit, @worker_number])
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

    context "SIGINT handling" do
      # Worker shim that sleeps on each item, simulating slow work --
      # ensures the master can interrupt mid-run without a race.
      before do
        stub_const("RSpec::Core::Parallel::Worker", Class.new do
          def initialize(_runner, channel, worker_number)
            @channel = channel
            @worker_number = worker_number
          end

          def run
            loop do
              msg = @channel.receive_from_master
              break if msg.nil?
              _, key = msg
              sleep 5
              @channel.send_to_master([:group_finished, key, :ok])
            end
            @channel.send_to_master([:worker_exit, @worker_number])
            @channel.close
          end
        end)
      end

      # Raise the master-side trap synchronously via a background thread
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
                    Process.kill(0, w.pid); true
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
                    Process.kill(0, w.pid); true
                  rescue Errno::ESRCH, Errno::EPERM
                    false
                  end
          expect(alive).to be(false)
        end
      end
    end
  end
end
