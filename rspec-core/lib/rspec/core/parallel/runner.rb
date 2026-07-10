RSpec::Support.require_rspec_core "parallel/balancer"
RSpec::Support.require_rspec_core "parallel/rehydrator"
RSpec::Support.require_rspec_core "parallel/worker_pool"

module RSpec
  module Core
    # Namespace for rspec-core's fork-based parallel runner implementation.
    # See `Parallel::Runner` for the parent-side entry point and
    # `Parallel::Worker` for the forked-child loop.
    # @private
    module Parallel
      # Synthesised for reporting when a forked worker dies without
      # completing its dispatched group (segfault, OOM kill, SystemExit).
      # Never raised -- passed to `Reporter#notify_non_example_exception`
      # so the crash surfaces as a run error with a nonzero exit code.
      # @private
      class WorkerCrashedError < StandardError; end

      # Parent-side entry point. Stands in for Runner#run_specs when
      # parallel execution is requested. Composition:
      #
      #     before(:suite) hooks        (parent, once)
      #       parallelize_before_fork   (parent, once, after suite setup)
      #         fork N workers
      #           parallelize_setup     (worker, once after fork)
      #             examples
      #           parallelize_teardown  (worker, once before exit)
      #         join
      #     after(:suite) hooks         (parent, once)
      #
      # Events flow: worker emits via ReporterListener on its fresh
      # reporter -> WorkerPool yields to us -> per-worker buffer ->
      # (flushed atomically when the worker's group completes) ->
      # Rehydrator dispatches to the parent reporter -> parent formatters
      # fire unchanged.
      #
      # If `configuration.parallel_runtime_log_path` is set, the queue
      # is LPT-sorted against the prior log before dispatch, and the
      # log is updated (merge-preserving filtered-out keys) after the
      # run completes. See Parallel::Balancer.
      #
      # @private
      class Runner
        attr_reader :configuration, :world

        # Serialized examples that actually executed, keyed by example id,
        # carrying final execution results. `Core::Runner` overlays these
        # on `world.all_examples` when persisting example statuses, since
        # the parent's own Example objects never execute in a parallel run
        # (persisting those would record every example as `unknown` and
        # silently break `--only-failures`).
        attr_reader :executed_example_results

        def initialize(configuration, world, worker_count)
          @configuration = configuration
          @world         = world
          @worker_count  = worker_count
          @executed_example_results = {}
        end

        # Mirrors `RSpec::Core::Runner#run_specs` return contract,
        # including `error_exit_code` semantics for non-example failures
        # (failed `before(:suite)` hook, crashed worker).
        def run_specs(example_groups)
          examples_count = @world.example_count(example_groups)
          queue = build_queue(example_groups)

          log_path = @configuration.parallel_runtime_log_path
          prior_timings = Balancer.read_log(log_path)
          queue = Balancer.sort_queue(queue, prior_timings)

          new_timings = {}

          all_ok = @configuration.reporter.report(examples_count) do |reporter|
            @configuration.with_suite_hooks do
              if examples_count == 0 && @configuration.fail_if_no_examples
                return @configuration.failure_exit_code
              end

              # A failed `before(:suite)` hook (or anything else that flips
              # `wants_to_quit` during suite setup) bails out before forking,
              # like the serial runner: workers would inherit the flag via
              # fork and report `:error` for every group without running it.
              if @world.wants_to_quit
                false
              else
                @configuration.fire_parallelize_before_fork_hooks
                drive_pool(queue, reporter, new_timings)
              end
            end
          end

          # Merge order: current run's timings win for keys that ran,
          # prior log preserves keys the run didn't touch (filter,
          # Ctrl-C mid-run, etc).
          Balancer.write_log(log_path, prior_timings.merge(new_timings)) if log_path

          exit_code(all_ok)
        end

      private

        # Mirrors `Core::Runner#exit_code`: `error_exit_code` (when
        # configured) takes precedence for non-example failures.
        def exit_code(examples_passed)
          return @configuration.error_exit_code || @configuration.failure_exit_code if @world.non_example_failure
          return @configuration.failure_exit_code unless examples_passed

          0
        end

        # Group-granularity queue. Mixed-granularity (per-example work
        # units for groups without `before(:context)` hooks) is a later
        # expansion; default stays group-level for correctness.
        #
        # Keys are `ExampleGroup#id` ("<rerun_file_path>[<scoped_id>]"),
        # not `metadata[:location]`. `:location` is only file:line and
        # collides for groups declared on the same line -- e.g.
        # `[Foo, Bar].each { |k| RSpec.describe(k) { ... } }` generates
        # two groups whose locations are identical. `scoped_id` is a
        # per-file declaration-order index, so `id` is unique per group
        # and stable across fork (children inherit the same declaration
        # order via COW).
        def build_queue(example_groups)
          example_groups.map(&:id)
        end

        def drive_pool(queue, reporter, timings_out)
          rehydrator = Rehydrator.new(reporter)
          statuses = {}
          # Rehydrated events are buffered per worker and flushed to the
          # reporter only when that worker's in-flight group completes.
          # This keeps each group's notifications contiguous (stateful
          # formatters like documentation render without cross-worker
          # interleaving) and lets a crashed attempt's events be voided
          # wholesale -- the requeued attempt re-emits everything, so no
          # notification is ever delivered twice.
          buffers = Hash.new { |hash, worker_number| hash[worker_number] = [] }

          pool = WorkerPool.new(self, @worker_count)
          pool.run(queue) do |message|
            case message.first
            when :event
              buffers[message[2]] << message
            when :group_finished
              _, key, status, elapsed, worker_number = message
              flush_events(buffers, worker_number, rehydrator)
              statuses[key] = status
              timings_out[key] = elapsed if elapsed
              stop_dispatching_if_fail_fast(pool, reporter)
            when :worker_crashed
              _, worker_number, key, disposition = message
              buffers.delete(worker_number)
              report_worker_crash(reporter, worker_number, key, disposition)
            when :worker_exit
              # Clean exit: flush stray non-group events (e.g. deprecations
              # emitted from parallelize_setup/teardown hooks).
              flush_events(buffers, message[1], rehydrator)
            end
          end

          @executed_example_results = rehydrator.examples_by_id
          queue.all? { |key| statuses[key] == :ok }
        end

        def flush_events(buffers, worker_number, rehydrator)
          return unless buffers.key?(worker_number)
          buffers.delete(worker_number).each { |event| rehydrator.handle(event) }
        end

        def stop_dispatching_if_fail_fast(pool, reporter)
          return unless reporter.fail_fast_limit_met?
          @world.wants_to_quit = true
          pool.stop_dispatching!
        end

        # A worker died without completing its group. A requeued attempt is
        # announced (crashes must never pass silently) but doesn't fail the
        # run -- the retry will produce the group's real results. A final
        # (:gave_up) crash is reported like any other non-example error:
        # visible in the output, counted in the summary, nonzero exit code.
        def report_worker_crash(reporter, worker_number, key, disposition)
          worker_desc = worker_number ? "Parallel worker #{worker_number}" : "A parallel worker"

          if disposition == :requeued
            reporter.message(
              "#{worker_desc} exited unexpectedly while running #{key.inspect}. " \
              "The group has been requeued to run on another worker."
            )
          else
            error = WorkerCrashedError.new(
              "#{worker_desc} exited unexpectedly (possible crash or `exit` call) while " \
              "running #{key.inspect}, and the retry limit for the group has been reached. " \
              "Results for this group are incomplete."
            )
            error.set_backtrace([])
            reporter.notify_non_example_exception(
              error, "An error occurred while running #{key.inspect} in a parallel worker."
            )
          end
        end
      end
    end
  end
end
