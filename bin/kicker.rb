#!ruby
$LOAD_PATH.unshift(File.expand_path("../lib", File.dirname(__FILE__)))
require "tmpdir"
require "optparse"
require "rbconfig"
require "mswin-build/builder"

# use this running ruby as BASERUBY by default
baseruby = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"] + RbConfig::CONFIG["EXEEXT"])
interval = 60
force_build = 24 * 60 * 60  # force build at least once in every day
cmd_dir = ENV['TEMP']

opt = OptionParser.new
opt.banner = "Usage: ruby #$0 [options] <target name>"
opt.separator ""
opt.separator "  This script automatically loads config/<target name>.yaml."
opt.separator ""
opt.separator "Options:"
opt.on('-v', '--verbose', "Be verbose. default = #{!$debug.nil? && $debug}") { $debug = true }
opt.on('-b <baseruby>', '--baseruby=<baserbuby>', "specify baseruby. default: #{baseruby}") { |v| baseruby = v }
opt.on('-i <seconds>', '--interval=<seconds>', "interval between each build. default: #{interval}") { |v| interval = Integer(v) }
opt.on('-f <seconds>', '--force-build=<seconds>', "force build after specified seconds from last bulid. default: #{force_build}") { |v| force_build = Integer(v) }
opt.on('-t <directory>', '--command-dir=<directory>', "specify force-build command directory. default: ENV['TEMP'] (#{ENV['TEMP']})") { |v| cmd_dir = v }

begin
  opt.parse!(ARGV)
  raise "target name is not specified." if ARGV.empty?
rescue RuntimeError => ex
  puts ex.message
  puts
  puts opt.help
  exit 1
end
STDOUT.sync = true if $debug

loop do
  ARGV.each do |target|
    builder = MswinBuild::Builder.new(target: target, baseruby: baseruby, settings: File.expand_path("../config/#{target}.yaml", File.dirname(__FILE__)))
    if File.exist?(File.join(cmd_dir, target))
      force = true
      File.unlink(File.join(cmd_dir, target)) rescue nil
    else
      force = false
    end
    if force || !builder.get_last_build_time || builder.get_last_build_time + force_build < Time.now || builder.get_last_revision != builder.get_current_revision
      cmd = [baseruby, File.expand_path("build.rb", File.dirname(__FILE__)), target]
      cmd << "-v" if $debug
      puts "+++ #{Time.now}  Start #{target} +++" if $debug
      system(*cmd)
      puts "--- #{Time.now}  Finish #{target} ---" if $debug
    else
      puts "=== #{Time.now}  Skipped #{target} ===" if $debug
    end
  end
  puts "=== #{Time.now}  Pausing #{interval} seconds ===" if $debug
  sleep interval
end
