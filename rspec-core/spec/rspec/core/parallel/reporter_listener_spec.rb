require 'rspec/core/parallel/reporter_listener'

module RSpec::Core::Parallel
  RSpec.describe ReporterListener do
    # Fake channel that just records what the listener ships upstream.
    let(:fake_channel) do
      Class.new do
        attr_reader :sent

        def initialize = @sent = []
        def send_to_master(msg) = @sent.push(msg)
      end.new
    end

    let(:worker_number) { 2 }
    let(:listener) { ReporterListener.new(fake_channel, worker_number) }

    it "defines a method for every event in Reporter::RSPEC_NOTIFICATIONS" do
      RSpec::Core::Reporter::RSPEC_NOTIFICATIONS.each do |event|
        expect(listener).to respond_to(event)
      end
    end

    it "projects example_finished into a [:event, event, worker_number, [:example, payload]] tuple" do
      example = RSpec.describe("g") { it("e") { } }.examples.first
      notification = RSpec::Core::Notifications::ExampleNotification.send(:new, example)

      listener.example_finished(notification)

      expect(fake_channel.sent.length).to eq(1)
      tag, event, worker, payload = fake_channel.sent.first
      expect(tag).to eq(:event)
      expect(event).to eq(:example_finished)
      expect(worker).to eq(worker_number)
      kind, serialized = payload
      expect(kind).to eq(:example)
      expect(serialized).to be_a(Serializer::SerializedExample)
      expect(serialized.id).to eq(example.id)
    end

    it "projects example_group_started into a [:group, SerializedGroup] payload" do
      group = RSpec.describe("g") { it("e") { } }
      notification = RSpec::Core::Notifications::GroupNotification.new(group)

      listener.example_group_started(notification)

      _, event, _, (kind, serialized) = fake_channel.sent.first
      expect(event).to eq(:example_group_started)
      expect(kind).to eq(:group)
      expect(serialized.description).to eq("g")
    end

    it "ships :raw notifications (seed, message) as-is" do
      seed = RSpec::Core::Notifications::SeedNotification.new(42, true)
      listener.seed(seed)

      _, event, _, (kind, payload) = fake_channel.sent.first
      expect(event).to eq(:seed)
      expect(kind).to eq(:raw)
      expect(payload).to equal(seed)
    end

    it "Marshal-round-trips every sent message (what would go over the pipe)" do
      example = RSpec.describe("g") { it("e") { } }.examples.first
      notification = RSpec::Core::Notifications::ExampleNotification.send(:new, example)

      listener.example_finished(notification)
      msg = fake_channel.sent.first

      restored = Marshal.load(Marshal.dump(msg))
      expect(restored[0]).to eq(:event)
      expect(restored[1]).to eq(:example_finished)
      expect(restored[3][0]).to eq(:example)
      expect(restored[3][1].id).to eq(example.id)
    end

    describe ".install" do
      it "registers the new listener against every RSPEC_NOTIFICATIONS event on a fresh reporter" do
        configuration = RSpec::Core::Configuration.new
        listener = ReporterListener.install(configuration, fake_channel, 0)

        reporter = configuration.reporter
        RSpec::Core::Reporter::RSPEC_NOTIFICATIONS.each do |event|
          expect(reporter.registered_listeners(event)).to include(listener)
        end
      end
    end
  end
end
