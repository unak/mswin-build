#! ruby
# expected ruby 1.9.x or later.

require "webrick"

class WEBrick::HTTPServer
  alias :__rewrite_old_service :service
  def service(req, res)
    ret = __rewrite_old_service(req, res)
    if /\.html\.gz\z/ =~ req.path
      res.header["content-encoding"] = "gzip"
      res.header["content-type"] = "text/html"
    end
  end
end

root = ARGV.shift
unless root
  puts "Usage: ruby #$0 <document root>"
  exit 1
end

options = {
  DocumentRoot: root,
}

server = WEBrick::HTTPServer.new(options)
shutdown = proc { server.shutdown }
(%w"TERM QUIT HUP INT" & Signal.list.keys).each do |sig|
  Signal.trap(sig, shutdown)
end
server.start
