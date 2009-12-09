#!/usr/bin/env ruby

require 'rubygems'
require 'stringio'
require 'cast'

class Object

  def cvar sym
    self.class.instance_variable_get sym
  end

end

class String

  def sinsp
    inspect.gsub(/\\0+/, '\\\\0')
  end

end

class FuseMsg

  PrintLimit = 512

  class FuseMsgError < RuntimeError
  end


  ### Model ###

  Ctypes = {}
  Msgmap = {}
  Zipcodes = {
    '__s32'  => 'l',
    '__s64'  => 'q',
    '__u32'  => 'L',
    '__u64'  => 'Q',
    '__u16'  => 'S',
    'char'   => 'a*',
    'string' => 'Z*'
  }

  Messages = {}
  MsgBodies = {} ## some default entries added later

  def self.import_proto_data ch
    Ctypes.clear
    Messages.clear
    # CAST can't handle macros, we have to strip them
    skip = false
    ca = []
    open(ch).each {|l|
      l =~ /^\s*#/ and skip = true
      skip or ca << l
      if skip
        skip = (l =~ /\\$/) ? true : false
      end
    }
    cp = C::Parser.new
    %w[__s32 __s64 __u32 __u64 __u16].each{|t| cp.type_names  << t}
    ct = cp.parse ca.join
    ct.entities.each {|e|
      et = e.type
      en = et.class.to_s.sub(/^C::/, "").to_sym
      Ctypes[en] ||= {}
      Ctypes[en][et.name] = []
      et.members.each { |m|
        Ctypes[en][et.name] << case en
        when :Struct
          [m.type.send(m.type.respond_to?(:name) ? :name : :to_s),
           m.declarators.first.name]
        when :Enum
          [m.name, m.val ? m.val.val : m.val]
        else raise FuseMsgError, "unknown C container #{en}"
        end
      }
    }
    Ctypes[:Enum]["fuse_opcode"].each {|o,n| Messages[n] = o }
    nil
  end

  def self.import_proto_messages ty
    Msgmap.clear
    Msgmap.merge! case ty
    when Hash
      ty
    when String
      YAML.load_file ty
    else
      raise TypeError, "cannot load message map from this"
    end
    nil
  end

  def self.import_proto ch, ty
    import_proto_data ch
    import_proto_messages ty
    generate_bodyclasses
    nil
  end

  ###### ORM layer #######
  ###### (t3h metaprogramming v00d00)

  def self.generate_bodyclass dir, op
    Class.new(MsgBodyGeneric).class_eval {
      @direction = dir
      @op = op
      extend MsgClassBaptize
      self
    }
  end

  def self.generate_bodyclasses
    Msgmap.each { |dir, ddesc|
      ddesc.each_key { |on|
        MsgBodies[[dir, on]] ||= generate_bodyclass dir, on
      }
    }
  end

  ### Controller ###
  ###### (#inspect-s belong to View, though...)

  module MsgClassBaptize

    def inspect
      "#{@op}_#{@direction}"
    end

  end

  class MsgBodyCore

    def initialize buf, msg
      @buf = buf
      @msg = msg
    end

    attr_reader :buf, :msg

    def self.inspect_buf buf, limit
      limit ||= PrintLimit
      limit.zero? && limit = buf.size
      buf.size <= limit ? buf.sinsp : buf[0...limit].sinsp + " ... [#{buf.size} bytes]"
    end

    def inspect limit = nil
      self.class.inspect_buf @buf, limit
    end

  end

  class MsgBodyGeneric < MsgBodyCore

    class Msgnode < Array

      def initialize tag = nil
        @tag = tag
      end

      def << elem, key = nil
        super [key, elem]
      end

      attr_accessor :tag

      def walk &b
        each { |kv|
          case kv[1]
          when Msgnode
            kv[1].walk &b
          else
            b[kv]
          end
        }
      end

      def deploy
        walk { |kv|
          tnam = kv[1]
          sr = Ctypes[:Struct][tnam]
          next unless sr
          sm = Msgnode.new tnam
          sr.each { |typ, fld| sm.<< typ, fld }
          kv[1] = sm.deploy
        }
        self
      end

      def [] idx
        case idx
        when Symbol
          idx = idx.to_s
          each { |k, v| k == idx and return v }
          nil
        else
          super
        end
      end

      def inspect limit = nil
        "#{@tag.to_s.sub(/^fuse_/i, "")}<%s>" % map { |k,v|
          v or next
          "#{k}#{k ? ": " : ""}%s" % case v
          when Msgnode
            v.inspect limit
          when String
            MsgBodyCore.inspect_buf v, limit
          else
            v.inspect
          end
        }.compact.join(" ")
      end

      def method_missing m, *a
        v = self[m]
        unless v
          raise NoMethodError, "undefined method `#{m}' for #{self.class}"
        end
        unless a.empty?
          raise ArgumentError, "wrong number of arguments (#{a.size} for 0)"
        end
        v
      end

      def populate buf, dtyp
        dtyp.each { |t| self.<< *t }
        deploy
        leaftypes = []
        walk { |kv| leaftypes << kv[1] }
        leafvalues = buf.unpack leaftypes.map { |t| Zipcodes[t] }.join
        walk { |kv| kv[1] = leafvalues.shift }
      end

    end

    def initialize buf, msg
      super
      @tree = Msgnode.new.populate @buf, Msgmap[cvar :@direction][cvar :@op].split
    end

    attr_reader :tree

    def inspect limit = nil
      @tree.inspect limit
    end

    def method_missing *a, &b
      if @tree
        return @tree.send *a, &b
      end
      raise NoMethodError, "undefined method `#{a[0]}' for #{self.class}"
    end

  end

