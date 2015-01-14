require "fileutils"
require "tmpdir"
require "tempfile"
require "test/unit"
require "mswin-build/builder.rb"

module ProcessMock
  @callback = nil

  def self.spawn(*args)
    @status = @callback.call(args, @param)
    @status.pid
  end

  def self.waitpid2(pid, flags = 0)
    [pid, @status]
  end

  def self.set_callback(param = nil, &blk)
    @param = param
    @callback = blk
  end
end

class StatusMock
  attr_accessor :to_i, :pid
  alias to_int to_i

  def initialize(retval, pid = rand(65536))
    @to_i = retval
    @pid = pid
  end

  def success?
    @to_i.zero?
  end
end

class TestBuilder < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir('TestBuilder')
    @yaml = Tempfile.open('TestBuilder', @tmpdir)
    @yaml.puts <<-EOY
baseruby: ruby
repository: dummy_repository
logdir: #{@tmpdir}
tmpdir: #{@tmpdir}
env:
  DUMMY: foo
    EOY
    @yaml.open # rewind for reading
  end

  def teardown
    @yaml.close!
    FileUtils.rm_r(@tmpdir)
  end

  def run_builder(hash = {}, &blk)
    builder = MswinBuild::Builder.new(target: "dummy", settings: @yaml.path)
    if !hash.empty?
      config = builder.instance_variable_get(:@config)
      config["timeout"]["test-all"] = hash[:timeout] if hash[:timeout]
      builder.instance_variable_set(:@config, config)
    end
    begin
      origProcess = Process
      Object.class_eval do
        remove_const :Process
        const_set :Process, ProcessMock
      end

      commands = [
        /^bison --version\s*$/,
        /^svn checkout dummy_repository ruby\s*$/,
        /^svn info\s*$/,
        /^win32\/configure\.bat --prefix=[^ ]+ --with-baseruby=ruby\s*$/,
        /^cl\s*$/,
        /^nmake -l miniruby\s*$/,
        /^\.\/miniruby -v\s*$/,
        /^nmake -l "OPTS=-v -q" btest\s*$/,
        /^\.\/miniruby sample\/test\.rb\b/,
        /^nmake -l showflags\s*$/,
        /^nmake -l main\s*$/,
        /^nmake -l docs\s*$/,
        /^\.\/ruby -v\s*$/,
        /^nmake -l install-nodoc\s*$/,
        /^nmake -l install-doc\s*$/,
        /^nmake -l "OPTS=-v -q" test-knownbug\s*$/,
        /^nmake -l TESTS=-v RUBYOPT=-w test-all\s*$/,
      ]

      ProcessMock.set_callback(commands, &blk)

      builder.run

      assert_empty commands
      assert_equal hash[:revision].to_s, builder.get_last_revision if hash[:revision]
    ensure
      Object.class_eval do
        remove_const :Process
        const_set :Process, origProcess
      end
    end

    assert File.exist?(File.join(@tmpdir, "recent.html"))
    assert File.exist?(File.join(@tmpdir, "summary.html"))
    assert File.directory?(File.join(@tmpdir, "log"))
    files = Dir.glob(File.join(@tmpdir, "log", "*"))
    assert files.reject! {|e| /\.log\.html\.gz\z/ =~ e}
    assert files.reject! {|e| /\.diff\.html\.gz\z/ =~ e}
    assert_empty files
  end

  def test_run_success
    assert_raise(ArgumentError) do
      MswinBuild::Builder.new
    end

    assert_raise(RuntimeError) do
      MswinBuild::Builder.new(target: "dummy")
    end

    assert_raise(RuntimeError) do
      MswinBuild::Builder.new(settings: @yaml.path)
    end

    assert_raise(RuntimeError) do
      MswinBuild::Builder.new(target: "dummy", settings: @yaml.path, foo: nil)
    end

    run_builder(revision: 12345) do |args, commands|
      assert_not_empty commands, "for ``#{args[0]}''"
      assert_match commands.shift, args[0]

      case args[0]
      when /^svn checkout\b/
        Dir.mkdir("ruby")
      when /^svn info\b/
        if args[1].is_a?(Hash) && args[1][:out]
          args[1][:out].puts "Revision: 54321"
          args[1][:out].puts "Last Changed Rev: 12345"
        end
      end

      StatusMock.new(0)
    end

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /\bsuccess\b/, recent
    assert_match /^<a href="[^"]+" name="[^"]+">[^<]+<\/a> r12345 /, recent
  end

  def test_run_btest_failure
    run_builder do |args, commands|
      commands.shift

      status = 0
      case args[0]
      when /^svn checkout\b/
        Dir.mkdir("ruby")
      when /\bbtest\b/
        if args[1].is_a?(Hash) && args[1][:out]
          args[1][:out].puts "FAIL 3/456"
        end
        status = 3
      end

      StatusMock.new(status)
    end

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /\b3BFail\b/, recent
    assert_not_match /\bfailed\b/, recent
  end

  def test_run_testrb_failure
    run_builder do |args, commands|
      commands.shift

      status = 0
      case args[0]
      when /^svn checkout\b/
        Dir.mkdir("ruby")
      when /\btest\.rb\b/
        if args[1].is_a?(Hash) && args[1][:out]
          args[1][:out].puts "not ok/test: 123 failed 4"
        end
        status = 3
      end

      StatusMock.new(status)
    end

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /\b4NotOK\b/, recent
    assert_not_match /\bfailed\b/, recent
  end

  def test_run_test_all_failure
    run_builder do |args, commands|
      commands.shift

      status = 0
      case args[0]
      when /^svn checkout\b/
        Dir.mkdir("ruby")
      when /\btest-all\b/
        if args[1].is_a?(Hash) && args[1][:out]
          args[1][:out].puts "123 tests, 4567 assertions, 2 failures, 1 errors, 4 skips"
        end
        status = 3
      end

      StatusMock.new(status)
    end

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /\b2F1E\b/, recent
    assert_not_match /\bfailed\b/, recent
  end

  def test_run_timeout
    run_builder(timeout: 0.1) do |args, commands|
      commands.shift

      case args[0]
      when /^svn checkout\b/
        Dir.mkdir("ruby")
      when /\btest-all\b/
        StatusMock.new(nil)
        sleep 2
        break
      end

      StatusMock.new(0)
    end

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /\bfailed\(test-all CommandTimeout\)/, recent
  end

  def test_get_current_revision
    TOPLEVEL_BINDING.eval <<-EOS
      alias orig_backquote ` #`
      def `(cmd) #`
        "Revision: 54321\nLast Changed Rev: 12345\n"
      end
    EOS

    begin
      builder = MswinBuild::Builder.new(target: "dummy", settings: @yaml.path)
      assert_equal "12345", builder.get_current_revision
    ensure
      TOPLEVEL_BINDING.eval <<-EOS
        alias ` orig_backquote #`
      EOS
    end
  end
end
