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

    it "disables parallel (nil) when N < 2" do
      expect(Parser.parse(%w[--parallel=1])[:parallel_workers]).to be_nil
      expect(Parser.parse(%w[--parallel=0])[:parallel_workers]).to be_nil
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
  end
end