#  Not needed if we make use of "Z*" unpacker
#
#  MsgRenameR = generate_bodyclass :R , 'FUSE_RENAME'
#  MsgRenameR.class_eval {
#
#    def initialize *a
#      super
#      k, nam = @tree.pop
#      nam.split(/\0/).each { |n| @tree << n }
#    end
#
#  }

  MsgGetxattrW = generate_bodyclass :W, 'FUSE_GETXATTR'
  MsgGetxattrW.class_eval {

    def initialize *a
      super
      if (mb = @msg.in_body) and mb[0][1][:size].zero?
        @tree = MsgBodyGeneric::Msgnode.new.populate @buf, ["fuse_getxattr_out"]
      end
    end

  }

  MsgListxattrW = MsgGetxattrW.dup

  MsgBodies.merge! [:W, 'FUSE_GETXATTR'] => MsgGetxattrW,
                   [:W, 'FUSE_LISTXATTR'] => MsgListxattrW

  def self.sizeof tnam
    @hcac ||= {}
    @hcac[tnam] ||= Ctypes[:Struct][tnam].transpose[0].instance_eval {|tt|
      ([0]*tt.size).pack(tt.map {|t| Zipcodes[t] }.join).size
    }
  end

  attr_accessor :in_head, :out_head, :in_body, :out_body

  def self.read_stream data
    data.respond_to? :read or data = StringIO.new(data)
    q = {}
    head_get = proc { |t|
      ts = t.to_s
      hsiz = sizeof(ts)
      h = MsgBodyGeneric::Msgnode.new(t).populate data.read(hsiz), Ctypes[:Struct][ts]
      [h, hsiz]
    }
    loop do
      dir = data.read 1
      yield case dir
      when 'R'
        in_head, hsiz = head_get[:fuse_in_header]
        in_head.tag = Messages[in_head.opcode] || "??"
        mbcls = MsgBodies[[:R, Messages[in_head.opcode]]]
        mbcls ||= MsgBodyCore
        msg = new
        msg.in_head = in_head
        msg.in_body = mbcls.new data.read(in_head.len - hsiz), msg
        q[in_head.unique] = msg
        [in_head, msg.in_body]
      when 'W'
        out_head, hsiz = head_get[:fuse_out_header]
        msg = q.delete(out_head.unique) || new
        msg.out_head = out_head
        mbcls = msg.in_head ? MsgBodies[[:W, Messages[msg.in_head.opcode]]] : MsgBodyCore
        mbcls ||= MsgBodyCore
        msg.out_body = mbcls.new data.read(out_head.len - hsiz), msg
        [out_head, msg.out_body]
      when nil
        break
      else
        raise FuseMsgError, "bogus direction #{dir.inspect}"
      end
    end
  end

end

  ### View ###


if __FILE__ == $0
  require 'optparse'

  limit = nil
  protoh = nil
  msgy = nil
  OptionParser.new do |op|
    op.on('-l', '--limit N', Integer) { |limit| }
    op.on('-p', '--proto_head F') { |protoh| }
    op.on('-m', '--msgdef F') { |msgy| }
  end.parse!
  FuseMsg.import_proto protoh, msgy
  FuseMsg.read_stream($<) { |m|
    puts m.map{|mp| mp.inspect limit}.join(" ")
  }
end
