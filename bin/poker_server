#!/usr/bin/env jruby
require File.expand_path("#{File.dirname(__FILE__)}/../server/server.rb")
puts "Starting up server"
s = PokerServer.new
puts "Server running:"
puts "DISCOVERY_URL = '#{s.discovery_url}'"
puts "DISCOVERY_CAPABILITY = '#{s.discovery_capability}'"
puts "ADMIN_URL = '#{s.admin_url}'"
puts "ADMIN_CAPABILITY = '#{s.admin_capability}'"
while true
	sleep 1000
end