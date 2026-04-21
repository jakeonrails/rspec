RSpec::Support.require_rspec_core "parallel/serializer"

module RSpec
  module Core
    module Parallel
      # Worker-side reporter listener. Registered against every event in
      # `Reporter::RSPEC_NOTIFICATIONS`; each callback serializes the
      # notification and ships it to the parent over the Channel. Workers
      # never drive the formatter chain themselves -- the parent does that
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
            @channel.send_to_parent([
              :event, event, @worker_number,
              Serializer.serialize_notification(event, notification)
            ])
          end
        end

        # Register this listener against every event the reporter knows
        # about, in a single call. Replaces the configured formatters on
        # the worker -- we want exactly one listener that ships upstream.
        #
        # Workers must NOT also run the user's configured formatters
        # (progress, documentation, etc.): their file descriptors are
        # inherited from the parent, so each worker's formatter would
        # write dots/docs to the same stdout the parent is writing to,
        # duplicating output. We force Reporter's `@setup` flag after
        # registering, which short-circuits `ensure_listeners_ready` and
        # prevents the default formatter from being lazily added on the
        # first notify.
        def self.install(configuration, channel, worker_number)
          configuration.reset_reporter
          reporter = configuration.reporter
          listener = new(channel, worker_number)
          reporter.register_listener(listener, *Reporter::RSPEC_NOTIFICATIONS.to_a)
          reporter.instance_variable_set(:@setup, true)
          listener
        end
      end
    end
  end
end
