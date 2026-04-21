Feature: `--parallel` option

  Use the `--parallel[=N]` option to run example groups across N fork-based
  worker processes in parallel. With no argument, RSpec uses one worker per
  available CPU (`Etc.nprocessors`).

  Each worker loads your spec files pre-fork, so startup is paid once. The
  master runs `before(:suite)` and `after(:suite)` hooks once, straddling the
  pool. Workers run example groups pulled from a shared queue and ship
  serialized notifications back to the master, which drives the usual
  formatter pipeline.

  Parallel execution requires a platform that supports `Process.fork`. On
  platforms without fork (e.g. Windows, JRuby), `--parallel` is a no-op and
  specs run serially.

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

  Scenario: A failing example in any group surfaces in the master's output
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
