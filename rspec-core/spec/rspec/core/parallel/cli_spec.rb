require 'rspec/core'
require 'rspec/core/option_parser'

module RSpec::Core
  RSpec.describe "--parallel CLI flag" do
    it "parses --parallel=N to parallel_workers = N" do
      opts = Parser.parse(%w[--parallel=4])
      expect(opts[:parallel_workers]).to eq(4)
    end

    it "parses a bare --parallel to `true`, deferring count resolution to run time" do
      # The count must NOT be resolved while parsing: `spec_helper.rb`
      # (where `default_parallel_workers` typically lives) has not been
      # loaded yet. `Runner#effective_parallel_workers` resolves it.
      opts = Parser.parse(%w[--parallel])
      expect(opts[:parallel_workers]).to be(true)
    end

    it "preserves explicit N < 2 so users can force serial over a configured default" do
      expect(Parser.parse(%w[--parallel=1])[:parallel_workers]).to eq(1)
      expect(Parser.parse(%w[--parallel=0])[:parallel_workers]).to eq(0)
    end

    it "rejects a negative worker count with a clear error" do
      expect {
        expect { Parser.parse(%w[--parallel=-3]) }.to raise_error(SystemExit)
      }.to output(/Invalid `--parallel` worker count: -3/).to_stderr
    end

    it "parses --no-parallel to parallel_workers = 0" do
      expect(Parser.parse(%w[--no-parallel])[:parallel_workers]).to eq(0)
    end

    it "lets an explicit --parallel=N win over --no-parallel regardless of order" do
      expect(Parser.parse(%w[--parallel=4 --no-parallel])[:parallel_workers]).to eq(4)
      expect(Parser.parse(%w[--no-parallel --parallel=4])[:parallel_workers]).to eq(4)
    end

    it "lets --no-parallel override a bare --parallel that precedes it" do
      expect(Parser.parse(%w[--parallel --no-parallel])[:parallel_workers]).to eq(0)
    end

    it "applies to Configuration via ConfigurationOptions" do
      config = Configuration.new
      options = ConfigurationOptions.new(%w[--parallel=3])
      options.configure(config)
      expect(config.parallel_workers).to eq(3)
    end

    it "forces the CLI value so RSpec.configure cannot override it" do
      config = Configuration.new
      options = ConfigurationOptions.new(%w[--parallel=3])
      options.configure(config)
      config.parallel_workers = 8 # e.g. spec_helper.rb loaded afterwards
      expect(config.parallel_workers).to eq(3)
    end
  end

  RSpec.describe "PARALLEL_WORKERS environment variable" do
    it "supplies the worker count when no CLI parallel flag is given" do
      with_env_vars 'PARALLEL_WORKERS' => '3' do
        opts = ConfigurationOptions.new([]).options
        expect(opts[:parallel_workers]).to eq(3)
      end
    end

    it "loses to an explicit --parallel=N" do
      with_env_vars 'PARALLEL_WORKERS' => '3' do
        opts = ConfigurationOptions.new(%w[--parallel=5]).options
        expect(opts[:parallel_workers]).to eq(5)
      end
    end

    it "loses to --no-parallel" do
      with_env_vars 'PARALLEL_WORKERS' => '3' do
        opts = ConfigurationOptions.new(%w[--no-parallel]).options
        expect(opts[:parallel_workers]).to eq(0)
      end
    end

    it "supplies the count for a bare --parallel" do
      with_env_vars 'PARALLEL_WORKERS' => '3' do
        opts = ConfigurationOptions.new(%w[--parallel]).options
        expect(opts[:parallel_workers]).to eq(3)
      end
    end

    it "beats `parallel_workers` assigned in RSpec.configure, by virtue of being forced" do
      with_env_vars 'PARALLEL_WORKERS' => '3' do
        config = Configuration.new
        ConfigurationOptions.new([]).configure(config)
        config.parallel_workers = 8
        expect(config.parallel_workers).to eq(3)
      end
    end

    it "warns and ignores a non-integer value" do
      with_env_vars 'PARALLEL_WORKERS' => 'lots' do
        expect(RSpec).to receive(:warning).with(/PARALLEL_WORKERS/, anything)
        opts = ConfigurationOptions.new([]).options
        expect(opts).not_to have_key(:parallel_workers)
      end
    end

    it "treats an empty string as unset" do
      with_env_vars 'PARALLEL_WORKERS' => '' do
        opts = ConfigurationOptions.new([]).options
        expect(opts).not_to have_key(:parallel_workers)
      end
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
      allow(RSpec).to receive(:warning)
      expect(runner.parallel?).to be(false)
    end

    it "warns exactly once when parallel is requested but fork is unavailable" do
      config.parallel_workers = 4
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

      expect(RSpec).to receive(:warning).once.with(
        /Parallel execution was requested \(4 workers\).*Process\.fork.*serially/m, anything
      )

      expect(runner.parallel?).to be(false)
      expect(runner.parallel?).to be(false)
    end

    it "does not warn when parallel was never requested" do
      config.parallel_workers = nil
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      expect(RSpec).not_to receive(:warning)
      expect(runner.parallel?).to be_falsy
    end

    it "reports parallel? = false when parallel_workers = 1" do
      config.parallel_workers = 1
      expect(runner.parallel?).to be(false)
    end

    it "#run_specs_in_parallel delegates to Parallel::Runner with the resolved worker count" do
      RSpec::Support.require_rspec_core "parallel/runner"
      config.parallel_workers = 3
      example_groups = [:group_a, :group_b]
      parallel_runner = instance_double(
        RSpec::Core::Parallel::Runner, :executed_example_results => {}
      )

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

  RSpec.describe Runner, "bare --parallel (parallel_workers = true) resolution" do
    let(:config)  { Configuration.new }
    let(:world)   { World.new(config) }
    let(:options) { ConfigurationOptions.new(%w[--parallel]) }
    subject(:runner) { Runner.new(options, config, world) }

    before do
      allow(Process).to receive(:respond_to?).with(:fork).and_return(true)
      config.parallel_workers = true
    end

    it "uses default_parallel_workers when configured" do
      config.default_parallel_workers = 3
      expect(runner.effective_parallel_workers).to eq(3)
    end

    it "resolves a :number_of_processors default" do
      require 'etc'
      config.default_parallel_workers = :number_of_processors
      expect(runner.effective_parallel_workers).to eq(Etc.nprocessors)
    end

    it "falls back to the number of available CPUs when no default is configured" do
      require 'etc'
      expect(runner.effective_parallel_workers).to eq(Etc.nprocessors)
    end
  end
end
