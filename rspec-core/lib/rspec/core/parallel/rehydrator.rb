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
      # Kept pure (`rehydrate` returns `[event_name, notification]` or
      # `nil` for non-event messages) so it's independently testable
      # without a live reporter. `drive` is the thin glue that a Runner
      # can call from inside `WorkerPool#run`'s block.
      #
      # @private
      class Rehydrator
        def initialize(reporter)
          @reporter = reporter
        end

        # Yield each WorkerPool wire message here; drives @reporter for
        # events and ignores control messages (:group_finished,
        # :worker_exit). Returns nil.
        def handle(message)
          event_name, notification = rehydrate(message)
          @reporter.notify(event_name, notification) if event_name
          nil
        end

        # Pure: decode a wire message into `[event_name, notification]`
        # for dispatching, or nil for control messages.
        def rehydrate(message)
          return nil unless message.is_a?(Array) && message.first == :event
          _, event_name, _worker_number, wrapped = message
          kind, data = wrapped
          [event_name, build_notification(event_name, kind, data)]
        end

      private

        def build_notification(event_name, kind, data)
          case kind
          when :example then build_example_notification(event_name, data)
          when :group   then Notifications::GroupNotification.new(data)
          when :raw     then data
          else
            raise ArgumentError, "Unknown parallel payload kind: #{kind.inspect}"
          end
        end

        def build_example_notification(event_name, serialized_example)
          case event_name
          when :example_failed
            Notifications::FailedExampleNotification.new(serialized_example)
          when :example_pending
            if serialized_example.execution_result &&
               serialized_example.execution_result.example_skipped?
              Notifications::SkippedExampleNotification.new(serialized_example)
            else
              Notifications::FailedExampleNotification.new(serialized_example)
            end
          else
            # :example_started, :example_finished, :example_passed
            Notifications::ExampleNotification.send(:new, serialized_example)
          end
        end
      end
    end
  end
end
