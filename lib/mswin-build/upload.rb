# derived from chkbuild/upload.rb, but changed for mswin-build.
# original copyright is below:

# chkbuild/upload.rb - upload method definition
#
# Copyright (C) 2006-2011 Tanaka Akira <akr@fsij.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following
# disclaimer in the documentation and/or other materials provided
# with the distribution.
# 3. The name of the author may not be used to endorse or promote
# products derived from this software without specific prior
# written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


module MswinBuild
  @upload_hooks = []
  def self.add_upload_hook(&block)
    @upload_hooks << block
  end

  def self.run_upload_hooks
    @upload_hooks.reverse_each do |block|
      begin
        block.call
      rescue Exception
        p $!
      end
    end
  end

  def self.register_azure_upload(logdir)
    ENV['AZURE_STORAGE_ACCOUNT'] ||= 'rubyci'
    raise 'no AZURE_STORAGE_ACCESS_KEY env' unless ENV['AZURE_STORAGE_ACCESS_KEY']

    require 'azure'
    require_relative 'azure-patch'
    service = Azure::BlobService.new
    service.with_filter do |req, _next|
      i = 0
      begin
        next _next.call
      rescue
        case $!
        when Errno::ETIMEOUT
          if i < 3
            i += 1
            retry
          end
        end
        raise $!
      end
    end

    add_upload_hook do
      azure_upload(service, logdir)
    end
  end

  def self.azure_upload(service, logdir)
    logdir = File.dirname(File.join(logdir, 'dummy'))
    branch = File.basename(logdir)
    container = File.basename(File.dirname(logdir))
    begin
      _res, body = service.get_blob(container, "#{branch}/recent.html")
      server_start_time = body[/^<a href=.*+ name="(\w+)">/, 1]
    rescue Azure::Core::Http::HTTPError => e
      server_start_time = '00000000T000000Z'
      if e.type == 'ContainerNotFound'
        service.create_container(container, :public_access_level => 'container')
      end
    end
    puts "Azure: #{branch} start_time: #{server_start_time}" if $DEBUG

    IO.foreach("#{logdir}/recent.html") do |line|
      break line[/^<a href=.*+ name="(\w+)">/, 1]
    end

    Dir.foreach(File.join(logdir, "log")).each do |file|
      next unless file.end_with?('.gz')
      blobname = File.join(branch, "log", file)
      filepath = File.join(logdir, "log", file)
      if (service.get_blob_metadata(container, blobname) rescue false)
        File.unlink filepath
        next
      end
      if azure_upload_file(service, container, blobname, filepath)
        File.unlink filepath
      end
    end

    %w"summary.html recent.html".each do |file|
      blobname = File.join(branch, file)
      filepath = File.join(logdir, file)
      azure_upload_file(service, container, blobname, filepath)
    end
  end

  def self.azure_upload_file(service, container, blobname, filepath)
    unless File.exist?(filepath)
      puts "File '#{filepath}' is not found"
      return false
    end

    options = {}
    case filepath
    when /\.html\.gz\z/
      options[:content_type] = "text/html"
      options[:content_encoding] = "gzip"
    when /\.html\z/
      options[:content_type] = "text/html"
    end

    open(filepath, 'rb') do |f|
      puts "uploading '#{filepath}' as '#{blobname}'..." if $DEBUG
      service.create_block_blob(container, blobname, f, options)
    end
    true
  end
end
