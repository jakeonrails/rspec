require 'rspec/core/parallel/channel'

module RSpec::Core::Parallel
  RSpec.describe Channel do
    it "round-trips a message from parent to worker to parent within one process" do
      channel = Channel.new
      channel.send_to_worker({ :work => :a })
      expect(channel.receive_from_parent).to eq({ :work => :a })

      channel.send_to_parent({ :result => :ok })
      expect(channel.receive_from_worker).to eq({ :result => :ok })
    end

    it "supports binary data (Marshal output encoding)" do
      channel = Channel.new
      channel.send_to_parent("\xF8")
      expect(channel.receive_from_worker).to eq("\xF8")
    end

    context "across a real fork" do
      before { skip "fork not available on this platform" unless Process.respond_to?(:fork) }

      it "delivers work from parent to worker and events back" do
        channel = Channel.new

        pid = Process.fork do
          channel.close_parent_ends
          work = channel.receive_from_parent
          channel.send_to_parent([:event, :example_finished, work[:n], :payload])
          channel.send_to_parent([:group_finished, work[:key], :ok])
          channel.close
          exit!(0)
        end

        channel.close_worker_ends
        channel.send_to_worker(:n => 0, :key => "spec/foo_spec.rb:12")

        events = []
        2.times { events << channel.receive_from_worker }

        Process.waitpid(pid)
        channel.close

        expect(events).to eq([
          [:event, :example_finished, 0, :payload],
          [:group_finished, "spec/foo_spec.rb:12", :ok]
        ])
      end

      it "returns nil on EOF so worker runloops can exit cleanly" do
        channel = Channel.new

        pid = Process.fork do
          channel.close_parent_ends
          received = channel.receive_from_parent
          channel.send_to_parent([:got, received])
          # receive again, expect EOF when parent closes its down-pipe
          eof = channel.receive_from_parent
          channel.send_to_parent([:eof, eof.nil?])
          channel.close
          exit!(0)
        end

        channel.close_worker_ends
        channel.send_to_worker(:first)
        expect(channel.receive_from_worker).to eq([:got, :first])

        # Signal shutdown by closing only the down-write end. The public
        # `close` would drop all four FDs.
        channel.down_write.close
        expect(channel.receive_from_worker).to eq([:eof, true])

        Process.waitpid(pid)
        channel.close
      end
    end
  end
end
