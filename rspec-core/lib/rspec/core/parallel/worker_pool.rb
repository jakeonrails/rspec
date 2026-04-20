RSpec::Support.require_rspec_core "parallel/channel"
RSpec::Support.require_rspec_core "parallel/worker"

module RSpec
  module Core
    module Parallel
      # Master-side pool that forks N workers, dispatches work units on
      # demand, and yields each event arriving from any worker to the
      # caller's block. The caller (typically a Rehydrator + reporter
      # driver) decides what to do with events -- this class is pure
      # plumbing: forks, IO.select, queue, lifecycle.
      #
      # Correctness invariants:
      #
      #   1. Always drain a worker's up-pipe before sending it new work.
      #      We learn a pipe is writable via IO.select's writers array,
      #      but never issue `send_to_worker` outside of that select.
      #      Under backpressure the kernel refuses the write, select
      #      won't mark us writable, and we keep draining readable pipes
      #      instead. No deadlock.
      #
      #   2. Signal handling: SIGINT / SIGTERM to master marks the pool
      #      aborting, then TERMs every live worker, waits up to
      #      KILL_TIMEOUT per worker, and KILLs stragglers. Pipes closed
      #      after each worker reaps. No orphans.
      #
      # @private
      class WorkerPool
        KILL_TIMEOUT = 5.0 # seconds

        WorkerRecord = Struct.new(:number, :pid, :channel, :state) do
          # state transitions: :idle -> :busy -> :idle -> ... -> :exited
          def idle?;   state == :idle;   end
          def busy?;   state == :busy;   end
          def exited?; state == :exited; end
        end

        def initialize(runner, worker_count)
          @runner        = runner
          @worker_count  = worker_count
          @configuration = runner.configuration
          @workers       = []
          @aborting      = false
        end

        # queue: an array of group lookup keys (source-location strings).
        # Yields each message arriving from any worker, in arrival order:
        #   [:event, event_name, worker_number, payload]
        #   [:group_finished, key, :ok|:error]
        #   [:worker_exit, worker_number]
        def run(queue, &block)
          remaining = queue.dup
          install_signal_traps

          spawn_workers
          mark_all_idle

          until done?(remaining)
            ready_read, ready_write, _ = IO.select(
              readable_ios,
              writable_ios_for_dispatch(remaining),
              nil,
              0.1
            )

            # Rule #1: drain first, dispatch second.
            Array(ready_read).each do |io|
              worker = worker_for_up_read(io)
              message = worker.channel.receive_from_worker

              if message.nil?
                reap_worker(worker)
              else
                update_worker_state(worker, message)
                block.call(message) if block
              end
            end

            Array(ready_write).each do |io|
              next if remaining.empty?
              worker = worker_for_down_write(io)
              next unless worker && worker.idle? && !@aborting
              key = remaining.shift
              worker.channel.send_to_worker([:run_group, key])
              worker.state = :busy
            end

            break if @aborting
          end

          shutdown_workers(&block)
        ensure
          restore_signal_traps
        end

      private

        def spawn_workers
          @worker_count.times do |n|
            channel = Channel.new
            pid = Process.fork do
              channel.close_master_ends
              Worker.new(@runner, channel, n).run
              # Kernel#exit (not exit!) so third-party at_exit hooks fire --
              # e.g. Capybara's Selenium driver cleanup. Runner.invoke is
              # idempotent across fork, so the autorun at_exit won't re-run
              # the suite here.
              exit(0)
            end
            Process.detach(pid)
            channel.close_worker_ends
            @workers << WorkerRecord.new(n, pid, channel, :spawning)
          end
        end

        def mark_all_idle
          @workers.each { |w| w.state = :idle }
        end

        def readable_ios
          @workers.reject(&:exited?).map { |w| w.channel.up_read }
        end

        def writable_ios_for_dispatch(remaining)
          return [] if @aborting || remaining.empty?
          @workers.select(&:idle?).map { |w| w.channel.down_write }
        end

        def worker_for_up_read(io)
          @workers.find { |w| w.channel.up_read.equal?(io) }
        end

        def worker_for_down_write(io)
          @workers.find { |w| w.channel.down_write.equal?(io) }
        end

        def update_worker_state(worker, message)
          case message.first
          when :group_finished then worker.state = :idle
          when :worker_exit    then worker.state = :exited
          end
        end

        def done?(remaining)
          remaining.empty? && @workers.all? { |w| w.exited? || w.idle? }
        end

        def reap_worker(worker)
          worker.state = :exited
          worker.channel.close rescue nil
        end

        def shutdown_workers(&block)
          # Signal "no more work" by closing master's down-write end. Each
          # worker's receive_from_master returns nil and they exit their
          # runloop, sending :worker_exit before closing.
          @workers.each do |w|
            next if w.exited?
            begin
              w.channel.down_write.close
            rescue IOError
              # already closed
            end
          end

          if @aborting
            force_terminate_workers
          else
            drain_remaining_events(&block)
          end

          @workers.each { |w| w.channel.close rescue nil }
        end

        def drain_remaining_events(&block)
          deadline = Time.now + KILL_TIMEOUT
          until @workers.all?(&:exited?) || Time.now > deadline
            ready, = IO.select(readable_ios, nil, nil, 0.1)
            Array(ready).each do |io|
              worker = worker_for_up_read(io)
              msg = worker.channel.receive_from_worker
              if msg.nil?
                worker.state = :exited
              else
                update_worker_state(worker, msg)
                block.call(msg) if block
              end
            end
          end
          force_terminate_workers unless @workers.all?(&:exited?)
        end

        def force_terminate_workers
          @workers.reject(&:exited?).each do |w|
            begin
              Process.kill(:TERM, w.pid)
            rescue Errno::ESRCH
              # already gone
            end
          end

          deadline = Time.now + KILL_TIMEOUT
          until @workers.all? { |w| w.exited? || !process_alive?(w.pid) } || Time.now > deadline
            sleep 0.05
          end

          @workers.each do |w|
            next if w.exited? || !process_alive?(w.pid)
            Process.kill(:KILL, w.pid) rescue nil
            w.state = :exited
          end
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        def install_signal_traps
          @old_int  = Signal.trap(:INT)  { @aborting = true }
          @old_term = Signal.trap(:TERM) { @aborting = true }
        end

        def restore_signal_traps
          Signal.trap(:INT,  @old_int)  if @old_int
          Signal.trap(:TERM, @old_term) if @old_term
        end
      end
    end
  end
end
