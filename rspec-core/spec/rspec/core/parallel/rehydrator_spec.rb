require 'rspec/core/parallel/rehydrator'
require 'rspec/core/parallel/serializer'

module RSpec::Core::Parallel
  RSpec.describe Rehydrator do
    let(:reporter) do
      instance_double(
        "RSpec::Core::Reporter",
        :notify => nil,
        :example_started => nil, :example_finished => nil,
        :example_passed => nil, :example_failed => nil,
        :example_pending => nil,
        :example_group_started => nil, :example_group_finished => nil
      )
    end
    subject(:rehydrator) { described_class.new(reporter) }

    def serialized_example(status: :passed, skipped: false, exception: nil)
      exec = Serializer::SerializedExecutionResult.new(
        status, 0.01, nil, nil, Time.now, Time.now, exception, skipped, nil
      )
      Serializer::SerializedExample.new(
        "./a_spec.rb[1:1]", "does a thing", "A does a thing",
        "./a_spec.rb:1", "./a_spec.rb:1",
        { :file_path => "./a_spec.rb" }, exec,
        Serializer::SerializedGroup.new("A", 1, {}, "A")
      )
    end

    it "returns nil for non-event wire messages (control plane)" do
      expect(rehydrator.handle([:group_finished, "./a_spec.rb:1", :ok])).to be_nil
      expect(rehydrator.handle([:worker_exit, 0])).to be_nil
      expect(reporter).not_to have_received(:notify)
      expect(reporter).not_to have_received(:example_started)
    end

    describe "example events (routed through Reporter named methods)" do
      it "dispatches :example_started to reporter.example_started with the example" do
        ex = serialized_example
        rehydrator.handle([:event, :example_started, 0, [:example, ex]])
        expect(reporter).to have_received(:example_started).with(ex)
      end

      it "dispatches :example_passed to reporter.example_passed" do
        ex = serialized_example
        rehydrator.handle([:event, :example_passed, 0, [:example, ex]])
        expect(reporter).to have_received(:example_passed).with(ex)
      end

      it "dispatches :example_failed to reporter.example_failed" do
        ex = serialized_example(status: :failed)
        rehydrator.handle([:event, :example_failed, 0, [:example, ex]])
        expect(reporter).to have_received(:example_failed).with(ex)
      end

      it "dispatches :example_pending to reporter.example_pending" do
        ex = serialized_example(status: :pending, skipped: true)
        rehydrator.handle([:event, :example_pending, 0, [:example, ex]])
        expect(reporter).to have_received(:example_pending).with(ex)
      end

      it "dispatches :example_finished to reporter.example_finished" do
        ex = serialized_example
        rehydrator.handle([:event, :example_finished, 0, [:example, ex]])
        expect(reporter).to have_received(:example_finished).with(ex)
      end
    end

    describe "group events (routed through Reporter named methods)" do
      it "dispatches :example_group_started with the group" do
        group = Serializer::SerializedGroup.new("A", 1, {}, "A")
        rehydrator.handle([:event, :example_group_started, 0, [:group, group]])
        expect(reporter).to have_received(:example_group_started).with(group)
      end

      it "dispatches :example_group_finished with the group" do
        group = Serializer::SerializedGroup.new("A", 1, {}, "A")
        rehydrator.handle([:event, :example_group_finished, 0, [:group, group]])
        expect(reporter).to have_received(:example_group_finished).with(group)
      end
    end

    it "passes a :raw payload through notify verbatim" do
      raw = RSpec::Core::Notifications::MessageNotification.new("hi")
      rehydrator.handle([:event, :message, 0, [:raw, raw]])
      expect(reporter).to have_received(:notify).with(:message, raw)
    end

    it "wraps an :example payload in an ExampleNotification for non-routed events" do
      ex = double("example", :id => "./a_spec.rb[1:1]")
      rehydrator.handle([:event, :example_custom, 0, [:example, ex]])
      expect(reporter).to have_received(:notify) do |event_name, notification|
        expect(event_name).to eq(:example_custom)
        expect(notification).to be_a(RSpec::Core::Notifications::ExampleNotification)
      end
    end

    it "wraps a :group payload in a GroupNotification for non-routed events" do
      group = double("group")
      rehydrator.handle([:event, :group_custom, 0, [:group, group]])
      expect(reporter).to have_received(:notify) do |event_name, notification|
        expect(event_name).to eq(:group_custom)
        expect(notification).to be_a(RSpec::Core::Notifications::GroupNotification)
      end
    end

    it "raises on an unknown payload kind" do
      expect {
        rehydrator.handle([:event, :mystery, 0, [:bogus, :stuff]])
      }.to raise_error(ArgumentError, /Unknown parallel payload kind/)
    end

    describe "example identity across events" do
      # Workers serialize a fresh snapshot per event, but the Reporter
      # stores the object it saw at example_started and re-reads it at dump
      # time (JSON formatter per-example fields, profiler, persistence).
      # Regression: without canonicalization, `--format json` emitted
      # status:"" / run_time:null for every example under parallel.
      it "funnels every event for an id through the object seen first, synced to the latest state" do
        started  = serialized_example(status: nil)
        finished = serialized_example(status: :passed)

        rehydrator.handle([:event, :example_started, 0, [:example, started]])
        rehydrator.handle([:event, :example_finished, 0, [:example, finished]])

        # The reporter received the *same object* both times...
        expect(reporter).to have_received(:example_started).with(equal(started))
        expect(reporter).to have_received(:example_finished).with(equal(started))

        # ...updated in place with the final execution result.
        expect(started.execution_result.status).to eq(:passed)
      end

      it "exposes executed examples by id with their final results" do
        rehydrator.handle([:event, :example_started, 0, [:example, serialized_example(status: nil)]])
        rehydrator.handle([:event, :example_passed, 0, [:example, serialized_example(status: :passed)]])

        canonical = rehydrator.examples_by_id.fetch("./a_spec.rb[1:1]")
        expect(canonical.execution_result.status).to eq(:passed)
      end
    end
  end
end
