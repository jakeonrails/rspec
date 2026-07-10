Feature: `--parallel` option

  Use the `--parallel[=N]` option to run example groups across N fork-based
  worker processes in parallel. `--parallel=0` and `--parallel=1` run
  serially. With no argument, `--parallel` enables parallel execution and
  resolves the worker count in this order: the `PARALLEL_WORKERS`
  environment variable, then `config.default_parallel_workers`, then one
  worker per available CPU (`Etc.nprocessors`).

  Use `--no-parallel` to force a serial run, overriding `PARALLEL_WORKERS`,
  `config.parallel_workers` and `config.default_parallel_workers`. An
  explicit `--parallel=N` wins over `--no-parallel` regardless of the order
  in which they appear.

  The full precedence for the worker count, highest first:

  * `--parallel=N` (explicit count on the command line)
  * `--no-parallel`
  * the `PARALLEL_WORKERS` environment variable
  * `config.parallel_workers`
  * `config.default_parallel_workers`

  Each worker loads your spec files pre-fork, so startup is paid once. The
  parent runs `before(:suite)` and `after(:suite)` hooks once, straddling the
  pool. Workers run example groups pulled from a shared queue and ship
  serialized notifications back to the parent, which drives the usual
  formatter pipeline.

  Parallel execution requires a platform that supports `Process.fork`. On
  platforms without fork (e.g. Windows, JRuby), requesting parallel
  execution emits a single warning and the suite runs serially.

  Caveats compared to a serial run:

  * Fail-fast is best-effort across workers: groups already in flight when
    the threshold is met run to completion and report normally.
  * Custom formatters receive serialized stand-ins for examples, groups and
    exceptions, not the live objects. Unmarshalable metadata values degrade
    to their `inspect` string and `metadata[:block]` is stripped.
  * If a worker crashes twice on the same group, the run fails with a
    synthetic error naming the group -- that group's examples appear in
    neither the JSON output nor the summary counts.
  * `--profile` attributes nested groups' examples to the innermost group.
  * `--bisect` always runs serially, ignoring parallel flags and config.

  Background:
    Given a file named "spec/example_spec.rb" with:
      """ruby
      RSpec.describe "group A" do
        it("passes a1") {}
        it("passes a2") {}
      end

      RSpec.describe "group B" do
        it("passes b1") {}
        it("passes b2") {}
      end

      RSpec.describe "group C" do
        it("passes c1") {}
        it("passes c2") {}
      end

      RSpec.describe "group D" do
        it("passes d1") {}
        it("passes d2") {}
      end
      """

  Scenario: Using `--parallel=N` with an explicit worker count
    When I run `rspec --parallel=2 spec/example_spec.rb`
    Then the output should contain "8 examples, 0 failures"
    And the exit status should be 0

  Scenario: Using `--parallel` with no argument (defaults to number of CPUs)
    When I run `rspec --parallel spec/example_spec.rb`
    Then the output should contain "8 examples, 0 failures"
    And the exit status should be 0

  Scenario: A failing example in any group surfaces in the parent's output
    Given a file named "spec/failing_spec.rb" with:
      """ruby
      RSpec.describe "passing group" do
        it("passes") {}
      end

      RSpec.describe "failing group" do
        it("fails") { expect(1).to eq(2) }
      end
      """
    When I run `rspec --parallel=2 spec/failing_spec.rb`
    Then the output should contain "2 examples, 1 failure"
    And the exit status should be 1

  Scenario: Custom formatters can read nested metadata from serialized examples
    Given a file named "spec/group_description_formatter.rb" with:
      """ruby
      class GroupDescriptionFormatter
        RSpec::Core::Formatters.register self, :example_passed

        def initialize(output)
          @output = output
        end

        def example_passed(notification)
          # Reaches through the serialized example into nested group
          # metadata, which must survive the worker -> parent round trip
          # as a real hash.
          @output.puts "group: #{notification.example.metadata[:example_group][:description]}"
        end
      end
      """
    When I run `rspec --parallel=2 --require ./spec/group_description_formatter --format GroupDescriptionFormatter spec/example_spec.rb`
    Then the output should contain "group: group A"
    And the output should contain "group: group D"
    And the exit status should be 0

  Scenario: Using the `PARALLEL_WORKERS` environment variable instead of a flag
    Given a file named "spec/worker_number_spec.rb" with:
      """ruby
      RSpec.describe "parallel run" do
        it "runs inside a worker" do
          expect(RSpec.parallel_worker_number).not_to be_nil
        end
      end
      """
    And I set the environment variable "PARALLEL_WORKERS" to "2"
    When I run `rspec spec/worker_number_spec.rb`
    Then the output should contain "1 example, 0 failures"
    And the exit status should be 0

  Scenario: Using `--no-parallel` to force a serial run over a configured default
    Given a file named "spec/spec_helper.rb" with:
      """ruby
      RSpec.configure { |c| c.default_parallel_workers = 2 }
      """
    And a file named "spec/serial_spec.rb" with:
      """ruby
      require "spec_helper"
      RSpec.describe "serial run" do
        it "does not run inside a worker" do
          expect(RSpec.parallel_worker_number).to be_nil
        end
      end
      """
    When I run `rspec --no-parallel spec/serial_spec.rb`
    Then the output should contain "1 example, 0 failures"
    And the exit status should be 0
