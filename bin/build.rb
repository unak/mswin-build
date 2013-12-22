#! ruby
# expected ruby 1.9.x or later.
$LOAD_PATH.unshift(File.expand_path("../lib", File.dirname(__FILE__)))
require "optparse"
require "rbconfig"
require "mswin-build/builder"

$debug = $DEBUG
opt = OptionParser.new
opt.banner = "Usage: ruby #$0 [options] <target name>"
opt.separator ""
opt.separator "  This script automatically loads config/<target name>.yaml."
opt.separator ""
opt.separator "Options:"
opt.on('-v', '--verbose', 'Be verbose.') { $debug = true }

begin
  opt.parse!(ARGV)
  target = ARGV.shift
  raise "target name is not specified." unless target
rescue RuntimeError => ex
  puts ex.message
  puts
  puts opt.help
  exit 1
end

# use this running ruby as BASERUBY
baseruby = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"] + RbConfig::CONFIG["EXEEXT"])

builder = MswinBuild::Builder.new(target: target, baseruby: baseruby, settings: File.expand_path("../config/#{target}.yaml", File.dirname(__FILE__)))
exit builder.run
