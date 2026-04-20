module RSpec
  module Core
    module Parallel
      # Bidirectional IPC channel between the master process and a worker.
      # Built on a pair of `IO.pipe`s with length-prefixed Marshal framing,
      # matching the pattern used by `RSpec::Core::Bisect::Channel`.
      #
      # Lifecycle:
      #   channel = Channel.new      # parent, before fork
      #   if fork
      #     channel.close_worker_ends # parent keeps master FDs
      #     channel.send(work)
      #     event = channel.receive
      #   else
      #     channel.close_master_ends # child keeps worker FDs
      #     work = channel.receive
      #     channel.send(result)
      #   end
      #
      # @private
      class Channel
        MARSHAL_DUMP_ENCODING = Marshal.dump("").encoding

        def initialize
          # "down" pipe: master writes, worker reads (work dispatch).
          @down_read, @down_write = IO.pipe
          # "up" pipe: worker writes, master reads (events, results).
          @up_read,   @up_write   = IO.pipe

          [@down_write, @up_write].each { |io| io.set_encoding MARSHAL_DUMP_ENCODING }
        end

        # Called by the master after forking a worker. Drops FDs that only
        # the worker side needs, so the kernel's refcount reaches zero when
        # the worker exits -- otherwise the master's `receive` blocks forever.
        def close_worker_ends
          @down_read.close
          @up_write.close
        end

        # Mirror of `close_worker_ends`, called inside the forked worker.
        def close_master_ends
          @down_write.close
          @up_read.close
        end

        # Master -> worker. Safe to call after `close_worker_ends`.
        def send_to_worker(message)
          write_packet(@down_write, message)
        end

        # Worker -> master. Safe to call after `close_master_ends`.
        def send_to_master(message)
          write_packet(@up_write, message)
        end

        # Master-side blocking read of the next worker event. Returns `nil`
        # on clean EOF (worker exited).
        def receive_from_worker
          read_packet(@up_read)
        end

        # Worker-side blocking read of the next work item. Returns `nil` on
        # clean EOF (master closed the pipe to signal shutdown).
        def receive_from_master
          read_packet(@down_read)
        end

        # Returns the master-side read IO so a `WorkerPool` can `IO.select`
        # across many workers' up-pipes simultaneously.
        attr_reader :up_read

        # Returns the master-side write IO. Exposed so the pool can (a)
        # pass the FD to `IO.select`'s writers array to learn when a worker
        # has drained its input, and (b) close this end as the
        # "no-more-work" EOF signal to the worker.
        attr_reader :down_write

        def close
          [@down_read, @down_write, @up_read, @up_write].each do |io|
            io.close unless io.closed?
          end
        end

      private

        def write_packet(io, message)
          packet = Marshal.dump(message)
          io.write("#{packet.bytesize}\n#{packet}")
        end

        # rubocop:disable Security/MarshalLoad
        def read_packet(io)
          header = io.gets
          return nil if header.nil?
          packet_size = Integer(header)
          Marshal.load(io.read(packet_size))
        end
        # rubocop:enable Security/MarshalLoad
      end
    end
  end
end
