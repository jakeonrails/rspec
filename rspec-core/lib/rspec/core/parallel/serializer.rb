module RSpec
  module Core
    module Parallel
      # Data transfer objects shipped from a worker to the parent in place of
      # the live `Example`, `ExampleGroup`, `ExecutionResult`, and `Exception`
      # objects. They hold only the surface that core's built-in formatters
      # read from those objects -- reconstructed on the parent so the existing
      # formatter pipeline runs unchanged.
      #
      # Any symmetric `Example`-alike behavior should live here rather than
      # attempting to Marshal real `RSpec::Core::Example` instances, which
      # transitively reference `RSpec.world` and `RSpec.configuration`.
      #
      # @private
      module Serializer
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
          # this is empty (filtered-out groups). On the parent side the
          # worker has already selected which groups to run, so always
          # return a non-empty sentinel to let notifications through.
          def descendant_filtered_examples
            [:sentinel].freeze
          end
        end

        # `Struct`'s default to_s would render `#<struct ClassStub name="X">`
        # anywhere the presenter interpolates `"#{exception.class}"` (see
        # ExceptionPresenter#exception_class_name). Mask the Struct form.
        # Defined outside SerializedException so the constant is scoped to
        # the module (rubocop: Lint/ConstantDefinitionInBlock).
        ClassStub = Struct.new(:name) do
          # @return [String] the class name.
          def to_s
            name.to_s
          end
          alias_method :inspect, :to_s
        end

        SerializedException = Struct.new(:class_name, :message, :backtrace, :cause) do
          # Duck-type as `Exception` for `ExceptionPresenter`, which reads
          # `.message`, `.backtrace`, `.class.name`, `.cause`.
          def class
            ClassStub.new(class_name)
          end
        end

        SerializedExample = Struct.new(
          :id, :description, :full_description, :location, :location_rerun_argument,
          :metadata, :execution_result, :example_group
        ) do
          # Expose the same `#file_path`, `#pending`, `#skip` delegate surface
          # that `Example#delegate_to_metadata` provides, so formatters that
          # hit those methods don't branch on real-vs-serialized.
          # @return [String, nil] the spec file path.
          def file_path = metadata.[](:file_path)

          # @return [Object, nil] pending metadata value (String message, true, or nil).
          def pending = metadata.[](:pending)

          # @return [Object, nil] skip metadata value (String message, true, or nil).
          def skip = metadata.[](:skip)

          # @return [SerializedException, nil] the serialized failure exception, if any.
          def exception = execution_result&.exception
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
          # Marshal'd and later fed back to the parent's reconstitute step.
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

          # Groups are immutable for the lifetime of a worker and every
          # example event re-ships its group (3+ events per example), so
          # the serialized form is cached per group. Identity-keyed: the
          # cache holds the group itself as key, so a recycled object id
          # can never alias two groups.
          def serialize_group(group)
            return nil unless group
            cache = (@serialized_group_cache ||= {}.compare_by_identity)
            cache[group] ||= SerializedGroup.new(
              group.description,
              group.parent_groups.size,
              sanitized_group_metadata(group.metadata),
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

          # @private -- test hook. Caches live for the worker process's
          # lifetime in production; specs that assert cache behavior (or
          # need pristine state) reset them here.
          def reset_caches!
            @serialized_group_cache = nil
            @sanitized_group_metadata = nil
          end

        private

          # User metadata can contain arbitrary objects (AR models, Procs,
          # anonymous classes) that don't Marshal. Walk hashes and arrays
          # recursively and replace only the unmarshalable LEAVES with
          # their `inspect` string, so structured metadata -- notably the
          # nested `:example_group` / `:parent_example_group` hashes that
          # custom formatters read (`metadata[:example_group][:description]`)
          # -- survives with its sibling keys intact. `:block` keys (the
          # example/group procs) are stripped outright: they are never
          # useful on the parent and would otherwise degrade to noise.
          def safe_metadata(metadata)
            return {} unless metadata
            sanitize_hash(metadata, {}.compare_by_identity)
          end

          # Group metadata hashes belong to the world's example groups,
          # live for the whole worker, and are re-serialized for every
          # event of every example beneath them. Cache the sanitized copy
          # per hash (identity-keyed; holding the hash as key also pins it
          # against id recycling). Trade-off: a mid-run mutation of group
          # metadata isn't re-shipped -- per-example metadata is NOT
          # cached, so mutable example keys like `:extra_failure_lines`
          # still ship fresh with every event.
          def sanitized_group_metadata(metadata)
            return {} unless metadata
            cache = (@sanitized_group_metadata ||= {}.compare_by_identity)
            cache[metadata] ||= sanitize_hash(metadata, {}.compare_by_identity)
          end

          def sanitize_hash(hash, seen)
            return safe_inspect(hash) if seen.key?(hash)
            seen[hash] = true
            result = hash.each_with_object({}) do |(key, value), safe|
              next if key == :block
              safe[sanitize_leaf(key)] =
                if GROUP_METADATA_KEYS.include?(key) && value.is_a?(Hash)
                  sanitized_group_metadata(value)
                else
                  sanitize_value(value, seen)
                end
            end
            seen.delete(hash)
            result
          end

          GROUP_METADATA_KEYS = [:example_group, :parent_example_group].freeze

          def sanitize_value(value, seen)
            case value
            when Hash  then sanitize_hash(value, seen)
            when Array then sanitize_array(value, seen)
            else            sanitize_leaf(value)
            end
          end

          def sanitize_array(array, seen)
            return safe_inspect(array) if seen.key?(array)
            seen[array] = true
            result = array.map { |value| sanitize_value(value, seen) }
            seen.delete(array)
            result
          end

          def sanitize_leaf(value)
            marshal_roundtrippable?(value) ? value : safe_inspect(value)
          end

          def marshal_roundtrippable?(value)
            Marshal.dump(value)
            true
          rescue StandardError
            # TypeError covers the classically unmarshalable (Proc, IO,
            # anonymous Class); everything else covers user objects whose
            # `_dump` / `marshal_dump` raises an arbitrary error -- those
            # must degrade to a stub too, not crash the group's events.
            false
          end

          def safe_inspect(value)
            value.inspect
          rescue StandardError
            "#<uninspectable #{value.class}>"
          end
        end
      end
    end
  end
end
