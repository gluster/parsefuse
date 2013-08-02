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

    def typemap tnam
      case tnam
      when /^fuse_(.*)|(^cuse.*)/
        camelize($1||$2)
      when /^__u(\d+)$/
        "uint#{$1}"
      when /^__s(\d+)$/
        "int#{$1}"
      when "char"
        "[0]byte"
      when "string"
        "string"
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
