RSpec::Support.require_rspec_core "parallel/rehydrator"
RSpec::Support.require_rspec_core "parallel/worker_pool"

module RSpec
  module Core
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

          all_ok = @configuration.reporter.report(examples_count) do |reporter|
            @configuration.with_suite_hooks do
              if examples_count == 0 && @configuration.fail_if_no_examples
                return @configuration.failure_exit_code
              end

              @configuration.fire_parallelize_before_fork_hooks

              drive_pool(queue, reporter)
            end
          end

          all_ok ? 0 : @configuration.failure_exit_code
        end

      private

        # Group-granularity queue. Mixed-granularity (per-example work
        # units for groups without `before(:context)` hooks) is a later
        # expansion; default stays group-level for correctness.
        def build_queue(example_groups)
          example_groups.map { |g| g.metadata[:location] }
        end

        def drive_pool(queue, reporter)
          rehydrator = Rehydrator.new(reporter)
          statuses = {}

          pool = WorkerPool.new(self, @worker_count)
          pool.run(queue) do |message|
            case message.first
            when :event
              rehydrator.handle(message)
            when :group_finished
              _, key, status = message
              statuses[key] = status
            end
          end

          queue.all? { |key| statuses[key] == :ok }
        end
      end
    end
  end
end
