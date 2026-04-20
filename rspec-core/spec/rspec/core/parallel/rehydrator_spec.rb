require 'rspec/core/parallel/rehydrator'
require 'rspec/core/parallel/serializer'

module RSpec::Core::Parallel
  RSpec.describe Rehydrator do
    let(:reporter) { instance_double("RSpec::Core::Reporter", :notify => nil) }
    subject(:rehydrator) { described_class.new(reporter) }

    def serialized_example(status: :passed, skipped: false, exception: nil)
      exec = Serializer::SerializedExecutionResult.new(
        status, 0.01, nil, nil, Time.now, Time.now, exception, skipped, nil
      )
      Serializer::SerializedExample.new(
        "./a_spec.rb[1:1]", "does a thing", "A does a thing",
        "./a_spec.rb:1", "./a_spec.rb:1",
        {:file_path => "./a_spec.rb"}, exec,
        Serializer::SerializedGroup.new("A", 1, {})
      )
    end

    describe "#rehydrate" do
      it "returns nil for non-event wire messages (control plane)" do
        expect(rehydrator.rehydrate([:group_finished, "./a_spec.rb:1", :ok])).to be_nil
        expect(rehydrator.rehydrate([:worker_exit, 0])).to be_nil
      end

      it "wraps a serialized example in a plain ExampleNotification for :example_started" do
        ex = serialized_example
        event_name, notif = rehydrator.rehydrate([:event, :example_started, 0, [:example, ex]])
        expect(event_name).to eq(:example_started)
        expect(notif).to be_a(RSpec::Core::Notifications::ExampleNotification)
        expect(notif.example).to equal(ex)
      end

      it "wraps a serialized example in a plain ExampleNotification for :example_passed" do
        ex = serialized_example
        _, notif = rehydrator.rehydrate([:event, :example_passed, 0, [:example, ex]])
        expect(notif.class).to eq(RSpec::Core::Notifications::ExampleNotification)
      end

      it "routes :example_pending with skipped=true to SkippedExampleNotification" do
        ex = serialized_example(status: :pending, skipped: true)
        _, notif = rehydrator.rehydrate([:event, :example_pending, 0, [:example, ex]])
        expect(notif).to be_a(RSpec::Core::Notifications::SkippedExampleNotification)
      end

      it "wraps a serialized group in GroupNotification for :example_group_started" do
        group = Serializer::SerializedGroup.new("A", 1, {})
        event, notif = rehydrator.rehydrate([:event, :example_group_started, 0, [:group, group]])
        expect(event).to eq(:example_group_started)
        expect(notif).to be_a(RSpec::Core::Notifications::GroupNotification)
        expect(notif.group).to equal(group)
      end

      it "passes a :raw payload through verbatim" do
        raw = RSpec::Core::Notifications::MessageNotification.new("hi")
        _, notif = rehydrator.rehydrate([:event, :message, 0, [:raw, raw]])
        expect(notif).to equal(raw)
      end
    end

    describe "#handle" do
      it "dispatches events to the reporter and ignores control messages" do
        ex = serialized_example
        rehydrator.handle([:event, :example_started, 0, [:example, ex]])
        rehydrator.handle([:group_finished, "./a_spec.rb:1", :ok])
        rehydrator.handle([:worker_exit, 0])

        expect(reporter).to have_received(:notify).with(
          :example_started, an_instance_of(RSpec::Core::Notifications::ExampleNotification)
        )
        expect(reporter).to have_received(:notify).once
      end
    end
  end
end
