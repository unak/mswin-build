require "rake/testtask.rb"

namespace "test" do
  Rake::TestTask.new do |t|
    t.name = "units"
    t.pattern = "test/unit/test_*.rb"
  end
end

desc "Run all tests"
task test: ["test:units"]
