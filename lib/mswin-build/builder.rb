require "cgi"
require "fileutils"
require "socket"
require "time"
require "timeout"
require "tmpdir"
require "yaml"
require "mswin-build/process_tree"
require "mswin-build/upload"

module MswinBuild
  class Builder
    def initialize(h)
      @target = h.delete(:target) || raise("target not specified")
      baseruby = h.delete(:baseruby)
      yaml = h.delete(:settings) || raise("settings not specified")
      azure_key = h.delete(:azure_key)
      unless h.empty?
        raise "unknown option(s): #{h}"
      end
      @config = YAML.load(IO.read(yaml, encoding: "utf-8"))
      @config["baseruby"] = baseruby if baseruby
      @config["bison"] ||= "bison"
      @config["svn"] ||= "svn"
      @config["gzip"] ||= "gzip"

      raise "baseruby not specified" unless @config["baseruby"]
      raise "repository not specified" unless @config["repository"]
      raise "logdir not specfied" unless @config["logdir"]

      @config["azure_key"] = azure_key if azure_key
      if@config["azure_key"]
        ENV['AZURE_STORAGE_ACCESS_KEY'] = @config["azure_key"]
        MswinBuild.register_azure_upload(@config["logdir"])
      end

      @data = {}
      @title = []
      @links = {}

      @diff = nil

      @config["timeout"] ||= {}
      @config["timeout"]["default"] ||= 10 * 60      # default 10 min
      @config["timeout"]["default_short"] ||= 60     # default 1 min
      @config["timeout"]["default_long"] ||= 30 * 60 # default 30 min
      @config["timeout"]["start"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["bison-version"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["svn/ruby"] ||= @config["timeout"]["default"]
      @config["timeout"]["svn/info"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["configure"] ||= @config["timeout"]["default"]
      @config["timeout"]["cc-version"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["miniruby"] ||= @config["timeout"]["default"]
      @config["timeout"]["miniversion"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["btest"] ||= @config["timeout"]["default"]
      @config["timeout"]["test.rb"] ||= @config["timeout"]["default"]
      @config["timeout"]["showflags"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["main"] ||= @config["timeout"]["default_long"]
      @config["timeout"]["docs"] ||= @config["timeout"]["default"]
      @config["timeout"]["version"] ||= @config["timeout"]["default_short"]
      @config["timeout"]["install-nodoc"] ||= @config["timeout"]["default"]
      @config["timeout"]["install-doc"] ||= @config["timeout"]["default"]
      @config["timeout"]["test-knownbug"] ||= @config["timeout"]["default"]
      @config["timeout"]["test-all"] ||= @config["timeout"]["default_long"]

      @last_status = nil
    end

    def run
      begin
        orig_path = insert_path("PATH", @config["path_add"])
        orig_include = insert_path("INCLUDE", @config["include_add"])
        orig_lib = insert_path("LIB", @config["lib_add"])
        if @config["tmpdir"]
          @config["env"] ||= {}
          @config["env"]["TMP"] ||= @config["tmpdir"].gsub(%r(/), '\\')
          @config["env"]["TEMP"] ||= @config["tmpdir"].gsub(%r(/), '\\')
        end
        orig_env = {}
        (@config["env"] || {}).each do |name, value|
          orig_env[name] = ENV[name]
          ENV[name] = value
        end
        files = []
        Dir.mktmpdir("mswin-build", @config["tmpdir"]) do |tmpdir|
          files << baseinfo(tmpdir)
          files << checkout(tmpdir)
          if @last_status && @last_status.success?
            files << configure(tmpdir)
            files << update_unicode(tmpdir)
            files << update_gems(tmpdir)
            files << extract_extlibs(tmpdir)
            files << cc_version(tmpdir)
            files << miniruby(tmpdir)
            files << miniversion(tmpdir)
            files << btest(tmpdir)
            files << testrb(tmpdir)
            #files << method_list(tmpdir)
            files << showflags(tmpdir)
            files << main(tmpdir)
            files << docs(tmpdir)
            files << version(tmpdir)
            files << install_nodoc(tmpdir)
            files << install_doc(tmpdir)
            #files << version_list(tmpdir)
            files << test_knownbug(tmpdir)
            files << test_all(tmpdir)
            files << rubyspec(tmpdir)
          end
          files << end_(tmpdir)
          logfile = gather_log(files, tmpdir)
          difffile = diff(tmpdir, logfile)
          logfile = gzip(logfile)
          @data[:compressed_loghtml_relpath] = File.join("log", File.basename(logfile))
          difffile = gzip(difffile)
          @data[:compressed_diffhtml_relpath] = File.join("log", File.basename(difffile))
          add_recent(logfile)
          add_summary(logfile)

          MswinBuild.run_upload_hooks
        end
        true
      rescue
        STDERR.puts $!
        STDERR.puts $!.backtrace
        false
      ensure
        orig_env.each_pair do |name, value|
          if value
            ENV[name] = value
          else
            ENV.delete(name)
          end
        end
        ENV["LIB"] = orig_lib if orig_lib
        ENV["INCLUDE"] = orig_include if orig_include
        ENV["PATH"] = orig_path if orig_path
      end
    end

    def get_current_revision
      orig_lang = ENV["LANG"]
      ENV["LANG"] = "C"
      begin
        if /^(?:SVN )?Last Changed Rev: (\d+)$/ =~ `#{@config['svn']} info #{@config['repository']} 2> NUL`
          $1
        else
          nil
        end
      rescue
        nil
      ensure
        ENV["LANG"] = orig_lang
      end
    end

    def get_last_revision
      recent = File.join(@config["logdir"], "recent.html")
      return nil unless File.exist?(recent)
      file = nil
      open(recent, "r") do |f|
        f.read.scan(/^<a href="(.+?)".*?<br>$/) do |line|
          file = $1
          break
        end
      end
      return nil unless file

      cmd = "#{@config['gzip']} -d -c #{File.join(@config['logdir'], file)}"
      `#{cmd}`.scan(/^(?:SVN )?Last Changed Rev: (\d+)$/) do |line|
        return $1
      end
      nil
    end

    def get_last_build_time
      recent = File.join(@config["logdir"], "recent.html")
      return nil unless File.exist?(recent)
      open(recent, "r") do |f|
        f.read.scan(/^<a href="(.+?)".*?<br>$/) do |line|
          return Time.parse(File.basename($1, ".log.html"))
        end
      end
      return nil
    end

    private
    def u(str)
      CGI.escape(str)
    end

    def h(str)
      CGI.escapeHTML(str)
    end

    def insert_path(env, add)
      return nil unless add
      orig = ENV[env]
      if orig
        add += ";" unless add[-1] == ?;
        ENV[env] = add + orig
      else
        ENV[env] = add
      end
      orig
    end

    def spawn_with_timeout(name, command, io)
      pid = nil
      begin
        ret = nil
        Timeout.timeout(@config["timeout"][name] || @config["timeout"]["default"]) do
          begin
            pid = Process.spawn(command, out: io, err: io)
            _, ret = Process.waitpid2(pid)
          rescue
            ret = nil
          end
        end
        ret
      rescue Timeout::Error => ex
        MswinBuild::ProcessTree.terminate_process_tree(pid) if pid
        raise ex
      end
    end

    def do_command(io, name, command, in_builddir = false, check_retval = true, lang = "C", &blk)
      heading(io, name)
      status = nil
      if lang
        orig_lang = ENV["LANG"]
        ENV["LANG"] = lang
      end
      begin
        if $DEBUG
          puts "+ #{command}"
          $stdout.flush
        end
        io.puts "+ #{command}"
        io.flush
        if in_builddir
          if File.exist?(@builddir)
            Dir.chdir(@builddir) do
              status = spawn_with_timeout(name, command, io)
              blk.call(status) if blk
            end
          else
            status = nil
          end
        else
          status = spawn_with_timeout(name, command, io)
          blk.call(status) if blk
        end

        if status.nil? || !status.success?
          io.puts "exit #{status.to_i}" unless status.nil?
          io.puts "failed(#{name})"
          @title << "failed(#{name})" if check_retval || status.nil?
          @data[:result] = "failure"
          @links[name] << "failed"
          if $DEBUG
            puts %'failed(#{name}) #{status.nil? ? "because maybe command not found" : "with status #{status.to_i}"}'
            $stdout.flush
          end
        end
      rescue Timeout::Error
        io.puts
        io.printf "|output interval exceeds %.1f seconds. (CommandTimeout)", @config["timeout"][name] || @config["timeout"]["default"]
        io.puts $!.backtrace.join("\n| ")
        io.puts "failed(#{name} CommandTimeout)"
        @title << "failed(#{name} CommandTimeout)"
        @data[:result] = "failure"
        @links[name] << "failed"
        if $DEBUG
          puts "failed(#{name} CommandTimeout)"
          $stdout.flush
        end
      ensure
        ENV["LANG"] = orig_lang if lang
      end
      @last_status = status
      status.nil? ? nil : status.success?
    end

    def heading(io, name)
      if $DEBUG
        puts "== #{name}"
        $stdout.flush
      end
      anchor = u name.to_s.tr('_', '-')
      text = h name.to_s.tr('_', '-')
      io.puts %'<a name="#{anchor}">== #{text}</a> \# #{h Time.now.iso8601}'
      @links[name] = [anchor, text]
    end

    def self.define_buildmethod(method, &blk)
      define_method("bare_#{method.to_s}", blk)
      define_method(method) do |tmpdir|
        io = open(File.join(tmpdir, method.to_s), "w+")
        begin
          __send__("bare_#{method.to_s}", io, tmpdir)
        ensure
          io.close
        end
        io
      end
    end

    define_buildmethod(:baseinfo) do |io, tmpdir|
      @start_time = Time.now
      @data[:start_time] = @start_time.dup.utc.strftime('%Y%m%dT%H%M%SZ')
      # target
      heading(io, @target)
      host = Socket.gethostname.split(/\./).first
      @title << "(#{host})"
      @data[:host] = host
      io.puts "Nickname: #{host}"
      io.puts "#{`ver`.gsub(/\r?\n/, '')} #{ENV['OS']} #{ENV['ProgramW6432'] ? 'x64' : 'i386'}"

      # start
      heading(io, "start")

      # cpu-info
      #heading(io, "cpu-info")

      # bison-version
      do_command(io, "bison-version", "#{@config['bison']} --version")
    end

    define_buildmethod(:checkout) do |io, tmpdir|
      # svn/ruby
      Dir.chdir(tmpdir) do
        do_command(io, "svn/ruby", "#{@config['svn']} checkout #{@config['repository']} ruby")
      end

      # svn-info/ruby
      @builddir = File.join(tmpdir, "ruby")
      do_command(io, "svn-info/ruby", "#{@config['svn']} info", true) do |s|
        if /^URL: (.*)$/ =~ `#{@config['svn']} info 2> NUL`
          @data[:svn_url] = $1
        end
      end
    end

    define_buildmethod(:configure) do |io, tmpdir|
      options = " --with-baseruby=#{@config['baseruby'].gsub(%r(/), '\\')}" if ruby_version >= "1.9.0"
      options << " #{@config['configure_args']}"
      do_command(io, "configure", "win32/configure.bat --prefix=#{destdir(tmpdir)}#{options}", true)
    end

    define_buildmethod(:update_unicode) do |io, tmpdir|
      begin
        open(File.join(@builddir, 'common.mk')) do |f|
          if /^update-unicode:/ =~ f.read
            do_command(io, "update-unicode", "nmake -l update-unicode", true)
          end
        end
      rescue Errno::ENOENT
      end
    end

    define_buildmethod(:update_gems) do |io, tmpdir|
      begin
        open(File.join(@builddir, 'common.mk')) do |f|
          if /^update-gems:/ =~ f.read
            do_command(io, "update-gems", "nmake -l update-gems", true)
          end
        end
      rescue Errno::ENOENT
      end
    end

    define_buildmethod(:extract_extlibs) do |io, tmpdir|
      begin
        open(File.join(@builddir, 'common.mk')) do |f|
          if /^extract-extlibs:/ =~ f.read
            do_command(io, "extract-extlibs", "nmake -l extract-extlibs", true)
          end
        end
      rescue Errno::ENOENT
      end
    end

    define_buildmethod(:cc_version) do |io, tmpdir|
      do_command(io, "cc-version", "cl")
    end

    define_buildmethod(:miniruby) do |io, tmpdir|
      do_command(io, "miniruby", "nmake -l miniruby", true)
    end

    define_buildmethod(:miniversion) do |io, tmpdir|
      do_command(io, "miniversion", "./miniruby -v", true)
    end

    define_buildmethod(:btest) do |io, tmpdir|
      ret = do_command(io, "btest", 'nmake -l "OPTS=-v -q" btest', true, false)
      if !ret && !ret.nil?
        io.rewind
        if %r'^FAIL (\d+)/\d+' =~ io.read
          @title << "#{$1}BFail"
        else
          @title << "failed(btest)"
        end
        @data[:result] = "failure"
      end
    end

    define_buildmethod(:testrb) do |io, tmpdir|
      ret = do_command(io, "test.rb", "./miniruby sample/test.rb", true, false)
      if !ret && !ret.nil?
        io.rewind
        if %r'^not ok/test: \d+ failed (\d+)' =~ io.read
          @title << "#{$1}NotOK"
        else
          @title << "failed(test.rb)"
        end
        @data[:result] = "failure"
      end
    end

    define_buildmethod(:showflags) do |io, tmpdir|
      begin
        open(File.join(@builddir, 'common.mk')) do |f|
          if /^showflags:/ =~ f.read
            do_command(io, "showflags", "nmake -l showflags", true)
          end
        end
      rescue Errno::ENOENT
      end
    end

    define_buildmethod(:main) do |io, tmpdir|
      do_command(io, "main", "nmake -l main", true)
    end

    define_buildmethod(:docs) do |io, tmpdir|
      do_command(io, "docs", "nmake -l docs", true)
    end

    define_buildmethod(:version) do |io, tmpdir|
      if do_command(io, "version", "./ruby -v", true)
        io.rewind
        @title.unshift(io.read.split(/\r?\n/).last.chomp)
      else
        @title.unshift(@target)
      end
      @data[:version] = @title.first
    end

    define_buildmethod(:install_nodoc) do |io, tmpdir|
      options = " DESTDIR=#{destdir(tmpdir)}" if ruby_version < "1.9.0"
      do_command(io, "install-nodoc", "nmake -l install-nodoc#{options}", true)
    end

    define_buildmethod(:install_doc) do |io, tmpdir|
      options = " DESTDIR=#{destdir(tmpdir)}" if ruby_version < "1.9.0"
      do_command(io, "install-doc", "nmake -l install-doc#{options}", true)
    end

    define_buildmethod(:test_knownbug) do |io, tmpdir|
      do_command(io, "test-knownbug", 'nmake -l "OPTS=-v -q" test-knownbug', true, false)
    end

    define_buildmethod(:test_all) do |io, tmpdir|
      ret = do_command(io, "test-all", "nmake -l TESTS=-v RUBYOPT=-w test-all", true, false, nil)
      if !ret && !ret.nil?
        io.rewind
        if %r'^\d+ tests, \d+ assertions, (\d+) failures, (\d+) errors, (\d+) skips' =~ io.read
          @title << "#{$1}F#{$2}E"
          @data[:result] = "failure" if $1.to_i + $2.to_i > 0
        else
          @title << "failed(test-all)"
          @data[:result] = "failure"
        end
      end
    end

    define_buildmethod(:rubyspec) do |io, tmpdir|
      heading(io, "rubyspec")
      io.puts "skipped."
      @links["rubyspec"] << "skipped"
    end

    define_buildmethod(:end_) do |io, tmpdir|
      unless /failed|BFail|NotOK|\d+F\d+E/ =~ @title.join
        heading(io, "success")
        @title << "success"
        @data[:result] = "success"
      end

      heading(io, "end")
      diff = Time.now - @start_time
      io.printf "elapsed %.1fs = %dm %04.1fs\n", diff, diff / 60, diff % 60
    end

    def destdir(tmpdir)
      File.join(tmpdir, 'install')
    end

    def ruby_version
      if /_(\d)_(\d)(?:_(\d+))?$/ =~ @config["repository"]
        return "#{$1}.#{$2}.#{$3 || 9}"
      else
        return "9.9.9"  # means unknown (maybe trunk)
      end
    end

    def header(io)
      title = @title.join(' ')
      io.puts <<-EOH
<html>
  <head>
    <title>#{h title}</title>
    <meta name="author" content="mswin-build">
    <meta name="generator" content="mswin-build">
  </head>
  <body>
  <h1>#{h title}</h1>
    <p>
      <a href="../../">mswin-build</a>
      <a href="../summary.html">summary</a>
      <a href="../recent.html">recent</a>
    </p>
      EOH
    end

    def footer(io)
      io.puts <<-EOH
    <hr>
    <p>
      <a href="../../">mswin-build</a>
      <a href="../summary.html">summary</a>
      <a href="../recent.html">recent</a>
    </p>
  </body>
</html>
      EOH
    end

    def gather_log(files, tmpdir)
      logdir = File.join(@config["logdir"], "log")
      FileUtils.mkdir_p(logdir)
      logfile = File.join(logdir, @data[:start_time] + '.log.html')
      warns = 0
      revision = nil
      open(File.join(tmpdir, "gathered"), "w") do |out|
        files.each_with_index do |io, i|
          next unless io
          io.reopen(io.path, "r")
          begin
            io.each_line do |line|
              line = h(line) unless /^<a / =~ line
              out.write line
              warns += line.scan(/warn/i).length
              if File.basename(io.path) == "checkout" && /^(?:SVN )?Last Changed Rev: (\d+)$/ =~ line
                revision = $1
              end
            end
          ensure
            io.close
            File.unlink(io.path) rescue nil
          end
        end
      end
      @title.insert(2, "#{warns}W") if warns > 0
      @data[:warn] = "#{warns}W"
      url = @data.delete(:svn_url)
      if revision
        @title.unshift("r#{revision}")
        @data[:ruby_rev] = "r#{revision}"
        @data[:version] = @data[:ruby_rev] + @data[:version]
        @data[url] = revision
      end
      open(logfile, "w") do |out|
        header(out)
        out.puts "    <ul>"
        @links.each_value do |anchor, text, result = nil|
          out.puts %'      <li><a href="\##{anchor}">#{text}</a>#{" #{result}" if result}</li>'
        end
        out.puts "    </ul>"
        out.puts "    <pre>"
        out.write IO.read(File.join(tmpdir, "gathered"))
        out.puts "    </pre>"
        footer(out)
      end
      logfile
    end

    def diff(tmpdir, logfile)
      filename = logfile.sub(/\.log/, ".diff")
      open(filename, "w") do |out|
        header(out)
        out.puts %'<p>Skipped. See the <a href="#{u File.basename(logfile)}.gz">full build log</a>.</p>'
        footer(out)
      end
      filename
    end

    def gzip(file)
      system("#{@config['gzip']} #{file}")
      file + ".gz"
    end

    def add_recent(logfile)
      add_recent_summary(logfile, :recent)
    end

    def add_summary(logfile)
      add_recent_summary(logfile, :summary)
    end

    def add_recent_summary(logfile, mode)
      if mode == :recent
        filename = File.join(@config["logdir"], "recent.html")
      else
        filename = File.join(@config["logdir"], "summary.html")
      end
      old = []
      if File.exist?(filename)
        open(filename, "r") do |f|
          f.read.scan(/^(<a .*?<br>)$/) do |line| #"
            old << line
          end
        end
      end

      title = @title.join(' ')
      @data[:title] = title
      time = @data[:start_time]
      latest = %'<a href="log/#{u time}.log.html.gz" name="#{u time}">#{h time}</a> #{h title} (<a href="log/#{u time}.diff.html.gz">#{@diff ? h(@diff) : "no diff"}</a>)<br>'
      if mode == :recent
        old = old[0..99]
        old.unshift(latest)
      else
        old.push(latest)
      end
      open(filename, "w") do |f|
        f.print <<-EOH
<html>
  <head>
    <title>#{h File.basename(@config['logdir'])} #{h mode.to_s} build summary (#{h @target})</title>
    <meta name="author" content="mswin-build">
    <meta name="generator" content="mswin-build">
  </head>
  <body>
    <h1>#{h File.basename(@config['logdir'])} #{h mode.to_s} build summary (#{h @target})</h1>
    <p>
      <a href="../">mswin-build</a>
      <a href="./summary.html">summary</a>
      <a href="./recent.html">recent</a>
    </p>
        EOH

        old.each do |line|
          f.puts line
        end

        f.print <<-EOH
    <hr>
    <p>
      <a href="../">mswin-build</a>
      <a href="./summary.html">summary</a>
      <a href="./recent.html">recent</a>
    </p>
  </body>
</html>
        EOH
      end

      if mode == :recent
        old = []
        filename = File.join(@config["logdir"], "recent.ltsv")
        if File.exist?(filename)
          open(filename, "r") do |f|
            f.each_line do
              old << line.chomp
            end
          end
        end

        latest = @data.map{|k, v|
          k = k.to_s
          k = k.gsub(/:/, '\\x3a')
          v = v.gsub(/\t/, ' ')
          k = %'"#{k}"' if /\W/ =~ k
          "#{k}:#{v}"
        }.join("\t")
        old.unshift(latest)

        open(filename, "w") do |f|
          old.take(100).each do |line|
            f.puts line
          end
        end
      end
    end
  end
end
