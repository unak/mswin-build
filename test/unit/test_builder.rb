require "fileutils"
require "tmpdir"
require "tempfile"
require "test/unit"
require "mswin-build/builder.rb"

module ProcessMock
  @callback = nil

  def self.spawn(*args)
    @status = @callback.call(args)
    @status.pid
  end

  def self.waitpid2(pid, flags = 0)
    [pid, @status]
  end

  def self.set_callback(&blk)
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

  def test_run
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

    builder = MswinBuild::Builder.new(target: "dummy", settings: @yaml.path)
    begin
      origProcess = Process
      Object.class_eval do
        remove_const :Process
        const_set :Process, ProcessMock
      end

      commands = [
        /^bison --version$/,
        /^svn checkout dummy_repository ruby$/,
        /^svn info$/,
        /^win32\/configure\.bat --prefix=[^ ]+ --with-baseruby=ruby$/,
        /^cl$/,
        /^nmake -l miniruby$/,
        /^\.\/miniruby -v$/,
        /^nmake -l "OPTS=-v -q" btest$/,
        /^\.\/miniruby sample\/test\.rb/,
        /^nmake -l showflags$/,
        /^nmake -l main$/,
        /^nmake -l docs$/,
        /^\.\/ruby -v$/,
        /^nmake -l install-nodoc$/,
        /^nmake -l install-doc$/,
        /^nmake -l "OPTS=-v -q" test-knownbug$/,
        /^nmake -l TESTS=-v RUBYOPT=-w test-all$/,
      ]

      ProcessMock.set_callback do |args|
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

      builder.run

      assert_empty commands
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

    recent = File.read(File.join(@tmpdir, "recent.html"))
    assert_match /^<a href="[^"]+" name="[^"]+">[^<]+<\/a> r12345 /, recent
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
