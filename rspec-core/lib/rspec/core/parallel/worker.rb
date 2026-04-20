RSpec::Support.require_rspec_core "parallel/reporter_listener"

module RSpec
  module Core
    module Parallel
      # Child-side runloop. After the master forks, a Worker runs inside the
      # child, pulls group descriptors off the master's queue one at a time,
      # runs each group's examples, and ships serialized notification events
      # back via the Channel. Exits when the master closes its end of the
      # down-pipe (EOF signal).
      #
      # The master is responsible for having already loaded spec files in the
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
        #   [:event, event_name, worker_number, payload]   (via ReporterListener)
        #   [:group_finished, group_lookup_key, :ok|:error] -- request next unit
        #   [:worker_exit, worker_number]                   -- clean shutdown

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
          @configuration.fire_parallelize_setup_hooks(@worker_number)
          @configuration.with_suite_hooks do
            loop do
              message = @channel.receive_from_master
              break if message.nil?
              handle(message)
            end
          end
        ensure
          begin
            @configuration.fire_parallelize_teardown_hooks(@worker_number)
          rescue StandardError
            # Teardown errors must not prevent worker_exit -- otherwise the
            # master never learns this worker has stopped and waits KILL_TIMEOUT.
          end
          @channel.send_to_master([:worker_exit, @worker_number])
          @channel.close
        end

      private

        def handle(message)
          case message.first
          when :run_group
            _, key = message
            group = resolve_group(key)
            status = run_group(group)
            @channel.send_to_master([:group_finished, key, status])
          else
            raise ArgumentError, "Unknown parallel message: #{message.inspect}"
          end
        end

        # Groups are identified by their source location (file + line), which
        # is stable across the fork and unique within a suite. Richer keying
        # (seed-ordered index) is a later optimization.
        def resolve_group(key)
          @world.ordered_example_groups.find { |g| g.metadata[:location] == key } \
            or raise "Parallel worker #{@worker_number} could not resolve group #{key.inspect}"
        end

        def run_group(group)
          group.run(@configuration.reporter) ? :ok : :error
        rescue StandardError => e
          @channel.send_to_master([
            :event, :message, @worker_number,
            [:raw, Notifications::MessageNotification.new(
              "Worker #{@worker_number} crashed running #{group.description}: " \
              "#{e.class}: #{e.message}"
            )]
          ])
          :error
        end
      end
    end
  end
end
