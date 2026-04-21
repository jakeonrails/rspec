module RSpec
  module Core
    module Parallel
      # Logfile-backed LPT (longest-processing-time) queue balancer.
      #
      # Without balancing, a single slow group becomes the critical-path
      # tail of a --parallel run: dynamic dispatch only helps when the
      # slow work happens to be picked up early. Sorting the queue so
      # that known-slow keys dispatch first makes the slow group start
      # at t=0 on one worker while the remaining workers drain the fast
      # tail in parallel.
      #
      # The balancer is log-driven rather than static so that timings
      # stay accurate as the suite evolves: each run updates the log
      # for keys it executed, preserving timings for keys that didn't
      # run (filtered runs, partial runs via Ctrl-C).
      #
      # Unknown keys (present in the queue but not in the log) slot
      # ahead of known keys so that newly added spec files don't become
      # the tail on their first run -- once they complete, the updated
      # log will order them correctly on the next run.
      #
      # @private
      module Balancer
        # Reorders `queue` so that the head is:
        #   unknown keys (in original order, as-added)
        #   then known keys, descending by prior runtime.
        def self.sort_queue(queue, timings)
          return queue.dup if timings.empty?
          known, unknown = queue.partition { |key| timings.key?(key) }
          unknown + known.sort_by { |key| -timings.fetch(key) }
        end

        # Reads a tab-separated `key\tseconds` log. Missing file or
        # malformed lines are tolerated -- an unreadable entry just
        # means that key is treated as unknown on this run.
        def self.read_log(path)
          return {} unless path && File.exist?(path)
          timings = {}
          File.foreach(path) do |line|
            key, seconds = line.chomp.split("\t", 2)
            next if key.nil? || key.empty? || seconds.nil?
            begin
              timings[key] = Float(seconds)
            rescue ArgumentError, TypeError
              # Skip malformed row
            end
          end
          timings
        end

        # Writes `timings` to `path` atomically (write to tmp, rename).
        # Entries are sorted by key for deterministic output, which
        # keeps diffs small when the log is version-controlled.
        def self.write_log(path, timings)
          return if path.nil? || timings.empty?
          tmp = "#{path}.#{Process.pid}.tmp"
          File.open(tmp, "w") do |f|
            timings.sort_by { |k, _| k }.each do |key, seconds|
              f.puts "#{key}\t#{format('%.3f', seconds)}"
            end
          end
          File.rename(tmp, path)
        end
      end
    end
  end
end
