RSpec::Support.require_rspec_core "parallel/balancer"
RSpec::Support.require_rspec_core "parallel/rehydrator"
RSpec::Support.require_rspec_core "parallel/worker_pool"

module RSpec
  module Core
    # Namespace for rspec-core's fork-based parallel runner implementation.
    # See `Parallel::Runner` for the master-side entry point and
    # `Parallel::Worker` for the forked-child loop.
    # @private
    module Parallel
      # Master-side entry point. Stands in for Runner#run_specs when
      # parallel execution is requested. Composition:
      #
      #     before(:suite) hooks        (master, once)
      #       parallelize_before_fork   (master, once, after suite setup)
      #         fork N workers
      #           parallelize_setup     (worker, once after fork)
      #             examples
      #           parallelize_teardown  (worker, once before exit)
      #         join
      #     after(:suite) hooks         (master, once)
      #
      # Events flow: worker emits via ReporterListener on its fresh
      # reporter -> WorkerPool yields to us -> Rehydrator dispatches to
      # the master reporter -> master formatters fire unchanged.
      #
      # If `configuration.parallel_runtime_log_path` is set, the queue
      # is LPT-sorted against the prior log before dispatch, and the
      # log is updated (merge-preserving filtered-out keys) after the
      # run completes. See Parallel::Balancer.
      #
      # @private
      class Runner
        attr_reader :configuration, :world

        def initialize(configuration, world, worker_count)
          @configuration = configuration
          @world         = world
          @worker_count  = worker_count
        end

        # Mirrors `RSpec::Core::Runner#run_specs` return contract: a
        # Fixnum exit code (0 on all-pass, else failure_exit_code).
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

              @configuration.fire_parallelize_before_fork_hooks

              drive_pool(queue, reporter, new_timings)
            end
          end

          # Merge order: current run's timings win for keys that ran,
          # prior log preserves keys the run didn't touch (filter,
          # Ctrl-C mid-run, etc).
          Balancer.write_log(log_path, prior_timings.merge(new_timings)) if log_path

          all_ok ? 0 : @configuration.failure_exit_code
        end

      private

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

          pool = WorkerPool.new(self, @worker_count)
          pool.run(queue) do |message|
            case message.first
            when :event
              rehydrator.handle(message)
            when :group_finished
              _, key, status, elapsed = message
              statuses[key] = status
              timings_out[key] = elapsed if elapsed
            end
          end

          queue.all? { |key| statuses[key] == :ok }
        end
      end
    end
  end
end
