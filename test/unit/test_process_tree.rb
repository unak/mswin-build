require "test/unit"
require "mswin-build/process_tree"

class TestProcessTree < Test::Unit::TestCase
  def test_s_terminate_process_tree
    pid = Process.spawn(%(ruby -e "system('calc.exe')"))
    sleep 1

    assert_nil Process.waitpid(pid, Process::WNOHANG)
    assert_equal 2, MswinBuild::ProcessTree.terminate_process_tree(pid)
  end
end
