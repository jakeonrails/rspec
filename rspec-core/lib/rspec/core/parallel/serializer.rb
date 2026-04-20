module RSpec
  module Core
    module Parallel
      # Data transfer objects shipped from a worker to the master in place of
      # the live `Example`, `ExampleGroup`, `ExecutionResult`, and `Exception`
      # objects. They hold only the surface that core's built-in formatters
      # read from those objects — reconstructed on the master so the existing
      # formatter pipeline runs unchanged.
      #
      # Any symmetric `Example`-alike behavior should live here rather than
      # attempting to Marshal real `RSpec::Core::Example` instances, which
      # transitively reference `RSpec.world` and `RSpec.configuration`.
      #
      # @private
      module Serializer
        # Keys from `Example#metadata` that core's own formatters read.
        # Additional keys are preserved via best-effort Marshal — see
        # `safe_metadata`.
        FORMATTER_METADATA_KEYS = [
          :file_path, :line_number, :extra_failure_lines,
          :shared_group_inclusion_backtrace, :described_class
        ].freeze

        SerializedExecutionResult = Struct.new(
          :status, :run_time, :pending_message, :pending_fixed,
          :started_at, :finished_at, :exception
        )

        SerializedGroup = Struct.new(:description, :parent_groups_size, :metadata)

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

        class << self
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
              serialize_exception(result.exception)
            )
          end

          def serialize_group(group)
            return nil unless group
            SerializedGroup.new(
              group.description,
              group.parent_groups.size,
              safe_metadata(group.metadata)
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
