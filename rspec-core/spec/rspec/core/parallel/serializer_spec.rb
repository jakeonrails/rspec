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

    describe "rehydration of an exception class the parent never sees" do
      # Typical real-world shape: Rails app raises an app-defined exception
      # (e.g. `MyApp::PaymentError`) inside a worker, ships the serialized
      # form to the parent, and the parent's process does not have the Rails
      # app loaded. The parent must still render the failure message without
      # trying to reconstruct the original class.
      it "round-trips through Marshal without requiring the class on the parent" do
        worker_side = Class.new(StandardError) do
          def self.name = "MyApp::ThisClassDoesNotExistOnTheParent"
        end
        raised = worker_side.new("payment gateway timeout").tap do |e|
          e.set_backtrace(["app/models/payment.rb:42:in `charge'"])
        end

        wire = Marshal.dump(Serializer.serialize_exception(raised))
        # Simulate parent: drop all reference to the worker-side class before
        # rehydrating. Marshal.load must succeed anyway.
        worker_side = nil # rubocop:disable Lint/UselessAssignment
        restored = Marshal.load(wire) # rubocop:disable Security/MarshalLoad

        expect(restored.class_name).to eq("MyApp::ThisClassDoesNotExistOnTheParent")
        expect(restored.message).to eq("payment gateway timeout")
        expect(restored.backtrace).to eq(["app/models/payment.rb:42:in `charge'"])
        expect(restored.class.name).to eq("MyApp::ThisClassDoesNotExistOnTheParent")
      end

      it "preserves a cause chain whose classes are also absent from the parent" do
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

      it "replaces only the unmarshalable leaves inside nested hashes and arrays, keeping siblings" do
        group = RSpec.describe("g") do
          it("e", :nested => { :callback => proc {}, :name => "payments", :ids => [1, proc {}] }) { }
        end
        example = group.examples.first

        serialized = Serializer.serialize_example(example)

        nested = serialized.metadata[:nested]
        expect(nested).to be_a(Hash)
        expect(nested[:name]).to eq("payments")
        expect(nested[:callback]).to be_a(String)
        expect(nested[:ids][0]).to eq(1)
        expect(nested[:ids][1]).to be_a(String)
      end

      it "keeps metadata[:example_group] a real hash whose :description survives" do
        # Regression: the whole nested :example_group hash used to collapse
        # into one giant inspect string (its :block key made it fail the
        # Marshal round-trip wholesale), breaking custom formatters that
        # read `example.metadata[:example_group][:description]`.
        group = RSpec.describe("billing") do
          it("charges the card") { }
        end
        example = group.examples.first

        serialized = Serializer.serialize_example(example)

        expect(serialized.metadata[:example_group]).to be_a(Hash)
        expect(serialized.metadata[:example_group][:description]).to eq("billing")
      end

      it "survives a full Marshal round-trip with the nested group metadata intact" do
        group = RSpec.describe("outer") do
          describe "inner" do
            it("e") { }
          end
        end.children.first
        example = group.examples.first

        restored = Marshal.load(Marshal.dump(Serializer.serialize_example(example)))

        expect(restored.metadata[:example_group][:description]).to eq("inner")
        expect(restored.metadata[:example_group][:parent_example_group][:description]).to eq("outer")
      end

      it "strips :block keys outright instead of shipping inspect noise" do
        group = RSpec.describe("g") { it("e") { } }
        example = group.examples.first

        serialized = Serializer.serialize_example(example)

        expect(serialized.metadata).not_to have_key(:block)
        expect(serialized.metadata[:example_group]).not_to have_key(:block)
      end

      it "degrades a value whose custom _dump raises a non-TypeError instead of crashing" do
        explosive_class = Class.new do
          def self.name
            "ExplosiveDump"
          end

          def _dump(_level)
            raise "refusing to be dumped"
          end

          def inspect
            "#<ExplosiveDump>"
          end
        end

        group = RSpec.describe("g") do
          it("e", :landmine => explosive_class.new) { }
        end
        example = group.examples.first

        serialized = nil
        expect { serialized = Serializer.serialize_example(example) }.not_to raise_error
        expect(serialized.metadata[:landmine]).to eq("#<ExplosiveDump>")
      end

      it "stubs out a value that is neither marshalable nor inspectable" do
        broken_class = Class.new do
          def self.name
            "BrokenInspect"
          end

          def _dump(_level)
            raise TypeError, "no"
          end

          def inspect
            raise "inspect is broken too"
          end
        end

        group = RSpec.describe("g") do
          it("e", :broken => broken_class.new) { }
        end
        example = group.examples.first

        serialized = Serializer.serialize_example(example)
        expect(serialized.metadata[:broken]).to be_a(String)
        expect(serialized.metadata[:broken]).to include("uninspectable")
      end

      it "does not hang on cyclic user metadata" do
        cyclic = { :name => "loop" }
        cyclic[:self] = cyclic

        group = RSpec.describe("g") do
          it("e", :cyclic => cyclic) { }
        end
        example = group.examples.first

        serialized = Serializer.serialize_example(example)
        expect(serialized.metadata[:cyclic][:name]).to eq("loop")
        expect(serialized.metadata[:cyclic][:self]).to be_a(String)
      end
    end

    describe "payload diet (per-worker caches)" do
      before { Serializer.reset_caches! }
      after  { Serializer.reset_caches! }

      it "serializes a group once and reuses it across the example's event cycle" do
        group = RSpec.describe("g") { it("e") { } }
        example = group.examples.first

        first  = Serializer.serialize_example(example)
        second = Serializer.serialize_example(example)

        # Same SerializedGroup object -> the giant sanitized group metadata
        # is built once, not once per started/passed/finished event.
        expect(first.example_group).to equal(second.example_group)
        expect(first.metadata[:example_group]).to equal(second.metadata[:example_group])
      end

      it "still serializes the execution result fresh on every event" do
        group = RSpec.describe("g") { it("e") { } }
        example = group.examples.first

        first = Serializer.serialize_example(example)
        example.execution_result.status = :passed
        second = Serializer.serialize_example(example)

        expect(second.execution_result.status).to eq(:passed)
        expect(first.execution_result).not_to equal(second.execution_result)
      end

      it "still serializes per-example metadata fresh on every event (e.g. :extra_failure_lines)" do
        group = RSpec.describe("g") { it("e") { } }
        example = group.examples.first

        Serializer.serialize_example(example)
        example.metadata[:extra_failure_lines] = ["late-added diagnostic"]
        second = Serializer.serialize_example(example)

        expect(second.metadata[:extra_failure_lines]).to eq(["late-added diagnostic"])
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
