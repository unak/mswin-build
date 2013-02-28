#! ruby
# expected ruby 1.9.x or later.

$LOAD_PATH.unshift(File.join(File.dirname(File.dirname(__FILE__))), "lib")
require "rbconfig"
require "mswin-build/builder"

target = ARGV.shift
unless target
  puts "Usage: ruby #$0 <target name>"
  puts
  puts " ex: ruby #$0 vc10-x86-trunk"
  puts "     ruby #$0 vc11-x64-1.9.3"
  puts
  puts " This script automatically loads config/<target-name>.yaml"
  exit 1
end

# use this running ruby as BASERUBY
baseruby = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"] + RbConfig::CONFIG["EXEEXT"])

builder = MswinBuild::Builder.new(target: target, baseruby: baseruby, settings: File.join(File.dirname(File.dirname(__FILE__)), "config/#{target}.yaml"))
exit builder.run
