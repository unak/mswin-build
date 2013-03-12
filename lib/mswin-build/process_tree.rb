begin
  require "fiddle/import"
  require "fiddle/types"
rescue LoadError
  # 1.9?
  require "dl/import"
  require "dl/types"

  Fiddle::Importer = DL::Importer
  Fiddle::Win32Types = DL::Win32Types
end

module MswinBuild
  module ProcessTree
    extend Fiddle::Importer

    dlload "kernel32.dll", "ntdll.dll"

    include Fiddle::Win32Types
    if /64/ =~ RUBY_PLATFORM
      typealias "ULONG_PTR", "unsigned long long"
    else
      typealias "ULONG_PTR", "unsigned long"
    end
    typealias "TCHAR", "char"

    # from tlhelp32.h
    TH32CS_SNAPPROCESS = 0x00000002
    PROCESSENTRY32 = struct([
      "DWORD dwSize",
      "DWORD cntUsage",
      "DWORD th32ProcessID",
      "ULONG_PTR th32DefaultHeapID",
      "DWORD th32ModuleID",
      "DWORD cntThreads",
      "DWORD th32ParentProcessID",
      "long pcPriClassBase",
      "DWORD dwFlags",
      "TCHAR szExeFile[260]", # [MAX_PATH]
    ])

    # from kernel32.dll
    extern "BOOL CloseHandle(HANDLE)"
    extern "HANDLE CreateToolhelp32Snapshot(DWORD, DWORD)"
    extern "BOOL Process32First(HANDLE, VOID*)"
    extern "BOOL Process32Next(HANDLE, VOID*)"
    extern "DWORD GetLastError(void)"

    def self.terminate_process_tree(pid, code = 0)
      begin
        terminated = 0
        h = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        unless pid == Process.pid
          Process.kill(:KILL, pid)
          terminated += 1
        end
        pe32 = PROCESSENTRY32.malloc
        pe32.dwSize = PROCESSENTRY32.size
        if Process32First(h, pe32) != 0
          begin
            if pe32.th32ParentProcessID == pid
              terminated += terminate_process_tree(pe32.th32ProcessID, code)
            end
          end while Process32Next(h, pe32) != 0
        else
          raise sprintf("Cannot get processes: %d", GetLastError())
        end
      ensure
        CloseHandle(h) if h
      end

      if pid == Process.pid
        Process.kill(:KILL, pid)
        terminated += 1
      end

      terminated
    end
  end
end
