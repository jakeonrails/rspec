Feature: Parallel execution configuration

  Several configuration options govern RSpec's fork-based parallel runner.
  These complement the `--parallel[=N]` command-line flag.

  * `config.default_parallel_workers` sets the worker count when `--parallel`
    is passed with no argument (and when no explicit `--parallel=N` is
    given). Accepts an integer or the symbol `:number_of_processors`.
  * `config.parallelize_before_fork` registers a parent-side hook that
    fires once, after `before(:suite)`, before any worker is forked.
  * `config.parallelize_setup` registers a worker-side hook that fires
    once per worker, immediately after the fork.
  * `config.parallelize_teardown` registers a worker-side hook that fires
    once per worker, just before the worker exits.
  * `config.parallel_runtime_log_path` enables longest-processing-time
    balancing. When set, RSpec reads prior per-group timings from the log,
    sorts the queue so longer groups dispatch first, then rewrites the log
    with fresh timings. It defaults to `nil`: no log is read or written
    unless you opt in (add the log to your `.gitignore`). Balancing never
    reorders the queue under `--order defined`.

  `RSpec.parallel_worker_number` is available inside workers (zero-based)
  and is `nil` on the parent.

  Parallel execution requires a platform that supports `Process.fork`.

  Scenario: Setting `default_parallel_workers` as an integer
    Given a file named "spec/spec_helper.rb" with:
      """ruby
      RSpec.configure { |c| c.default_parallel_workers = 2 }
      """
    And a file named "spec/example_spec.rb" with:
      """ruby
      require "spec_helper"
      RSpec.describe "A" do
        it("a") {}
      end
      RSpec.describe "B" do
        it("b") {}
      end
      """
    When I run `rspec --parallel spec/example_spec.rb`
    Then the output should contain "2 examples, 0 failures"
    And the exit status should be 0

  Scenario: Setting `default_parallel_workers` to the number of processors
    Given a file named "spec/spec_helper.rb" with:
      """ruby
      RSpec.configure { |c| c.default_parallel_workers = :number_of_processors }
      """
    And a file named "spec/example_spec.rb" with:
      """ruby
      require "spec_helper"
      RSpec.describe "A" do
        it("a") {}
      end
      """
    When I run `rspec --parallel spec/example_spec.rb`
    Then the output should contain "1 example, 0 failures"
    And the exit status should be 0

  Scenario: Registering fork lifecycle hooks
    Given a file named "spec/spec_helper.rb" with:
      """ruby
      RSpec.configure do |c|
        c.parallelize_before_fork do
          File.open("hooks.log", "a") { |f| f.puts "before_fork:parent" }
        end

        c.parallelize_setup do |worker_number|
          File.open("hooks.log", "a") { |f| f.puts "setup:#{worker_number}" }
        end

        c.parallelize_teardown do |worker_number|
          File.open("hooks.log", "a") { |f| f.puts "teardown:#{worker_number}" }
        end
      end
      """
    And a file named "spec/example_spec.rb" with:
      """ruby
      require "spec_helper"
      RSpec.describe "A" do
        it("a") { expect(RSpec.parallel_worker_number).not_to be_nil }
      end
      RSpec.describe "B" do
        it("b") { expect(RSpec.parallel_worker_number).not_to be_nil }
      end
      """
    When I run `rspec --parallel=2 spec/example_spec.rb`
    Then the output should contain "2 examples, 0 failures"
    And the file "hooks.log" should contain "before_fork:parent"
    And the file "hooks.log" should contain "setup:0"
    And the file "hooks.log" should contain "setup:1"
    And the file "hooks.log" should contain "teardown:0"
    And the file "hooks.log" should contain "teardown:1"

  Scenario: Enabling the runtime log for longest-processing-time balancing
    Given a file named "spec/spec_helper.rb" with:
      """ruby
      RSpec.configure { |c| c.parallel_runtime_log_path = "parallel_runtime.log" }
      """
    And a file named "spec/example_spec.rb" with:
      """ruby
      require "spec_helper"
      RSpec.describe "A" do
        it("a") {}
      end
      RSpec.describe "B" do
        it("b") {}
      end
      """
    When I run `rspec --parallel=2 spec/example_spec.rb`
    Then the output should contain "2 examples, 0 failures"
    And a file named "parallel_runtime.log" should exist

  Scenario: No runtime log is written unless the path is configured
    Given a file named "spec/example_spec.rb" with:
      """ruby
      RSpec.describe "A" do
        it("a") {}
      end
      """
    When I run `rspec --parallel=2 spec/example_spec.rb`
    Then the output should contain "1 example, 0 failures"
    And a file named ".rspec_parallel_runtime.log" should not exist
