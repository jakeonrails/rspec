module RSpec
  module Core
    # Provides the main entry point to run a suite of RSpec examples.
    class Runner
      # @attr_reader
      # @private
      attr_reader :options, :configuration, :world

      # Register an `at_exit` hook that runs the suite when the process exits.
      #
      # @note This is not generally needed. The `rspec` command takes care
      #       of running examples for you without involving an `at_exit`
      #       hook. This is only needed if you are running specs using
      #       the `ruby` command, and even then, the normal way to invoke
      #       this is by requiring `rspec/autorun`.
      def self.autorun
        if autorun_disabled?
          RSpec.deprecate("Requiring `rspec/autorun` when running RSpec via the `rspec` command")
          return
        elsif installed_at_exit? || running_in_drb?
          return
        end

        at_exit { perform_at_exit }
        @installed_at_exit = true
      end

      # @private
      def self.perform_at_exit
        # Don't bother running any specs and just let the program terminate
        # if we got here due to an unrescued exception (anything other than
        # SystemExit, which is raised when somebody calls Kernel#exit).
        return unless $!.nil? || $!.is_a?(SystemExit)

        # We got here because either the end of the program was reached or
        # somebody called Kernel#exit. Run the specs and then override any
        # existing exit status with RSpec's exit status if any specs failed.
        invoke
      end

      # Runs the suite of specs and exits the process with an appropriate exit
      # code.
      def self.invoke
        # Re-entrancy guard, scoped to "while a run is in flight". Forked
        # parallel workers inherit `@invoked = true` (the parent's invoke is
        # on the stack at fork time), so a worker exiting via Kernel#exit --
        # done so third-party at_exit hooks like Capybara's driver cleanup
        # can fire -- won't have an autorun at_exit re-run the whole suite.
        # (`exit` in a fork child does not unwind the inherited stack, so
        # the `ensure` below never resets the flag inside a worker.) Once
        # the run completes in the parent, the flag is cleared so a
        # legitimate second `Runner.invoke` in the same process still works.
        return if @invoked
        @invoked = true
        begin
          disable_autorun!
          status = run(ARGV, $stderr, $stdout).to_i
          exit(status) if status != 0
        ensure
          @invoked = false
        end
      end

      # Run a suite of RSpec examples. Does not exit.
      #
      # This is used internally by RSpec to run a suite, but is available
      # for use by any other automation tool.
      #
      # If you want to run this multiple times in the same process, and you
      # want files like `spec_helper.rb` to be reloaded, be sure to load `load`
      # instead of `require`.
      #
      # @param args [Array] command-line-supported arguments
      # @param err [IO] error stream
      # @param out [IO] output stream
      # @return [Fixnum] exit status code. 0 if all specs passed,
      #   or the configured failure exit code (1 by default) if specs
      #   failed.
      def self.run(args, err=$stderr, out=$stdout)
        trap_interrupt
        options = ConfigurationOptions.new(args)

        if options.options[:runner]
          options.options[:runner].call(options, err, out)
        else
          new(options).run(err, out)
        end
      end

      def initialize(options, configuration=RSpec.configuration, world=RSpec.world)
        @options       = options
        @configuration = configuration
        @world         = world
      end

      # Configures and runs a spec suite.
      #
      # @param err [IO] error stream
      # @param out [IO] output stream
      def run(err, out)
        setup(err, out)
        return @configuration.reporter.exit_early(exit_code) if RSpec.world.wants_to_quit

        run_specs(@world.ordered_example_groups).tap do
          persist_example_statuses
        end
      end

      # Wires together the various configuration objects and state holders.
      #
      # @param err [IO] error stream
      # @param out [IO] output stream
      def setup(err, out)
        configure(err, out)
        return if RSpec.world.wants_to_quit

        @configuration.load_spec_files
      ensure
        @world.announce_filters
      end

      # Runs the provided example groups.
      #
      # @param example_groups [Array<RSpec::Core::ExampleGroup>] groups to run
      # @return [Fixnum] exit status code. 0 if all specs passed,
      #   or the configured failure exit code (1 by default) if specs
      #   failed.
      def run_specs(example_groups)
        return run_specs_in_parallel(example_groups) if parallel?

        examples_count = @world.example_count(example_groups)
        examples_passed = @configuration.reporter.report(examples_count) do |reporter|
          @configuration.with_suite_hooks do
            if examples_count == 0 && @configuration.fail_if_no_examples
              return @configuration.failure_exit_code
            end

            example_groups.map { |g| g.run(reporter) }.all?
          end
        end

        exit_code(examples_passed)
      end

      # @private
      def parallel?
        workers = effective_parallel_workers
        return false if workers < 2
        return true if Process.respond_to?(:fork)

        warn_fork_unavailable(workers)
        false
      end

      # @private
      def run_specs_in_parallel(example_groups)
        RSpec::Support.require_rspec_core "parallel/runner"
        parallel_runner = Parallel::Runner.new(
          @configuration, @world, effective_parallel_workers
        )
        parallel_runner.run_specs(example_groups).tap do
          @parallel_example_results = parallel_runner.executed_example_results
        end
      end

      # @private
      # Resolution order for the worker count:
      #   1. An explicit Integer in `parallel_workers` -- set by
      #      `--parallel=N`, `--no-parallel` (0), the `PARALLEL_WORKERS`
      #      environment variable, or `config.parallel_workers = N`.
      #   2. `true` (a bare `--parallel`, meaning "enable parallel"):
      #      `default_parallel_workers` when configured, otherwise one
      #      worker per available CPU.
      #   3. Nothing requested: `default_parallel_workers` when
      #      configured, otherwise 0 (serial).
      # 0 and 1 both mean serial.
      def effective_parallel_workers
        requested = @configuration.parallel_workers
        case requested
        when Integer then requested
        when true    then resolved_default_parallel_workers || number_of_processors
        else              resolved_default_parallel_workers || 0
        end
      end

      # @private
      def resolved_default_parallel_workers
        default = @configuration.default_parallel_workers
        case default
        when :number_of_processors then number_of_processors
        when Integer               then default
        end
      end

      # @private
      def number_of_processors
        require 'etc'
        Etc.nprocessors
      end

      # @private
      # Emitted once per runner: parallel execution was asked for, but the
      # platform can't fork (Windows, JRuby), so the run falls back to
      # serial. Silence it by not requesting parallel execution.
      def warn_fork_unavailable(workers)
        return if @warned_fork_unavailable
        @warned_fork_unavailable = true
        RSpec.warning "Parallel execution was requested (#{workers} workers), but " \
                      "`Process.fork` is not supported on this platform. " \
                      "Falling back to running serially.", :call_site => nil
      end

      # @private
      def configure(err, out)
        @configuration.error_stream = err
        @configuration.output_stream = out if @configuration.output_stream == $stdout
        @options.configure(@configuration)
      end

      # @private
      def self.disable_autorun!
        @autorun_disabled = true
      end

      # @private
      def self.autorun_disabled?
        @autorun_disabled ||= false
      end

      # @private
      def self.installed_at_exit?
        @installed_at_exit ||= false
      end

      # @private
      def self.running_in_drb?
        return false unless defined?(DRb)

        server = begin
                   DRb.current_server
                 rescue DRb::DRbServerNotFound
                   return false
                 end

        return false unless server && server.alive?

        require 'socket'
        require 'uri'

        local_ipv4 = begin
                       IPSocket.getaddress(Socket.gethostname)
                     rescue SocketError
                       return false
                     end

        ["127.0.0.1", "localhost", local_ipv4].any? { |addr| addr == URI(DRb.current_server.uri).host }
      end

      # @private
      def self.trap_interrupt
        trap('INT') { handle_interrupt }
      end

      # @private
      def self.handle_interrupt
        if RSpec.world.wants_to_quit
          exit!(1)
        else
          RSpec.world.wants_to_quit = true

          $stderr.puts(
            "\nRSpec is shutting down and will print the summary report... Interrupt again to force quit " \
            "(warning: at_exit hooks will be skipped if you force quit)."
          )
        end
      end

      # @private
      def exit_code(examples_passed=false)
        return @configuration.error_exit_code || @configuration.failure_exit_code if @world.non_example_failure
        return @configuration.failure_exit_code unless examples_passed

        0
      end

    private

      def persist_example_statuses
        return if @configuration.dry_run
        return unless (path = @configuration.example_status_persistence_file_path)

        ExampleStatusPersister.persist(examples_for_status_persistence, path)
      rescue SystemCallError => e
        RSpec.warning "Could not write example statuses to #{path} (configured as " \
                      "`config.example_status_persistence_file_path`) due to a " \
                      "system error: #{e.inspect}. Please check that the config " \
                      "option is set to an accessible, valid file path", :call_site => nil
      end

      # In a serial run the world's Example objects carry their own
      # execution results. In a parallel run they never execute in this
      # process -- results live in the serialized examples shipped back
      # from the workers. Overlay those so persisted statuses (and thus
      # `--only-failures`) reflect what actually ran instead of recording
      # every example as unknown. Examples with no shipped result (not
      # run: filtered, fail-fast abort, crashed group) fall through to the
      # parent's unexecuted Example and persist as unknown, exactly like
      # a serial run that never reached them.
      def examples_for_status_persistence
        results = @parallel_example_results
        return @world.all_examples unless results

        @world.all_examples.map { |example| results[example.id] || example }
      end
    end
  end
end
