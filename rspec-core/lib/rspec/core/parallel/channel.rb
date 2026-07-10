module RSpec
  module Core
    module Parallel
      # Bidirectional IPC channel between the parent process and a worker.
      # Built on a pair of `IO.pipe`s with length-prefixed Marshal framing,
      # matching the pattern used by `RSpec::Core::Bisect::Channel`.
      #
      # Lifecycle:
      #   channel = Channel.new      # parent, before fork
      #   if fork
      #     channel.close_worker_ends # parent keeps parent FDs
      #     channel.send(work)
      #     event = channel.receive
      #   else
      #     channel.close_parent_ends # child keeps worker FDs
      #     work = channel.receive
      #     channel.send(result)
      #   end
      #
      # @private
      class Channel
        MARSHAL_DUMP_ENCODING = Marshal.dump("").encoding

        def initialize
          # "down" pipe: parent writes, worker reads (work dispatch).
          @down_read, @down_write = IO.pipe
          # "up" pipe: worker writes, parent reads (events, results).
          @up_read,   @up_write   = IO.pipe

          [@down_write, @up_write].each { |io| io.set_encoding MARSHAL_DUMP_ENCODING }
        end

        # Called by the parent after forking a worker. Drops FDs that only
        # the worker side needs, so the kernel's refcount reaches zero when
        # the worker exits -- otherwise the parent's `receive` blocks forever.
        def close_worker_ends
          @down_read.close
          @up_write.close
        end

        # Mirror of `close_worker_ends`, called inside the forked worker.
        # Runs in fork child only.
        # :nocov:
        def close_parent_ends
          @down_write.close
          @up_read.close
        end
        # :nocov:

        # Parent -> worker. Safe to call after `close_worker_ends`.
        def send_to_worker(message)
          write_packet(@down_write, message)
        end

        # Worker -> parent. Safe to call after `close_parent_ends`.
        def send_to_parent(message)
          write_packet(@up_write, message)
        end

        # Parent-side blocking read of the next worker event. Returns `nil`
        # on clean EOF (worker exited).
        def receive_from_worker
          read_packet(@up_read)
        end

        # Worker-side blocking read of the next work item. Returns `nil` on
        # clean EOF (parent closed the pipe to signal shutdown).
        def receive_from_parent
          read_packet(@down_read)
        end

        # Returns the parent-side read IO so a `WorkerPool` can `IO.select`
        # across many workers' up-pipes simultaneously.
        attr_reader :up_read

        # Returns the parent-side write IO. Exposed so the pool can (a)
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

        # Any framing or payload error is reported as `nil`, exactly like
        # EOF: a non-numeric header, a short read, or a Marshal parse
        # failure all mean the peer died mid-write (or the stream is
        # corrupt beyond recovery). Callers already treat `nil` as "peer
        # is gone" -- on the parent side that routes into the
        # worker-crashed/requeue path instead of dumping an
        # rspec-internals backtrace at the user.
        # rubocop:disable Security/MarshalLoad
        def read_packet(io)
          header = io.gets
          return nil if header.nil?
          packet_size = Integer(header)
          packet = io.read(packet_size)
          return nil if packet.nil? || packet.bytesize < packet_size
          Marshal.load(packet)
        rescue ArgumentError, TypeError, IOError, SystemCallError
          nil
        end
        # rubocop:enable Security/MarshalLoad
      end
    end
  end
end
