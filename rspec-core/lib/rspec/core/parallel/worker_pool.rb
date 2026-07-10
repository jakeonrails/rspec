RSpec::Support.require_rspec_core "parallel/channel"
RSpec::Support.require_rspec_core "parallel/worker"

module RSpec
  module Core
    module Parallel
      # Parent-side pool that forks N workers, dispatches work units on
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
      #   2. Signal handling: SIGINT / SIGTERM to parent marks the pool
      #      aborting, then TERMs every live worker, waits up to
      #      KILL_TIMEOUT per worker, and KILLs stragglers. Pipes closed
      #      after each worker reaps. No orphans.
      #
      # @private
      class WorkerPool
        KILL_TIMEOUT = 5.0 # seconds

        # Total dispatch attempts per group key before the pool gives up on
        # it. One retry tolerates a transient crash (OOM kill, flaky native
        # extension) without letting a poison group -- one that crashes
        # every worker it lands on -- cascade through the whole pool.
        MAX_ATTEMPTS = 2

        WorkerRecord = Struct.new(:number, :pid, :channel, :state, :current_key) do
          # state transitions: :idle -> :busy -> :idle -> ... -> :exited
          # current_key: the group key the worker is processing right now,
          # set on dispatch and cleared on :group_finished. If the worker's
          # pipe closes while current_key is set, the worker crashed
          # mid-group and we requeue that key.
          def idle? = state == :idle
          def busy? = state == :busy
          def exited? = state == :exited
        end

        def initialize(runner, worker_count)
          @runner        = runner
          @worker_count  = worker_count
          @configuration = runner.configuration
          @workers       = []
          @aborting      = false
          @draining      = false
          @attempts      = Hash.new(0)
        end

        # Fail-fast support: the caller invokes this (typically from inside
        # the `run` block, on seeing a failure that meets the fail-fast
        # threshold) to stop handing out new work. Undispatched keys stay
        # unrun -- mirroring serial fail-fast, which never reaches them --
        # while workers currently mid-group finish and report normally,
        # after which every worker is shut down via the usual EOF handshake.
        def stop_dispatching!
          @draining = true
        end

        # queue: an array of group lookup keys (source-location strings).
        # Yields each message arriving from any worker, in arrival order:
        #   [:event, event_name, worker_number, payload]
        #   [:group_finished, key, :ok|:error, elapsed, worker_number]
        #   [:worker_crashed, worker_number, key, :requeued|:gave_up]
        #   [:worker_exit, worker_number]
        # The event loop is intentionally kept as a single method so the
        # drain/dispatch/fail-fast ordering stays visible at one glance --
        # splitting it obscures the interleaving invariants.
        # rubocop:disable Metrics/CyclomaticComplexity
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
              receive_from(worker_for_up_read(io), remaining, &block)
            end

            Array(ready_write).each do |io|
              next if remaining.empty?
              worker = worker_for_down_write(io)
              next unless worker&.idle? && !@aborting && !@draining
              dispatch_to(worker, remaining)
            end

            break if @aborting

            # If every worker has exited but work remains (all workers
            # crashed, or all exited before draining the queue), further
            # selects are all-empty and loop forever. Surface a synthetic
            # :worker_crashed per remaining key so the reporter registers
            # them as failures, then bail out. Not applicable while
            # draining: leftover keys are then intentionally unrun.
            if remaining.any? && !@draining && @workers.all?(&:exited?)
              drain_remaining_as_crashed(remaining, &block)
              break
            end
          end

          shutdown_workers(&block)
        ensure
          restore_signal_traps
        end
      # rubocop:enable Metrics/CyclomaticComplexity

      private

        def receive_from(worker, remaining, &block)
          message = worker.channel.receive_from_worker

          if message.nil?
            handle_worker_crash(worker, remaining, &block)
            reap_worker(worker)
          else
            # A worker announcing :worker_exit while still holding a key
            # hit SystemExit mid-group (e.g. a spec called `exit`); the
            # group's outcome never arrived, so recover exactly as for a
            # pipe-EOF crash before recording the exit.
            handle_worker_crash(worker, remaining, &block) if message.first == :worker_exit
            update_worker_state(worker, message)
            block&.call(annotate(worker, message))
          end
        end

        def dispatch_to(worker, remaining)
          key = remaining.shift
          begin
            worker.channel.send_to_worker([:run_group, key])
          rescue Errno::EPIPE
            # The worker died while idle (its end of the down-pipe has no
            # reader). Put the key back for another worker and reap this
            # one; TERM is a no-op if the process is already gone but
            # ensures a wedged-yet-alive worker doesn't outlive the run.
            remaining.unshift(key)
            begin
              Process.kill(:TERM, worker.pid)
            rescue Errno::ESRCH
              nil
            end
            reap_worker(worker)
            return
          end
          @attempts[key] += 1
          worker.state = :busy
          worker.current_key = key
        end

        # The wire-level :group_finished a worker sends doesn't carry its
        # worker number; the parent-side event buffering in Parallel::Runner
        # needs it to know which worker's buffered events to flush. Rebuild
        # the message with the number appended.
        def annotate(worker, message)
          return message unless message.first == :group_finished
          _, key, status, elapsed = message
          [:group_finished, key, status, elapsed, worker.number]
        end

        def spawn_workers
          @worker_count.times do |n|
            channel = Channel.new
            pid = Process.fork do
              # fork-child code; SimpleCov runs in the parent process only.
              # :nocov:
              # Parent installed INT/TERM traps that only set `@aborting`
              # in the parent's scope. Children inherit those traps via
              # fork, which neuters SIGTERM in the worker -- the parent's
              # force_terminate_workers path would then always wait the
              # full KILL_TIMEOUT and fall through to SIGKILL. Reset to
              # default so SIGTERM actually terminates the worker.
              Signal.trap(:INT,  "DEFAULT")
              Signal.trap(:TERM, "DEFAULT")
              channel.close_parent_ends
              Worker.new(@runner, channel, n).run
              # Kernel#exit (not exit!) so third-party at_exit hooks fire --
              # e.g. Capybara's Selenium driver cleanup. Runner.invoke is
              # idempotent across fork, so the autorun at_exit won't re-run
              # the suite here.
              exit(0)
              # :nocov:
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
          return [] if @aborting || @draining || remaining.empty?
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
          when :group_finished
            worker.state = :idle
            worker.current_key = nil
          when :worker_exit
            worker.state = :exited
          end
        end

        # Called when a worker stops without completing its group: pipe EOF,
        # a corrupt/truncated frame, or a :worker_exit that arrives while a
        # key is still in flight (SystemExit raised by a spec). If the
        # worker was holding a key, the group's outcome never arrived:
        # unshift it back so another worker picks it up -- unless the key
        # has already burned MAX_ATTEMPTS, in which case the caller is told
        # we gave up so it can attribute a visible failure. The disposition
        # travels in the yielded event:
        #   [:worker_crashed, worker_number, key, :requeued | :gave_up]
        # No-op during @aborting: the caller is giving up, not redistributing.
        def handle_worker_crash(worker, remaining, &block)
          return if @aborting
          return unless worker.current_key
          crashed_key = worker.current_key
          worker.current_key = nil

          if @attempts[crashed_key] >= MAX_ATTEMPTS || @draining
            block&.call([:worker_crashed, worker.number, crashed_key, :gave_up])
          else
            remaining.unshift(crashed_key)
            block&.call([:worker_crashed, worker.number, crashed_key, :requeued])
          end
        end

        # Called when we detect that every worker is :exited but the
        # queue still has keys. Each remaining key is surfaced as a
        # :worker_crashed event (worker_number nil -- no live worker
        # to attribute it to) so the caller's reporter can mark those
        # groups as failures. Without this, Runner#drive_pool's
        # `queue.all? { |k| statuses[k] == :ok }` would just return
        # false silently and the user wouldn't see which groups never
        # ran.
        def drain_remaining_as_crashed(remaining, &block)
          return unless block
          remaining.shift(remaining.size).each do |key|
            block.call([:worker_crashed, nil, key, :gave_up])
          end
        end

        def done?(remaining)
          (remaining.empty? || @draining) && @workers.all? { |w| w.exited? || w.idle? }
        end

        def reap_worker(worker)
          worker.state = :exited
          begin
            worker.channel.close
          rescue
            # :nocov:
            nil
            # :nocov:
          end
        end

        def shutdown_workers(&block)
          # Signal "no more work" by closing parent's down-write end. Each
          # worker's receive_from_parent returns nil and they exit their
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

          @workers.each { |w|
            begin
              w.channel.close
            rescue
              # :nocov:
              nil
              # :nocov:
            end
          }
        end

        def drain_remaining_events(&block)
          deadline = Time.now + KILL_TIMEOUT
          until @workers.all?(&:exited?) || Time.now > deadline
            ready, = IO.select(readable_ios, nil, nil, 0.1)
            Array(ready).each do |io|
              worker = worker_for_up_read(io)
              msg = worker.channel.receive_from_worker
              if msg.nil?
                # :nocov: race between up-pipe close and receive
                worker.state = :exited
                # :nocov:
              else
                update_worker_state(worker, msg)
                block&.call(msg)
              end
            end
          end
          force_terminate_workers unless @workers.all?(&:exited?)
        end

        def force_terminate_workers
          send_term_to_live_workers
          wait_for_workers_to_exit
          send_kill_to_stuck_workers
          wait_for_process_teardown
          @workers.each { |w| w.state = :exited }
        end

        def send_term_to_live_workers
          @workers.reject(&:exited?).each do |w|
            begin
              Process.kill(:TERM, w.pid)
            rescue Errno::ESRCH
              # already gone
            end
          end
        end

        def wait_for_workers_to_exit
          deadline = Time.now + KILL_TIMEOUT
          sleep 0.05 until @workers.all? { |w| w.exited? || !process_alive?(w.pid) } || Time.now > deadline
        end

        # KILL fallback runs only when TERM + KILL_TIMEOUT didn't get
        # the worker to exit -- now rare since worker spawn resets
        # SIGTERM to DEFAULT, but kept as a safety net for workers
        # stuck in uninterruptible kernel calls.
        # :nocov:
        def send_kill_to_stuck_workers
          @workers.each do |w|
            next if w.exited? || !process_alive?(w.pid)
            begin
              Process.kill(:KILL, w.pid)
            rescue Errno::ESRCH
              nil
            end
          end
        end
        # :nocov:

        # After SIGKILL the kernel still has to tear the process down
        # and Process.detach's waiter thread has to call waitpid before
        # Process.kill(0, pid) stops returning 0 on the zombie. On a
        # loaded runner this can take tens of ms -- returning before
        # then would leave callers (and tests) seeing `alive=true` for
        # pids we've already reported as :exited.
        def wait_for_process_teardown
          deadline = Time.now + KILL_TIMEOUT
          sleep 0.05 until @workers.all? { |w| !process_alive?(w.pid) } || Time.now > deadline
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
