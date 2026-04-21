require 'rspec/core'
require 'rspec/core/option_parser'

module RSpec::Core
  RSpec.describe "--parallel CLI flag" do
    it "parses --parallel=N to parallel_workers = N" do
      opts = Parser.parse(%w[--parallel=4])
      expect(opts[:parallel_workers]).to eq(4)
    end

    it "parses --parallel alone to Etc.nprocessors" do
      require 'etc'
      opts = Parser.parse(%w[--parallel])
      expect(opts[:parallel_workers]).to eq(Etc.nprocessors)
    end

    it "preserves explicit N < 2 so users can force serial over a configured default" do
      expect(Parser.parse(%w[--parallel=1])[:parallel_workers]).to eq(1)
      expect(Parser.parse(%w[--parallel=0])[:parallel_workers]).to eq(0)
    end

    it "applies to Configuration via ConfigurationOptions" do
      config = Configuration.new
      options = ConfigurationOptions.new(%w[--parallel=3])
      options.configure(config)
      expect(config.parallel_workers).to eq(3)
    end
  end

  RSpec.describe Runner, "parallel dispatch" do
    let(:options) { ConfigurationOptions.new(%w[--parallel=2]) }
    let(:config)  { Configuration.new }
    let(:world)   { World.new(config) }
    subject(:runner) { Runner.new(options, config, world) }

    it "reports parallel? = true when parallel_workers >= 2 and fork is available" do
      config.parallel_workers = 4
      allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
      expect(runner.parallel?).to be(true)
    end

    it "reports parallel? = falsy when parallel_workers is nil" do
      config.parallel_workers = nil
      expect(runner.parallel?).to be_falsy
    end

    it "reports parallel? = false when fork is not available" do
      config.parallel_workers = 4
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      expect(runner.parallel?).to be(false)
    end

    it "reports parallel? = false when parallel_workers = 1" do
      config.parallel_workers = 1
      expect(runner.parallel?).to be(false)
    end

    it "#run_specs_in_parallel delegates to Parallel::Runner with the resolved worker count" do
      RSpec::Support.require_rspec_core "parallel/runner"
      config.parallel_workers = 3
      example_groups = [:group_a, :group_b]
      parallel_runner = instance_double(RSpec::Core::Parallel::Runner)

      expect(RSpec::Core::Parallel::Runner).to receive(:new).
        with(config, world, 3).and_return(parallel_runner)
      expect(parallel_runner).to receive(:run_specs).with(example_groups).and_return(0)

      expect(runner.run_specs_in_parallel(example_groups)).to eq(0)
    end
  end

  RSpec.describe Runner, "default_parallel_workers fallback" do
    let(:config)  { Configuration.new }
    let(:world)   { World.new(config) }
    let(:options) { ConfigurationOptions.new([]) }
    subject(:runner) { Runner.new(options, config, world) }

    before do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
    end

    it "falls back to default_parallel_workers when --parallel is absent" do
      config.default_parallel_workers = 3
      expect(runner.effective_parallel_workers).to eq(3)
      expect(runner.parallel?).to be(true)
    end

    it "resolves :number_of_processors via Etc.nprocessors" do
      require 'etc'
      config.default_parallel_workers = :number_of_processors
      expect(runner.effective_parallel_workers).to eq(Etc.nprocessors)
    end

    it "lets explicit parallel_workers win over the default" do
      config.parallel_workers = 5
      config.default_parallel_workers = :number_of_processors
      expect(runner.effective_parallel_workers).to eq(5)
    end

    it "stays serial when neither is set" do
      expect(runner.effective_parallel_workers).to eq(0)
      expect(runner.parallel?).to be(false)
    end

    it "stays serial when the default is nil" do
      config.default_parallel_workers = nil
      expect(runner.parallel?).to be(false)
    end

    it "lets explicit --parallel=0 force serial over a configured default" do
      config.default_parallel_workers = :number_of_processors
      config.parallel_workers = 0
      expect(runner.effective_parallel_workers).to eq(0)
      expect(runner.parallel?).to be(false)
    end
  end
end
