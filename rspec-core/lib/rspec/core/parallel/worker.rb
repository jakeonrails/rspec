RSpec::Support.require_rspec_core "parallel/reporter_listener"

module RSpec
  module Core
    module Parallel
      # Child-side runloop. After the parent forks, a Worker runs inside the
      # child, pulls group descriptors off the parent's queue one at a time,
      # runs each group's examples, and ships serialized notification events
      # back via the Channel. Exits when the parent closes its end of the
      # down-pipe (EOF signal).
      #
      # The parent is responsible for having already loaded spec files in the
      # pre-fork phase, so `RSpec.world.ordered_example_groups` is populated
      # at fork time and inherited by every worker via COW.
      #
      # @private
      class Worker
        # Work-queue wire protocol:
        #   [:run_group, group_lookup_key] -- run this example group
        #   nil (EOF)                       -- shut down cleanly
        #
        # Worker responses on up-pipe:
        #   [:event, event_name, worker_number, payload]       (via ReporterListener)
        #   [:group_finished, key, :ok|:error, elapsed_seconds] -- request next unit
        #   [:worker_exit, worker_number]                       -- clean shutdown
        #
        # `elapsed_seconds` is monotonic wall-clock time for the group
        # (including its hooks), used by the parent to update the
        # runtime log for LPT-balancing the next run. Readers that
        # predate this field (test shims) work unchanged -- the parent
        # treats a missing value as "no timing data."

        # Worker runs inside forked children; SimpleCov only instruments
        # the parent process, so every line below is reported uncovered
        # even though worker_pool_spec exercises it end-to-end via real
        # forks. See spec/rspec/core/parallel/worker_pool_spec.rb.
        # :nocov:
        def initialize(runner, channel, worker_number)
          @runner        = runner
          @channel       = channel
          @worker_number = worker_number
          @configuration = runner.configuration
          @world         = runner.world
        end

        def run
          RSpec.parallel_worker_number = @worker_number
          ReporterListener.install(@configuration, @channel, @worker_number)
          suppress_worker_local_fail_fast
          @configuration.fire_parallelize_setup_hooks(@worker_number)
          # Suite hooks (before/after(:suite)) run once on the parent,
          # straddling the entire pool; re-running them per worker would
          # both duplicate work and conflict on shared state.
          loop do
            message = @channel.receive_from_parent
            break if message.nil?
            handle(message)
          end
        ensure
          begin
            @configuration.fire_parallelize_teardown_hooks(@worker_number)
          rescue StandardError
            # Teardown errors must not prevent worker_exit -- otherwise the
            # parent never learns this worker has stopped and waits KILL_TIMEOUT.
          end
          begin
            @channel.send_to_parent([:worker_exit, @worker_number])
            @channel.close
          rescue StandardError
            # The parent may already have closed its ends (it treats a quiet
            # pipe as this worker crashing); nothing useful to do from here,
            # and raising would just splat a backtrace onto shared stderr.
          end
        end

      private

        # Fail-fast is coordinated by the parent, which alone sees the
        # global failure count across all workers. If this worker's own
        # reporter were allowed to trip the limit, it would set
        # `RSpec.world.wants_to_quit` inside this process and every
        # subsequently dispatched group would be skipped by
        # `ExampleGroup.run` (returns nil) -- yet still reported back to
        # the parent as `:error` despite never running. Neuter the local
        # check; the parent stops dispatching new groups once the global
        # threshold is actually met.
        def suppress_worker_local_fail_fast
          reporter = @configuration.reporter
          def reporter.fail_fast_limit_met?
            false
          end
        end

        def handle(message)
          case message.first
          when :run_group
            _, key = message
            group = resolve_group(key)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            status = run_group(group)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            @channel.send_to_parent([:group_finished, key, status, elapsed])
          else
            raise ArgumentError, "Unknown parallel message: #{message.inspect}"
          end
        end

        # Groups are identified by `ExampleGroup#id`, which composes
        # `rerun_file_path` with a per-file declaration-order `scoped_id`.
        # Stable across the fork (children inherit declaration order via
        # COW) and unique per group, even when two top-level describes
        # sit on the same source line (dynamically-generated describes,
        # eval'd specs, etc).
        def resolve_group(key)
          @world.ordered_example_groups.find { |g| g.id == key } \
            or raise "Parallel worker #{@worker_number} could not resolve group #{key.inspect}"
        end

        def run_group(group)
          group.run(@configuration.reporter) ? :ok : :error
        rescue StandardError => e
          @channel.send_to_parent([
            :event, :message, @worker_number,
            [:raw, Notifications::MessageNotification.new(
              "Worker #{@worker_number} crashed running #{group.description}: " \
              "#{e.class}: #{e.message}"
            )]
          ])
          :error
        end
        # :nocov:
      end
    end
  end
end
