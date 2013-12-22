#!ruby
$LOAD_PATH.unshift(File.expand_path("../lib", File.dirname(__FILE__)))
require "tmpdir"
require "rbconfig"
require "mswin-build/builder"

# use this running ruby as BASERUBY
baseruby = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"] + RbConfig::CONFIG["EXEEXT"])

raise "Usage: ruby kicker.rb <target> [<target> ...]" if ARGV.empty?
loop do
  ARGV.each do |target|
    builder = MswinBuild::Builder.new(target: target, baseruby: baseruby, settings: File.expand_path("../config/#{target}.yaml", File.dirname(__FILE__)))
    if builder.get_last_revision != builder.get_current_revision
      system(baseruby, File.expand_path("build.rb", File.dirname(__FILE__)), "-v", target)
    end
  end
  sleep 60
end
