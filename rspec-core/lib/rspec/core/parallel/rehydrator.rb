RSpec::Support.require_rspec_core "parallel/serializer"

module RSpec
  module Core
    module Parallel
      # Master-side counterpart to ReporterListener. Given a wire event
      # emitted by WorkerPool -- shape `[:event, event_name, worker_number,
      # [payload_kind, data]]` -- it reconstitutes a live `Notification`
      # and dispatches it to the reporter, so the existing formatter
      # pipeline runs unchanged.
      #
      # Dispatches through the Reporter's event methods (e.g.
      # `example_started(example)`) rather than `notify(event, notification)`,
      # because the event methods maintain the Reporter's internal
      # `@examples` / `@failed_examples` / `@pending_examples` arrays that
      # SummaryNotification reads at the end of the run. Bypassing them
      # means the final "N examples, M failures" line reads zero.
      #
      # @private
      class Rehydrator
        # Events that go through a dedicated Reporter method. Others
        # fall through to `notify`.
        EXAMPLE_ROUTED = [
          :example_started, :example_finished, :example_passed,
          :example_failed, :example_pending
        ].freeze
        GROUP_ROUTED = [:example_group_started, :example_group_finished].freeze

        def initialize(reporter)
          @reporter = reporter
        end

        # Yield each WorkerPool wire message here; drives @reporter for
        # events and ignores control messages (:group_finished,
        # :worker_exit). Returns nil.
        def handle(message)
          return nil unless message.is_a?(Array) && message.first == :event
          _, event_name, _worker_number, wrapped = message
          kind, data = wrapped
          dispatch(event_name, kind, data)
          nil
        end

      private

        def dispatch(event_name, kind, data)
          case kind
          when :example
            if EXAMPLE_ROUTED.include?(event_name)
              @reporter.__send__(event_name, data)
            else
              @reporter.notify(event_name, Notifications::ExampleNotification.send(:new, data))
            end
          when :group
            if GROUP_ROUTED.include?(event_name)
              @reporter.__send__(event_name, data)
            else
              @reporter.notify(event_name, Notifications::GroupNotification.new(data))
            end
          when :raw
            @reporter.notify(event_name, data)
          else
            raise ArgumentError, "Unknown parallel payload kind: #{kind.inspect}"
          end
        end
      end
    end
  end
end
