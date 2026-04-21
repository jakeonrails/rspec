require 'rspec/core/parallel/serializer'

module RSpec::Core::Parallel
  RSpec.describe Serializer do
    describe ".serialize_example" do
      it "projects an Example down to the surface formatters read" do
        group = RSpec.describe("outer") do
          describe "inner" do
            it("does a thing") { }
          end
        end.children.first
        example = group.examples.first

        serialized = Serializer.serialize_example(example)

        expect(serialized.id).to eq(example.id)
        expect(serialized.full_description).to eq("outer inner does a thing")
        expect(serialized.example_group.description).to eq("inner")
        expect(serialized.example_group.parent_groups_size).to eq(2)
      end
    end

    describe ".serialize_exception" do
      it "captures class name, message, backtrace, and recursive cause" do
        inner = RuntimeError.new("inner boom").tap { |e| e.set_backtrace(["a:1", "b:2"]) }
        outer = begin
          raise StandardError, "outer boom"
        rescue StandardError => e
          # Wire up a cause chain without actually using `raise x, cause: y`
          # so this test works on older Rubies too.
          e.define_singleton_method(:cause) { inner }
          e
        end

        serialized = Serializer.serialize_exception(outer)

        expect(serialized.class_name).to eq("StandardError")
        expect(serialized.message).to eq("outer boom")
        expect(serialized.cause.class_name).to eq("RuntimeError")
        expect(serialized.cause.message).to eq("inner boom")
        expect(serialized.cause.backtrace).to eq(["a:1", "b:2"])
      end

      it "returns nil for a nil exception" do
        expect(Serializer.serialize_exception(nil)).to be_nil
      end
    end

    describe "SerializedException duck-typing" do
      it "exposes #class.name so ExceptionPresenter sees the original type" do
        inner = RuntimeError.new("x")
        serialized = Serializer.serialize_exception(inner)
        expect(serialized.class.name).to eq("RuntimeError")
      end

      it "renders the class name cleanly under string interpolation" do
        # ExceptionPresenter does `"#{exception.class}"` in some code paths;
        # Struct's default to_s would surface `#<struct ClassStub name="X">`.
        serialized = Serializer.serialize_exception(RuntimeError.new("x"))
        expect(serialized.class.to_s).to eq("RuntimeError")
        expect(serialized.class.inspect).to eq("RuntimeError")
      end
    end

    describe "rehydration of an exception class the master never sees" do
      # Typical real-world shape: Rails app raises an app-defined exception
      # (e.g. `MyApp::PaymentError`) inside a worker, ships the serialized
      # form to the master, and the master's process does not have the Rails
      # app loaded. The master must still render the failure message without
      # trying to reconstruct the original class.
      it "round-trips through Marshal without requiring the class on the master" do
        worker_side = Class.new(StandardError) do
          def self.name = "MyApp::ThisClassDoesNotExistOnTheMaster"
        end
        raised = worker_side.new("payment gateway timeout").tap do |e|
          e.set_backtrace(["app/models/payment.rb:42:in `charge'"])
        end

        wire = Marshal.dump(Serializer.serialize_exception(raised))
        # Simulate master: drop all reference to the worker-side class before
        # rehydrating. Marshal.load must succeed anyway.
        worker_side = nil # rubocop:disable Lint/UselessAssignment
        restored = Marshal.load(wire) # rubocop:disable Security/MarshalLoad

        expect(restored.class_name).to eq("MyApp::ThisClassDoesNotExistOnTheMaster")
        expect(restored.message).to eq("payment gateway timeout")
        expect(restored.backtrace).to eq(["app/models/payment.rb:42:in `charge'"])
        expect(restored.class.name).to eq("MyApp::ThisClassDoesNotExistOnTheMaster")
      end

      it "preserves a cause chain whose classes are also absent from the master" do
        inner_klass = Class.new(StandardError) do
          def self.name = "MyApp::InnerError"
        end
        outer_klass = Class.new(StandardError) do
          def self.name = "MyApp::OuterError"
        end
        inner = inner_klass.new("inner")
        outer = outer_klass.new("outer")
        outer.define_singleton_method(:cause) { inner }

        wire = Marshal.dump(Serializer.serialize_exception(outer))
        restored = Marshal.load(wire) # rubocop:disable Security/MarshalLoad

        expect(restored.class_name).to eq("MyApp::OuterError")
        expect(restored.cause.class_name).to eq("MyApp::InnerError")
        expect(restored.cause.message).to eq("inner")
      end
    end

    describe ".safe_metadata (via serialize_example)" do
      it "preserves Marshalable values and replaces non-Marshalable ones with their inspect" do
        group = RSpec.describe("g") do
          it("e", :custom_proc => proc {}, :scalar => 42) { }
        end
        example = group.examples.first

        serialized = Serializer.serialize_example(example)

        expect(serialized.metadata[:scalar]).to eq(42)
        expect(serialized.metadata[:custom_proc]).to be_a(String)
        expect(serialized.metadata[:custom_proc]).to include("Proc")
      end
    end

    describe "Marshal round-trip of a fully serialized example" do
      it "survives Marshal.dump / Marshal.load end-to-end" do
        group = RSpec.describe("g") { it("e") { } }
        example = group.examples.first

        serialized = Serializer.serialize_example(example)
        restored = Marshal.load(Marshal.dump(serialized))

        expect(restored.id).to eq(example.id)
        expect(restored.full_description).to eq("g e")
      end
    end

    describe ".serialize_notification dispatch" do
      let(:example) do
        RSpec.describe("g") { it("e") { } }.examples.first
      end

      it "projects example_* events through serialize_example" do
        notification = RSpec::Core::Notifications::ExampleNotification.send(:new, example)
        kind, payload = Serializer.serialize_notification(:example_finished, notification)

        expect(kind).to eq(:example)
        expect(payload).to be_a(Serializer::SerializedExample)
        expect(payload.id).to eq(example.id)
      end

      it "projects example_group_* events through serialize_group" do
        group = RSpec.describe("g") { it("e") { } }
        notification = RSpec::Core::Notifications::GroupNotification.new(group)
        kind, payload = Serializer.serialize_notification(:example_group_started, notification)

        expect(kind).to eq(:group)
        expect(payload).to be_a(Serializer::SerializedGroup)
        expect(payload.description).to eq("g")
      end

      it "passes through plain-Struct notifications as :raw" do
        seed = RSpec::Core::Notifications::SeedNotification.new(1234, true)
        kind, payload = Serializer.serialize_notification(:seed, seed)

        expect(kind).to eq(:raw)
        expect(payload).to equal(seed)
      end
    end
  end
end
