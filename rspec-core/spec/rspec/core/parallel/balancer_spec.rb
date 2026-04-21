require 'rspec/core/parallel/balancer'
require 'tmpdir'

module RSpec::Core::Parallel
  RSpec.describe Balancer do
    describe ".sort_queue" do
      it "returns a copy of the queue unchanged when there are no prior timings" do
        queue = ["./spec/a_spec.rb:1", "./spec/b_spec.rb:1", "./spec/c_spec.rb:1"]
        expect(Balancer.sort_queue(queue, {})).to eq(queue)
      end

      it "dispatches slow known keys first" do
        queue = ["./spec/fast_spec.rb:1", "./spec/slow_spec.rb:1", "./spec/medium_spec.rb:1"]
        timings = {
          "./spec/fast_spec.rb:1"   => 0.2,
          "./spec/slow_spec.rb:1"   => 10.0,
          "./spec/medium_spec.rb:1" => 2.5
        }

        sorted = Balancer.sort_queue(queue, timings)

        expect(sorted).to eq([
          "./spec/slow_spec.rb:1",
          "./spec/medium_spec.rb:1",
          "./spec/fast_spec.rb:1"
        ])
      end

      it "slots unknown keys ahead of known keys, preserving their original order" do
        queue = [
          "./spec/known_fast_spec.rb:1",
          "./spec/unknown_a_spec.rb:1",
          "./spec/known_slow_spec.rb:1",
          "./spec/unknown_b_spec.rb:1"
        ]
        timings = {
          "./spec/known_fast_spec.rb:1" => 0.5,
          "./spec/known_slow_spec.rb:1" => 7.0
        }

        sorted = Balancer.sort_queue(queue, timings)

        expect(sorted).to eq([
          "./spec/unknown_a_spec.rb:1",
          "./spec/unknown_b_spec.rb:1",
          "./spec/known_slow_spec.rb:1",
          "./spec/known_fast_spec.rb:1"
        ])
      end

      it "does not mutate the input queue" do
        queue = ["./spec/a_spec.rb:1", "./spec/b_spec.rb:1"]
        frozen = queue.dup.freeze
        timings = { "./spec/a_spec.rb:1" => 1.0, "./spec/b_spec.rb:1" => 2.0 }

        Balancer.sort_queue(frozen, timings)

        expect(queue).to eq(["./spec/a_spec.rb:1", "./spec/b_spec.rb:1"])
      end
    end

    describe ".read_log" do
      it "returns an empty hash when path is nil" do
        expect(Balancer.read_log(nil)).to eq({})
      end

      it "returns an empty hash when the file does not exist" do
        Dir.mktmpdir do |dir|
          expect(Balancer.read_log(File.join(dir, "nope.log"))).to eq({})
        end
      end

      it "parses tab-separated key/seconds lines" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          File.write(path, <<~LOG)
            ./spec/a_spec.rb:1\t1.234
            ./spec/b_spec.rb:10\t5.678
          LOG

          expect(Balancer.read_log(path)).to eq(
            "./spec/a_spec.rb:1"  => 1.234,
            "./spec/b_spec.rb:10" => 5.678
          )
        end
      end

      it "skips malformed rows without crashing" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          File.write(path, <<~LOG)
            ./spec/good_spec.rb:1\t1.5
            this line has no tab
            \ttab-separated but empty key
            ./spec/bad_spec.rb:1\tnot-a-number
            ./spec/another_good_spec.rb:1\t2.0
          LOG

          expect(Balancer.read_log(path)).to eq(
            "./spec/good_spec.rb:1"         => 1.5,
            "./spec/another_good_spec.rb:1" => 2.0
          )
        end
      end
    end

    describe ".write_log" do
      it "writes tab-separated rows sorted by key" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          timings = {
            "./spec/b_spec.rb:1" => 2.5,
            "./spec/a_spec.rb:1" => 0.125,
            "./spec/c_spec.rb:1" => 10.0
          }

          Balancer.write_log(path, timings)

          expect(File.read(path)).to eq(<<~LOG)
            ./spec/a_spec.rb:1\t0.125
            ./spec/b_spec.rb:1\t2.500
            ./spec/c_spec.rb:1\t10.000
          LOG
        end
      end

      it "is a no-op when path is nil or timings are empty" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          Balancer.write_log(nil, { "k" => 1.0 })
          Balancer.write_log(path, {})
          expect(File.exist?(path)).to be(false)
        end
      end

      it "round-trips through read_log" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          timings = {
            "./spec/x_spec.rb:1" => 0.001,
            "./spec/y_spec.rb:1" => 42.42
          }

          Balancer.write_log(path, timings)
          restored = Balancer.read_log(path)

          expect(restored).to eq("./spec/x_spec.rb:1" => 0.001, "./spec/y_spec.rb:1" => 42.42)
        end
      end

      it "writes atomically via a temp file + rename" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "log")
          File.write(path, "./spec/old_spec.rb:1\t99.0\n")

          Balancer.write_log(path, "./spec/new_spec.rb:1" => 1.0)

          # Only the final file should exist -- no .tmp leftover.
          leftovers = Dir.children(dir).reject { |n| n == "log" }
          expect(leftovers).to be_empty
          expect(File.read(path)).to eq("./spec/new_spec.rb:1\t1.000\n")
        end
      end
    end
  end
end
