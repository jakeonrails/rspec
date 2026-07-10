RSpec::Support.require_rspec_core "parallel/serializer"

module RSpec
  module Core
    module Parallel
      # Parent-side counterpart to ReporterListener. Given a wire event
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
          @examples_by_id = {}
        end

        # Serialized examples keyed by example id, each holding its
        # latest-known state. Because `canonical_example_for` funnels every
        # event for a given id through a single object, entries carry the
        # final execution result (status, run_time, exception) once the
        # example has finished. The parent uses this for example-status
        # persistence, since its own Example objects never execute in a
        # parallel run.
        attr_reader :examples_by_id

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
            data = canonical_example_for(data)
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

        # The worker serializes a fresh DTO snapshot per event, so the
        # started/finished/passed notifications for one example arrive as
        # distinct objects -- but the Reporter assumes example identity: it
        # stores the object it saw at `example_started` and re-reads it at
        # dump time (JSON formatter per-example status, profiler, summary).
        # Funnel every event through the first object seen for the id,
        # copying the newer snapshot's fields into it, so late readers see
        # the final execution result instead of a stale started-state stub.
        def canonical_example_for(example)
          canonical = @examples_by_id[example.id]
          return @examples_by_id[example.id] = example unless canonical
          example.each_pair { |member, value| canonical[member] = value }
          canonical
        end
      end
    end
  end
end
