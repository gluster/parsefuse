#!/usr/bin/env ruby

require 'erb'
require 'parsefuse'

class FuseMsg

  module Go
    extend self

    def opcodemap cn
      cn.sub(/^FUSE_/, "")
    end

    def camelize nam
      nam.split("_").map { |x| x.capitalize }.join
    end

    def structname tnam
      camelize($1||$2) if tnam =~ /^fuse_(.*)|(^cuse.*)/
    end

    def typemap tnam
      structname tnam or case tnam
      when /^__u(\d+)$/, /^uint(\d+)_t$/
        "uint#{$1}"
      when /^__s(\d+)$/, /^int(\d+)_t$/
        "int#{$1}"
      when "char"
        "[0]byte"
      else
        raise "unknown C type #{tnam}"
      end
    end

    def makeerb erb, out
      out << ERB.new(erb).result(binding)
    end
  end
end

if __FILE__ == $0
  require 'optparse'

  protoh = nil
  msgy = nil
  OptionParser.new do |op|
    op.on('-p', '--proto_head F') { |v| protoh = v }
    op.on('-m', '--msgdef F') { |v| msgy = v }
  end.parse!
  FuseMsg.import_proto protoh, msgy
  FuseMsg::Go.makeerb STDIN.read, $>
end
