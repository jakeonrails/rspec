RSpec::Support.require_rspec_core "parallel/serializer"

module RSpec
  module Core
    module Parallel
      # Worker-side reporter listener. Registered against every event in
      # `Reporter::RSPEC_NOTIFICATIONS`; each callback serializes the
      # notification and ships it to the master over the Channel. Workers
      # never drive the formatter chain themselves -- the master does that
      # once, after rehydrating events from every worker in global order.
      #
      # @private
      class ReporterListener
        def initialize(channel, worker_number)
          @channel = channel
          @worker_number = worker_number
        end

        # Event wire format: [:event, event_name, worker_number, payload]
        # where `payload` is whatever `Serializer.serialize_notification`
        # produced for that event.
        Reporter::RSPEC_NOTIFICATIONS.each do |event|
          define_method(event) do |notification|
            @channel.send_to_master([
              :event, event, @worker_number,
              Serializer.serialize_notification(event, notification)
            ])
          end
        end

        # Register this listener against every event the reporter knows
        # about, in a single call. Replaces the configured formatters on
        # the worker -- we want exactly one listener that ships upstream.
        def self.install(configuration, channel, worker_number)
          configuration.reset_reporter
          reporter = configuration.reporter
          listener = new(channel, worker_number)
          reporter.register_listener(listener, *Reporter::RSPEC_NOTIFICATIONS.to_a)
          listener
        end
      end
    end
  end
end
