require 'spin/version'
require 'spin/hooks'
require 'socket'
require 'tempfile' # Dir.tmpdir
# This lets us hash the parameters we want to include in the filename
# without having to worry about subdirectories, special chars, etc.
require 'digest/md5'
# So we can tell users how much time they're saving by preloading their
# environment.
require 'benchmark'
require 'pathname'

module Spin
  extend Spin::Hooks

  PUSH_FILE_SEPARATOR = '|'

  class << self
    def serve(options)
      ENV['RAILS_ENV'] = 'test' unless ENV['RAILS_ENV']

      if root_path = rails_root(options[:preload])
        Dir.chdir(root_path)
        Spin.parse_hook_file(root_path)
      else
        warn "Could not find #{options[:preload]}. Are you running this from the root of a Rails project?"
      end

      open_socket do |socket|
        preload(options) if root_path

        puts "Pushing test results back to push processes" if options[:push_results]

        loop do
          run_pushed_tests(socket, options)
        end
      end
    end

    def push(argv, options)
      files_to_load = convert_push_arguments_to_files(argv)

      if root_path = rails_root(options[:preload])
        make_files_relative(files_to_load, root_path)
        Dir.chdir root_path
      end

      files_to_load << "tty?" if $stdout.tty?

      abort if files_to_load.empty?

      puts "Spinning up #{files_to_load.join(" ")}"
      send_files_to_serve(files_to_load)
    end

    private

    def send_files_to_serve(files_to_load)
      # This is the other end of the socket that `spin serve` opens. At this point
      # `spin serve` will accept(2) our connection.
      socket = UNIXSocket.open(socket_file)

      # We put the filenames on the socket for the server to read and then load.
      socket.puts files_to_load.join(PUSH_FILE_SEPARATOR)

      while line = socket.readpartial(100)
        break if line[-1,1] == "\0"
        print line
      end
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      abort "Connection was refused. Have you started up `spin serve` yet?"
    end

    # The filenames that we will spin up to `spin serve` are passed in as
    # arguments.
    def convert_push_arguments_to_files(argv)
      files_to_load = argv

      # We reject anything in ARGV that isn't a file that exists. This takes
      # care of scripts that specify files like `spin push -r file.rb`. The `-r`
      # bit will just be ignored.
      #
      # We build a string like `file1.rb|file2.rb` and pass it up to the server.
      files_to_load = files_to_load.map do |file|
        args = file.split(':')

        file_name = args.first.to_s
        line_number = args.last.to_i

        # If the file exists then we can push it up just like it is
        file_name = if File.exist?(file_name)
          file_name
          # kicker-2.5.0 now gives us file names without extensions, so we have to try adding it
        elsif File.extname(file_name).empty?
          full_file_name = [file_name, 'rb'].join('.')
          full_file_name if File.exist?(full_file_name)
        end

        if line_number > 0
          abort "You specified a line number. Only one file can be pushed in this case." if files_to_load.length > 1

          "#{file_name}:#{line_number}"
        else
          file_name
        end
      end.reject(&:empty?).uniq
    end

    def make_files_relative(files_to_load, root_path)
      files_to_load.map! do |file|
        Pathname.new(file).expand_path.relative_path_from(root_path).to_s
      end
    end

    def run_pushed_tests(socket, options)
      rerun_last_tests_on_quit(options) unless options[:push_results]

      # Since `spin push` reconnects each time it has new files for us we just
      # need to accept(2) connections from it.
      conn = socket.accept
      # This should be a list of relative paths to files.
      files = conn.gets.chomp
      files = files.split(PUSH_FILE_SEPARATOR)

      # If spin is started with the time flag we will track total execution so
      # you can easily compare it with time rspec spec for example
      start = Time.now if options[:time]

      # If we're not sending results back to the push process, we can disconnect
      # it immediately.
      disconnect(conn) unless options[:push_results]

      fork_and_run(files, conn, options)

      # WAIT: We don't want the parent process handling multiple test runs at the same
      # time because then we'd need to deal with multiple test databases, and
      # that destroys the idea of being simple to use. So we wait(2) until the
      # child process has finished running the test.
      Process.wait

      # If we are tracking time we will output it here after everything has
      # finished running
      puts "Total execution time was #{Time.now - start} seconds" if start

      # Tests have now run. If we were pushing results to a push process, we can
      # now disconnect it.
      begin
        disconnect(conn) if options[:push_results]
      rescue Errno::EPIPE
        # Don't abort if the client already disconnected
      end
    end

    # Trap SIGQUIT (Ctrl+\) and re-run the last files that were pushed
    # TODO test this
    def rerun_last_tests_on_quit(options)
      trap('QUIT') do
        fork_and_run(@last_files_ran, nil, options)
        Process.wait
      end
    end

    def preload(options)
      duration = Benchmark.realtime do
        # We require config/application because that file (typically) loads Rails
        # and any Bundler deps, as well as loading the initialization code for
        # the app, but it doesn't actually perform the initialization. That happens
        # in config/environment.
        #
        # In my experience that's the best we can do in terms of preloading. Rails
        # and the gem dependencies rarely change and so don't need to be reloaded.
        # But you can't initialize the application because any non-trivial app will
        # involve it's models/controllers, etc. in its initialization, which you
        # definitely don't want to preload.
        execute_hook(:before_preload)
        require File.expand_path options[:preload].sub('.rb', '')
        execute_hook(:after_preload)

        # Determine the test framework to use using the passed-in 'force' options
        # or else default to checking for defined constants.
        options[:test_framework] ||= determine_test_framework

        # Preload RSpec to save some time on each test run
        if options[:test_framework]
          begin
            require 'rspec/autorun'

            # Tell RSpec it's running with a tty to allow colored output
            if RSpec.respond_to?(:configure)
              RSpec.configure do |c|
                c.tty = true if c.respond_to?(:tty=)
              end
            end
          rescue LoadError
          end
        end
      end
      # This is the amount of time that you'll save on each subsequent test run.
      puts "Preloaded Rails env in #{duration}s..."
    end

    # This socket is how we communicate with `spin push`.
    # We delete the tmp file for the Unix socket if it already exists. The file
    # is scoped to the `pwd`, so if it already exists then it must be from an
    # old run of `spin serve` and can be cleaned up.
    def open_socket
      file = socket_file
      File.delete(file) if File.exist?(file)
      socket = UNIXServer.open(file)

      # Trap SIGINT (Ctrl-C) so that we exit cleanly.
      trap('SIGINT') do
        socket.close
        exit
      end

      yield socket
    ensure
      File.delete(file) if file && File.exist?(file)
    end

    def determine_test_framework
      if defined?(RSpec)
        :rspec
      else
        :testunit
      end
    end

    def disconnect(connection)
      connection.print "\0"
      connection.close
    end

    def rails_root(preload)
      path = Pathname.pwd
      until path.join(preload).file?
        return if path.root?
        path = path.parent
      end
      path
    end

    def fork_and_run(files, conn, options)
      execute_hook(:before_fork)
      # We fork(2) before loading the file so that our pristine preloaded
      # environment is untouched. The child process will load whatever code it
      # needs to, then it exits and we're back to the baseline preloaded app.
      fork do
        # To push the test results to the push process instead of having them
        # displayed by the server, we reopen $stdout/$stderr to the open
        # connection.
        tty = files.delete "tty?"
        if options[:push_results]
          $stdout.reopen(conn)
          if tty
            def $stdout.tty?
              true
            end
          end
          $stderr.reopen(conn)
        end

        execute_hook(:after_fork)

        puts
        puts "Loading #{files.inspect}"

        # Unfortunately rspec's interface isn't as simple as just requiring the
        # test file that you want to run (suddenly test/unit seems like the less
        # crazy one!).
        if options[:test_framework] == :rspec
          # We pretend the filepath came in as an argument and duplicate the
          # behaviour of the `rspec` binary.
          ARGV.push files
        else
          # We require the full path of the file here in the child process.
          files.each { |f| require File.expand_path f }
        end
      end
      @last_files_ran = files
    end

    def socket_file
      key = Digest::MD5.hexdigest [Dir.pwd, 'spin-gem'].join
      [Dir.tmpdir, key].join('/')
    end
  end
end
