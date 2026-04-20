module RSpec
  module Core
    module Parallel
      # Data transfer objects shipped from a worker to the master in place of
      # the live `Example`, `ExampleGroup`, `ExecutionResult`, and `Exception`
      # objects. They hold only the surface that core's built-in formatters
      # read from those objects -- reconstructed on the master so the existing
      # formatter pipeline runs unchanged.
      #
      # Any symmetric `Example`-alike behavior should live here rather than
      # attempting to Marshal real `RSpec::Core::Example` instances, which
      # transitively reference `RSpec.world` and `RSpec.configuration`.
      #
      # @private
      module Serializer
        # Keys from `Example#metadata` that core's own formatters read.
        # Additional keys are preserved via best-effort Marshal -- see
        # `safe_metadata`.
        FORMATTER_METADATA_KEYS = [
          :file_path, :line_number, :extra_failure_lines,
          :shared_group_inclusion_backtrace, :described_class
        ].freeze

        SerializedExecutionResult = Struct.new(
          :status, :run_time, :pending_message, :pending_fixed,
          :started_at, :finished_at, :exception, :example_skipped,
          :pending_exception
        ) do
          # ExampleNotification.for calls this to route between
          # SkippedExampleNotification and FailedExampleNotification.
          # Precomputed worker-side since the live flag uses
          # `pending_exception`, which we don't carry over the wire as
          # the live attribute.
          def example_skipped?
            example_skipped
          end

          # ExceptionPresenter::Factory and friends ask predicate-style.
          def pending_fixed?
            !!pending_fixed
          end
        end

        SerializedGroup = Struct.new(
          :description, :parent_groups_size, :metadata, :top_level_description
        ) do
          # `parent_groups` on the real class includes `self`, so a
          # top-level group has size 1. Some formatters (documentation,
          # html) branch on this for indentation.
          def top_level?
            parent_groups_size == 1
          end

          # Stub to satisfy listeners (notably Profiler) that read
          # `group.parent_groups.last` as a hash key or count. We don't
          # ship the full parent chain -- profiler metrics will key on
          # the innermost group instead of the outermost ancestor for
          # nested groups. `top_level_description` remains correct.
          def parent_groups
            [self]
          end

          # Reporter#example_group_started/finished skip the notify when
          # this is empty (filtered-out groups). On the master side the
          # worker has already selected which groups to run, so always
          # return a non-empty sentinel to let notifications through.
          def descendant_filtered_examples
            [:sentinel].freeze
          end
        end

        SerializedException = Struct.new(:class_name, :message, :backtrace, :cause) do
          # Duck-type as `Exception` for `ExceptionPresenter`, which reads
          # `.message`, `.backtrace`, `.class.name`, `.cause`.
          def class
            ClassStub.new(class_name)
          end

          ClassStub = Struct.new(:name)
        end

        SerializedExample = Struct.new(
          :id, :description, :full_description, :location, :location_rerun_argument,
          :metadata, :execution_result, :example_group
        ) do
          # Expose the same `#file_path`, `#pending`, `#skip` delegate surface
          # that `Example#delegate_to_metadata` provides, so formatters that
          # hit those methods don't branch on real-vs-serialized.
          def file_path;            metadata[:file_path];            end
          def pending;              metadata[:pending];              end
          def skip;                 metadata[:skip];                 end
          def exception;            execution_result && execution_result.exception; end
        end

        # Events that require per-type payload projection. Anything not
        # listed here (e.g. `:seed`, `:message`, `:start`, `:deprecation`,
        # `:close`, custom events) is a plain Struct or trivial value and
        # ships as-is -- the live notification objects Marshal fine.
        EXAMPLE_EVENTS = [
          :example_started, :example_finished, :example_passed,
          :example_failed, :example_pending
        ].freeze
        GROUP_EVENTS = [:example_group_started, :example_group_finished].freeze

        class << self
          # Dispatcher used by ReporterListener. Returns a value that can be
          # Marshal'd and later fed back to the master's reconstitute step.
          # Shape: [payload_kind, data]
          def serialize_notification(event, notification)
            if EXAMPLE_EVENTS.include?(event)
              [:example, serialize_example(notification.example)]
            elsif GROUP_EVENTS.include?(event)
              [:group, serialize_group(notification.group)]
            else
              [:raw, notification]
            end
          end

          def serialize_example(example)
            SerializedExample.new(
              example.id,
              example.description,
              example.full_description,
              example.location,
              example.location_rerun_argument,
              safe_metadata(example.metadata),
              serialize_execution_result(example.execution_result),
              serialize_group(example.example_group)
            )
          end

          def serialize_execution_result(result)
            return nil unless result
            SerializedExecutionResult.new(
              result.status,
              result.run_time,
              result.pending_message,
              result.pending_fixed,
              result.started_at,
              result.finished_at,
              serialize_exception(result.exception),
              result.respond_to?(:example_skipped?) && result.example_skipped?,
              serialize_exception(result.respond_to?(:pending_exception) ? result.pending_exception : nil)
            )
          end

          def serialize_group(group)
            return nil unless group
            SerializedGroup.new(
              group.description,
              group.parent_groups.size,
              safe_metadata(group.metadata),
              group.respond_to?(:top_level_description) ? group.top_level_description : group.description
            )
          end

          def serialize_exception(exception)
            return nil unless exception
            SerializedException.new(
              exception.class.name,
              exception.message,
              Array(exception.backtrace),
              serialize_exception(exception.cause)
            )
          end

        private

          # User metadata can contain arbitrary objects (AR models, Procs,
          # anonymous classes) that don't Marshal. Round-trip each value;
          # on failure, replace with the `inspect` output string. Lossy but
          # keeps the rest of the metadata usable.
          def safe_metadata(metadata)
            return {} unless metadata
            metadata.each_with_object({}) do |(key, value), safe|
              safe[key] = marshal_roundtrippable?(value) ? value : value.inspect
            end
          end

          def marshal_roundtrippable?(value)
            Marshal.dump(value)
            true
          rescue TypeError
            false
          end
        end
      end
    end
  end
end
