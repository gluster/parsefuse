#!/usr/bin/env ruby

require 'json'
require 'optparse'

OptionParser.new do |op|
  op.banner = <<-END
Usage: #{$0} [< <STDIN>|<FILE>]

Takes a fusedump in JSON stream format and combines incoming messages
into request + response pairs.

Output is JSON stream (one object per line) with scheme

{"UNIQUE":<UNIQUE>,"OP":<OP NAME>, "REQUEST":<REQUEST MSG>, "RESPONSE":<RESPONSE MSG>}
END
end.parse!

pending={}

$<.each do |line|
  rec = JSON.load line
  namepart,msg = rec["Msg"].partition { |elem| String === elem }
  op = namepart[0]
  unique = msg.find { |elem| Hash === elem }["Unique"]
  head = {"UNIQUE" => unique, "OP" => op}
  outrec = case op
  when /\A(BATCH_)?FORGET\Z/
    head.merge "REQUEST"=>msg, "Truncated"=>rec["Truncated"]
  when /\ANOTIFY_/
    head.merge "REVERSE_REQUEST"=>msg, "Truncated"=>rec["Truncated"]
  when nil
     outreq = pending.delete unique
     if outreq
       head.merge "OP"=>outreq[:op],
                  "REQUEST"=>outreq[:msg], "RESPONSE"=>msg,
                  "Truncated"=>outreq[:truncated]||rec["Truncated"]
     else
       STDERR.puts "WARNING: missing request for unique #{unique}"
       nil
     end
   else
     pending[unique] = {op: op, msg: msg, truncated: rec["Truncated"]} 
     nil
   end
   outrec and puts outrec.to_json
end

pending.each do |unique,rec|
  op = rec[:op]
  STDERR.puts "WARNING: no response found for request UNIQUE: #{unique}, OP: #{op}"
end
