#!/usr/bin/env ruby

require 'stringio'


class String

  def sinsp
    inspect.gsub(/\\0+/, '\\\\0')
  end

end


class FuseMsg

  Header = { :r => 'LLQQLLLL', :w => 'LlQ' }
  PrintLimit = 512

  Messages = {
    1 => :LOOKUP,
    2 => :FORGET,
    3 => :GETATTR,
    4 => :SETATTR,
    5 => :READLINK,
    6 => :SYMLINK,
    8 => :MKNOD,
    9 => :MKDIR,
    10 => :UNLINK,
    11 => :RMDIR,
    12 => :RENAME,
    13 => :LINK,
    14 => :OPEN,
    15 => :READ,
    16 => :WRITE,
    17 => :STATFS,
    18 => :RELEASE,
    20 => :FSYNC,
    21 => :SETXATTR,
    22 => :GETXATTR,
    23 => :LISTXATTR,
    24 => :REMOVEXATTR,
    25 => :FLUSH,
    26 => :INIT,
    27 => :OPENDIR,
    28 => :READDIR,
    29 => :RELEASEDIR,
    30 => :FSYNCDIR,
    31 => :GETLK,
    32 => :SETLK,
    33 => :SETLKW,
    34 => :ACCESS,
    35 => :CREATE,
    36 => :INTERRUPT,
    37 => :BMAP,
    38 => :DESTROY,
    39 => :IOCTL,
    40 => :POLL
  }

  class FuseMsgError < RuntimeError
  end

  def self.read_stream data, format = :binary
    case format
    when :binary
      loop do
        begin
          yield new(data)
        rescue FuseMsgError
          break
        end
      end
    when :ascii
      data.respond_to? :each or data = StringIO.new(data)
      data.each { |l|
        l =~ /^\s*(#|$)/ and next
        yield FuseMsg.import(l)
      }
    else raise FuseMsgError, "unknown fusedump format #{format}"
    end
  end

  def self.parse_ascii desc
     desc =~ /^\s*([RW])(?:\[[^\]]*\])?\s+(?:(\[(?:\d+,\s*)*\d\])\s+)?(.*)/
     dir = $1
     head = $2 ? eval($2).pack(Header[$1.downcase.to_sym]) : ""
     body = eval($3)
     Hash === body and body = body[:content] * body[:length]
     dir + head + body
  end

  def self.import desc
    new parse_ascii(desc)
  end

  def header_size
    @header_size ||= Header[@direction].instance_eval { |d| ([0]*d.size).pack(d).size }
  end

  attr_reader :direction, :header, :unique, :size, :body

  def initialize data, direction = nil
    data.respond_to? :read or data = StringIO.new(data)
    @direction = direction
    @direction ||= data.read(1)
    @direction &&= @direction.to_s.downcase.to_sym
    Header.include? @direction or raise FuseMsgError, "unknown direction #{@direction.inspect}"
    @header = data.read(header_size).unpack(Header[@direction])
    @unique, @size = @header.values_at(2, 0)
    @body = data.read(@size - header_size)
  end

  def inspect limit = nil
    limit ||= PrintLimit
    limit.zero? && limit = @body.size
    b_insp = @body.size <= limit ? @body.sinsp : @body[0...limit].sinsp + " ... [#{@body.size} bytes]"
    "#{@direction.to_s.upcase}[#{@unique}: #{@size}#{@direction == :r ? " " + Messages[@header[1]].to_s : ""}] #{@header.inspect} #{b_insp}"
  end

  def raw
    @header.pack(Header[@direction]) + @body
  end

end


if __FILE__ == $0
  require 'optparse'

  limit = nil
  format = :binary
  OptionParser.new do |op|
    op.on('-l', '--limit N', Integer) { |limit| }
    op.on('-a', '--ascii') { |v| format = :ascii }
  end.parse!
  FuseMsg.read_stream($<, format) { |f| puts f.inspect(limit) }
end
