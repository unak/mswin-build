#!ruby
# expected ruby 1.9.x or later.
libdir = File.expand_path("../lib", File.dirname(__FILE__))
$LOAD_PATH.unshift(libdir) if File.directory?(libdir)
require "optparse"
require "rbconfig"
require "mswin-build/builder"

opt = OptionParser.new
opt.banner = "Usage: ruby #$0 [options] <target name>"
opt.separator ""
opt.separator "  This script automatically loads config/<target name>.yaml."
opt.separator ""
opt.separator "Options:"
opt.on('-v', '--verbose', 'Be verbose.') { $DEBUG = true }
opt.on('-a KEY', '--azure-key=KEY', 'Upload results by KEY') {|v| $azure_key = v }

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

options = {
  target: target,
  baseruby: baseruby,
  settings: File.expand_path("../config/#{target}.yaml",
  File.dirname(__FILE__))
}
options[:azure_key] = $azure_key if $azure_key
builder = MswinBuild::Builder.new(options)
exit builder.run
