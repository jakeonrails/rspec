require 'rspec/core'

module RSpec::Core
  RSpec.describe Configuration, "parallel lifecycle hooks" do
    subject(:config) { Configuration.new }

    describe "#parallelize_before_fork" do
      it "accumulates blocks and fires them in registration order" do
        log = []
        config.parallelize_before_fork { log << :first }
        config.parallelize_before_fork { log << :second }
        config.fire_parallelize_before_fork_hooks
        expect(log).to eq([:first, :second])
      end

      it "is a no-op when no blocks are registered" do
        expect { config.fire_parallelize_before_fork_hooks }.not_to raise_error
      end
    end

    describe "#parallelize_setup" do
      it "fires each block with the worker number, in registration order" do
        log = []
        config.parallelize_setup { |n| log << [:a, n] }
        config.parallelize_setup { |n| log << [:b, n] }
        config.fire_parallelize_setup_hooks(2)
        expect(log).to eq([[:a, 2], [:b, 2]])
      end
    end

    describe "#parallelize_teardown" do
      it "fires each block with the worker number, in registration order" do
        log = []
        config.parallelize_teardown { |n| log << [:a, n] }
        config.parallelize_teardown { |n| log << [:b, n] }
        config.fire_parallelize_teardown_hooks(3)
        expect(log).to eq([[:a, 3], [:b, 3]])
      end
    end
  end

  RSpec.describe Configuration, "parallel_runtime_log_path" do
    it "defaults to nil so no log is written into the project unless the user opts in" do
      expect(Configuration.new.parallel_runtime_log_path).to be_nil
    end
  end

  RSpec.describe "RSpec.parallel_worker_number" do
    # Save/restore so these tests pass even when running rspec-core's own
    # suite under --parallel -- the worker sets parallel_worker_number to
    # its index before running, which is the correct production behavior
    # but violates this block's "default is nil" assertion unless isolated.
    before do
      @prev_worker_number = RSpec.parallel_worker_number
      RSpec.parallel_worker_number = nil
    end
    after { RSpec.parallel_worker_number = @prev_worker_number }

    it "is nil by default" do
      expect(RSpec.parallel_worker_number).to be_nil
    end

    it "is readable after being set" do
      RSpec.parallel_worker_number = 4
      expect(RSpec.parallel_worker_number).to eq(4)
    end
  end
end
