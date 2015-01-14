require "fileutils"
require "test/unit"
require "tmpdir"
require "mswin-build/upload"

alias mock_orig_require require
def require(feature)
  mock_orig_require(feature) unless feature == "azure"
end

# Azure mock
module Azure
  class BlobService
    def initialize
      @blobs = {}
    end

    def with_filter(&blk)
      blk.call(nil, lambda{})
    end

    def get_blob(container, blobname)
      raise Azure::Core::Http::HTTPError unless @blobs.has_key?(blobname)
      return @blobs[blobname][:data]
    end

    def get_blob_metadata(container, blobname)
      raise Azure::Core::Http::HTTPError unless @blobs.has_key?(blobname)
      return @blobs[blobname]
    end

    def create_block_blob(container, blobname, io, options)
      @blobs[blobname] = options.merge(data: io.read)
    end
  end

  module Core
    module Http
      class HTTPError < RuntimeError
        def type
          ""
        end
      end
    end
  end
end

class TestUpload < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    Dir.mkdir(File.join(@tmpdir, "log"))
  end

  def teardown
    ENV.delete "AZURE_STORAGE_ACCESS_KEY"
    MswinBuild.instance_variable_set(:@upload_hooks, [])

    FileUtils.rm_r @tmpdir if File.directory?(@tmpdir)
  end

  def test_add_upload_hook
    assert_equal 0, MswinBuild.instance_variable_get(:@upload_hooks).size
    MswinBuild.add_upload_hook do
    end
    assert_equal 1, MswinBuild.instance_variable_get(:@upload_hooks).size
  end

  def test_run_upload_hooks
    foo = false
    MswinBuild.add_upload_hook do
      foo = true
    end
    refute foo
    MswinBuild.run_upload_hooks
    assert foo
  end

  def test_register_azure_upload
    assert_raise(RuntimeError) do
      MswinBuild.register_azure_upload(@tmpdir)
    end

    assert_equal 0, MswinBuild.instance_variable_get(:@upload_hooks).size

    ENV["AZURE_STORAGE_ACCESS_KEY"] = "dummy"
    assert_nothing_raised do
      MswinBuild.register_azure_upload(@tmpdir)
    end
    assert_equal 1, MswinBuild.instance_variable_get(:@upload_hooks).size
  end

  def test_azure_upload
    open(File.join(@tmpdir, "log", "test1.html.gz"), "w") do |f|
      f.print "test1"
    end
    open(File.join(@tmpdir, "recent.html"), "w") do |f|
      f.print "recent"
    end
    open(File.join(@tmpdir, "summary.html"), "w") do |f|
      f.print "summary"
    end
    service = Azure::BlobService.new
    assert_nothing_raised do
      MswinBuild.azure_upload(service, @tmpdir)
    end
    branch = File.basename(@tmpdir)
    refute File.exist?(File.join(@tmpdir, "log", "test1.html.gz"))
    assert_equal "test1", service.get_blob(nil, File.join(branch, "log", "test1.html.gz"))
    assert File.exist?(File.join(@tmpdir, "recent.html"))
    assert_equal "recent", service.get_blob(nil, File.join(branch, "recent.html"))
    assert File.exist?(File.join(@tmpdir, "summary.html"))
    assert_equal "summary", service.get_blob(nil, File.join(branch, "summary.html"))
  end

  def test_azure_upload_file
    service = Azure::BlobService.new

    file = "test1.html.gz"
    path = File.join(@tmpdir, file)
    open(path, "wb") do |f|
      f.puts "test1"
    end
    assert_nothing_raised do
      assert MswinBuild.azure_upload_file(service, "foo", file, path)
    end
    assert_equal "test1\n", service.get_blob(service, file)
    assert_equal "text/html", service.get_blob_metadata(service, file)[:content_type]
    assert_equal "gzip", service.get_blob_metadata(service, file)[:content_encoding]

    file = "test2.html"
    path = File.join(@tmpdir, file)
    open(path, "wb") do |f|
      f.puts "test2"
    end
    assert_nothing_raised do
      assert MswinBuild.azure_upload_file(service, "foo", file, path)
    end
    assert_equal "test2\n", service.get_blob(service, file)
    assert_equal "text/html", service.get_blob_metadata(service, file)[:content_type]
    assert_nil service.get_blob_metadata(service, file)[:content_encoding]
  end
end
