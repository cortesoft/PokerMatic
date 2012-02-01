#!/usr/bin/env ruby
require 'timeout'
require 'rubygems'
require 'spire_io'

class PokerAdmin
	def initialize(admin_url = nil, admin_capability = nil)
		@spire = Spire.new("http://build.spire.io")
		@admin_channel = new_channel(admin_url, admin_capability)
	end

	def create_tournament
		puts "Tournament name?"
		name = gets.chomp
		start_time = choose_start_time
		puts "Starting blinds?"
		starting_blinds = gets.chomp.to_i
		starting_blinds = 1 if starting_blinds < 1
		puts "Increase blinds every how many seconds?"
		blind_timer = gets.chomp.to_i
		@admin_channel.publish({'command' => 'create_tournament',
			'name' => name, 'start_time' => start_time.to_i, 'starting_blinds' => starting_blinds,
			'blind_timer' => blind_timer}.to_json)
	end

	def choose_start_time
		t = Time.now
		base_time = Time.local(t.year, t.month, t.day, t.hour, t.min)
		base_time += 60
		hsh = {}
		opt_num = 1
		10.times do |n|
			puts "#{opt_num}: #{base_time}"
			hsh[opt_num] = base_time
			base_time += n >= 5 ? 300 : 60
			opt_num += 1
		end
		puts "Time?"
		hsh[gets.chomp.to_i]
	end

	def rounded_minute(min)
		new_min = ((min / 5) * 5) + 5
		new_min > 55 ? 55 : new_min
	end

	def new_sub(url, capability)
		Spire::Subscription.new(@spire,
			{'capability' => capability, 'url' => url})
	end
	
	def new_channel(url, capability)
		Spire::Channel.new(@spire,
			{'capability' => capability, 'url' => url})
	end
end

config_file_location = File.expand_path("#{File.dirname(__FILE__)}/../config.rb")
if File.exists?(config_file_location)
	require config_file_location
	Admin = PokerAdmin.new(ADMIN_URL, ADMIN_CAPABILITY)
	def ct
		Admin.create_tournament
	end
end