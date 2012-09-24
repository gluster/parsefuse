#!/usr/bin/env ruby

require 'ffi'
require 'parsefuse'

class Object

  def cvar sym
    self.class.instance_variable_get sym
  end

end

class FuseMsg

  ###### ORM layer #######
  ###### (t3h metaprogramming v00d00)

  class FuseFFI < FFI::Struct

    def inspect
      %w[< >].join(
        members.zip(values).map { |k,v|
         "#{k}: #{FuseFFI === v ? v.inspect : v}"
        }.join " "
      )
    end

  end

  MsgmapFFI = []
  R = 0
  W = 1

  def self.make_ffi
    structsffi = {}
    osiz = 0
    loop do
      # loop the struct definer
      # routine to get interdependent
      # types eventually resolved
      Ctypes[:Struct].each { |k,v|
        structsffi[k] and next
        la = v.map { |t,f|
          [f.to_sym,
           case t
           when /^__[us]/
             t.sub(/^__u/, "uint").sub(/^__s/, "int").to_sym
           when "char"
             [:char, 0]
           when /^[cf]use_/
             structsffi[t]
           end]
        }.flatten
        la.include? nil and next
        structsffi[k] = Class.new(FuseFFI).class_eval {
          layout *la.flatten
          self
        }
        const_set camelize(k), structsffi[k]
      }
      structsffi.size > osiz ? osiz = structsffi.size : break
    end
    structsffi.size == Ctypes[:Struct].size or raise "there are unresolvable types for FFI"
    Messages.each { |k,v| const_set opcodemap(v), k }
    FuseInHeader.size > FuseOutHeader.size or raise "head size assertion failed"

    Msgmap.each { |d,h|
      a = []
      h.each { |m, b|
        b or next
        a[const_get opcodemap(m)] = b.map { |t| structsffi[t] || t }
      }
      MsgmapFFI[const_get d] = a
    }
  end

  ### Controller ###
  ###### (#inspect-s belong to View, though...)

  class MsgPayload

    def initialize buf, layout, msg=nil
      @buf = buf
      @layout = layout
      @msg = msg
      unless layout
        msg and STDERR.puts "warning: no layout for #{Messages[msg.in_head.opcode]}"
        layout = %w[char]
      end
      pos = 0
      slice = proc { @buf.slice pos, @buf.size-pos }
      drained = false
      blob = proc {
        drained = true
        slice[]
      }
      @tree = []
      layout.each { |t|
        break if drained
        @tree << if t.is_a? Class and t < FuseFFI
          if pos + t.size > @buf.size
            blob[]
          else
            s = t.new slice[]
            pos += t.size
            s
          end
        else
          case t
          when "string"
            s = slice[].get_string 0
            pos += s.size + 1
            s
          when "char"
            blob[]
          else
            raise "unhandled layout directive #{t}"
          end
        end
      }
    end

    attr_reader :tree, :buf
    attr_accessor :msg

    def [] i
      @tree[i]
    end

    def inspect limit = nil
      @tree.empty? and return "<>"
      s = ""
      @tree.each_with_index { |e,i|
        s << case e
        when FuseFFI, String
          e.inspect
        when FFI::Buffer
          limit ||= PrintLimit
          limit.zero? && limit = e.size
          e.size <= limit ? e.get_bytes(0, e.size).inspect : e.get_bytes(0, limit).inspect + " ... [#{e.size} bytes]"
        else
          raise TypeError, "unknown tree elem type #{e.class}"
        end
        i == @tree.size-1 or s << " "
      }
      s
    end

    def copy
      buf = FFI::Buffer.new @buf.size
      buf.put_bytes 0, @buf.get_bytes(0, buf.size)
      self.class.new buf, @layout, @msg
    end

    def method_missing *a, &b
      if b or a.size != 1
        raise NoMethodError, "undefined method `#{a[0]}' for #{self.class}"
      end
      @tree[0][a[0]]
    end

  end

  class FuseInHeaderPayload < MsgPayload

    def initialize buf, layout=[FuseInHeader], msg=nil
      super
    end

    def inspect *a
      Messages[opcode].dup << " " << super
    end

  end

  class FuseReaddirOutPayload < MsgPayload

    def initialize buf, layout, msg=nil
      super
      raise "unhandled READDIR response layout" unless layout == %w[char]
      pos = 0
      slice = proc { @buf.slice pos, @buf.size-pos }
      @tree.clear
      while pos < buf.size
        if pos + FuseDirent.size > @buf.size
          @tree << slice[]
          pos = buf.size
        else
          s = FuseDirent.new slice[]
          @tree << s
          pos += s.size
          nlen = s[:namelen]
          @tree << buf.get_bytes(pos, nlen)
          pos += nlen + ((8 - nlen&7) & 7)
        end
      end
    end

  end

  class FuseGetxattrOutPayload < MsgPayload

    def initialize buf, layout, msg=nil
      if msg and msg.in_body and msg.in_body[0][:size] == 0
        layout = [FuseGetxattrOut]
      end
      super
    end

  end

  class FuseListxattrOutPayload < FuseGetxattrOutPayload

    def initialize *a
      super
      return unless @layout == %w[char]
      pos = 0
      @tree.clear
      while pos < buf.size
        @tree << @buf.get_string(pos)
        pos += @tree.last.size + 1
      end
    end

  end

  attr_accessor :in_head, :out_head, :in_body, :out_body

  def opcode
    @opcode || (@in_head && @in_head.opcode)
  end

  def save_opcode
    if @in_head
      @opcode = @in_head.opcode
      @in_head = nil
    end
  end

  def save *fnams
    fnams.each { |fnam|
      fnam = '@' + fnam.to_s
      f = instance_variable_get fnam
      f and instance_variable_set fnam, f.copy
    }
  end

  module LibcIO
    extend FFI::Library
    ffi_lib FFI::Library::LIBC
    attach_function :read, [ :int, :buffer_out, :size_t ], :int
  end

  def self.read_stream fd, opts={}
    preserve = opts[:preserve]
    fd.respond_to? :fileno and fd = fd.fileno
    hbuf = FFI::Buffer.new_out FuseInHeader.size + 1
    bbuf = FFI::Buffer.new_out 4096
    read = proc { |buf, &shortcbk|
      pos = 0
      while pos < buf.size
        r = LibcIO.read fd, buf.slice(pos, buf.size), buf.size - pos
        case r
        when -1
          raise SystemCallError, FFI::LastError.errno
        when 0
          shortcbk[r]
        else
          pos += r
        end
      end
    }
    realloc_body = proc { |h|
      n = h.len - h[0].size
      if bbuf.size < n
        bbuf = FFI::Buffer.new_out n
      end
      n
    }
    shraise = proc { raise "short read" }
    bR, bW = %w[R W].map{|d| d.unpack('c')[0] }
    q = {}
    inho = FuseOutHeader.size + 1
    inhts = hbuf.size - inho
    catch :eof do
      loop do
        read.call(hbuf.slice 0, inho) { |n| n.zero? ? throw(:eof) : shraise[] }
        dir = hbuf.get_uchar 0
        yield case dir
        when bR
          read.call hbuf.slice(inho, inhts), &shraise
          in_head = FuseInHeaderPayload.new hbuf.slice(1, FuseInHeader.size)
          b = bbuf.slice 0, realloc_body[in_head]
          read.call b, &shraise
          msg = new
          msg.in_head = in_head
          in_body = MsgPayload.new b, MsgmapFFI[R][in_head.opcode], msg
          q[in_head.unique] = msg unless in_head.opcode == FORGET
          if preserve or [LISTXATTR, GETXATTR].include? in_head.opcode
            msg.in_body = in_body
            msg.save :in_head, :in_body
          else
            msg.save_opcode
          end
          [in_head, in_body]
        when bW
          out_head = MsgPayload.new hbuf.slice(1, FuseOutHeader.size), [FuseOutHeader]
          b = bbuf.slice 0, realloc_body[out_head]
          read.call b, &shraise
          msg = q.delete(out_head.unique) || new
          out_body = case msg.opcode
          when READDIR
            FuseReaddirOutPayload
          when LISTXATTR
            FuseListxattrOutPayload
          when GETXATTR
            FuseGetxattrOutPayload
          else
            MsgPayload
          end.new b, msg.opcode && MsgmapFFI[W][msg.opcode], msg
          if preserve
            msg.out_head = out_head
            msg.out_body = out_body
            msg.save :out_head, :out_body
          end
          [out_head, out_body]
        when nil
          break
        else
          raise FuseMsgError, "bogus direction #{dir.chr.inspect}"
        end
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
    op.on('-l', '--limit N', Integer) { |v| limit = v }
    op.on('-p', '--proto_head F') { |v| protoh = v }
    op.on('-m', '--msgdef F') { |v| msgy = v }
  end.parse!
  FuseMsg.import_proto protoh, msgy
  FuseMsg.make_ffi
  FuseMsg.read_stream($<) { |m|
    puts m.map{|mp| mp.inspect limit}.join(" ")
  }
end
