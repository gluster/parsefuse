#!/usr/bin/env ruby

require 'parsefuse'

class FuseMsg

  module Go
    extend self

    def makehead out
      out <<
<<GOBLOCK
package protogen

import (
	"log"
	"unsafe"
)

func clen(n []byte) int {
	for i := 0; i < len(n); i++ {
		if n[i] == 0 {
			return i
		}
	}
	log.Fatal("terminating zero not found in C string")
	return -1
}

GOBLOCK
     FuseVersion.size == 2 and out <<
<<GOBLOCK
const(
	FuseMajor = #{FuseVersion[0]}
	FuseMinor = #{FuseVersion[1]}
)

GOBLOCK
    end

    def opcodemap cn
      cn.sub(/^FUSE_/, "")
    end

    def makeopcodes out
      out << "const(\n"
      Ctypes[:Enum].each { |e,a|
        a.each { |n,v|
          v or next
          out << "\t#{opcodemap n} uint32 = #{v}\n"
        }
      }
      out << ")\n\n"

      out << "var FuseOpnames = [...]string{\n"
      used = Set.new [nil]
      Ctypes[:Enum].each { |e,a|
        a.each { |n,v|
          used.include? v and next
          n = opcodemap n
          out << %Q(\t#{n}: "#{n}",\n)
          used << v
        }
      }
      out << "}\n\n"
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

    def makestruct name, desc, out
      out << "type #{typemap name} struct {\n"
      desc.each { |f,v|
        out << "\t#{camelize v} #{typemap f}\n"
      }
      out << "}\n\n"
    end

    def makestructs out
      Ctypes[:Struct].each { |s,d|
        makestruct s, d, out
      }
    end

    def makeparser fnam, mmap, out
      out <<
<<GOBLOCK
func #{fnam}(opcode uint32, data []byte) (a []interface{}) {
	pos := 0
	a = make([]interface{}, 0, 2)
	switch opcode {
GOBLOCK
      mmap.each do |c,d|
        d or next
        d = d.map { |t| typemap t }
        d[0...-1].include? "[0]byte" and raise "[0]byte type must be trailing"
        out <<
<<GOBLOCK
        case #{opcodemap c}:
GOBLOCK
        strings = 0
        d.each do |t|
          out << case t
          when "[0]byte"
<<GOBLOCK
		a = append(a, data[pos:])
GOBLOCK
          when "string"
<<GOBLOCK
		l #{(strings += 1) == 1 ? ":" : ""}= clen(data[pos:])
		a = append(a, string(data[pos:][:l]))
		pos += l + 1
GOBLOCK
          else
<<GOBLOCK
		if len(data[pos:]) >= int(unsafe.Sizeof(#{t}{})) {
			a = append(a, *(*#{t})(unsafe.Pointer(&data[pos])))
			pos += int(unsafe.Sizeof(#{t}{}))
		} else {
				a = append(a, data[pos:])
		}
GOBLOCK
          end
        end
      end
      out <<
<<GOBLOCK
	default:
		if FuseOpnames[opcode] == "" {
			log.Printf("warning: unknown opcode %d", opcode)
		} else {
			log.Printf("warning: format spec missing for %s", FuseOpnames[opcode])
		}
		a = append(a, data)
	}
	return
}

GOBLOCK
    end

    def makeparsers out
      Msgmap.each { |c, m|
         makeparser "Parse#{c}", m, out
      }
    end

    def makeall out
      makehead out
      makeopcodes out
      makestructs out
      makeparsers out
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
  FuseMsg::Go.makeall $>
end
