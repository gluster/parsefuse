require 'rubygems'
require 'yaml'
require 'cast'

class FuseMsg

  ### Model ###

  FuseVersion = []

  Ctypes = {}
  Msgmap = {}
  Messages = {}
  Notifications = {}
  MsgBodies = {} ## some default entries added later
  Source = {}

  def self.import_proto_data ch, compat: false
    Ctypes.clear
    Messages.clear
    Notifications.clear
    data = IO.read ch
    Source[:proto] = data
    # CAST can't handle macros, we have to strip them
    skip = false
    ca = []
    data.each_line {|l|
      if l =~ /^\s*#/
        skip = true
        l =~ /VERSION.*\s(\d+)$/ and FuseVersion << Integer($1)
      end
      skip or ca << l
      if skip
        skip = (l =~ /\\$/) ? true : false
      end
    }
    cp = C::Parser.new
    %w[__s32 __s64 __u32 __u64 __u16
       int32_t int64_t uint32_t uint64_t uint16_t].each{|t| cp.type_names  << t}
    ct = cp.parse ca.join
    ct.entities.each {|e|
      et = e.type
      en = et.class.to_s.sub(/^C::/, "").to_sym
      Ctypes[en] ||= {}
      Ctypes[en][et.name] = []
      et.members.each { |m|
        Ctypes[en][et.name] << case en
        when :Struct
          [m.type.send(m.type.respond_to?(:name) ? :name : :to_s) || m.type.to_s,
           m.declarators.first.name]
        when :Enum
          [m.name, m.val ? m.val.val : m.val]
        else raise FuseMsgError, "unknown C container #{en}"
        end
      }
    }
    if compat
      Ctypes[:Struct]["fuse_batch_forget_in"] ||= [%w[uint64_t count]]
      Ctypes[:Struct]["fuse_forget_one"] ||= []
    end
    [[Messages, "fuse_opcode"],
     [Notifications, "fuse_notify_code"]].each { |k,v|
      Ctypes[:Enum][v].each {|o,n| k[n] = o }
    }
    nil
  end

  def self.import_proto_messages ty
    Msgmap.clear
    mmap,src = case ty
    when Hash
      [ty, ty.to_yaml]
    when String
      src = IO.read ty
      [YAML.load(src), src]
    else
      raise TypeError, "cannot load message map from this"
    end
    Msgmap.merge! mmap
    Source[:messages] = src
    nil
  end

  def self.import_proto ch, ty, kw={}
    import_proto_data ch, **kw
    import_proto_messages ty
    nil
  end

end
