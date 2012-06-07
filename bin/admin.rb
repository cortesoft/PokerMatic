#!/usr/bin/env ruby
require 'timeout'
require 'rubygems'
require 'spire_io'

class PokerAdmin
	def initialize(email, password, app_name = "PokerMatic", api_url = 'https://api.spire.io')
		@spire = Spire.new(api_url)
    @spire.login(email, password)
    @application = @spire.session.find_or_create_application(app_name)
    @admin_member = @application.authenticate(email, password)
		@admin_channel = new_channel(@admin_member.profile['admin'])
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
		15.times do |n|
			puts "#{opt_num}: #{base_time}"
			hsh[opt_num] = base_time
			increment = case n
				when 0...5 then 60
				when 0...10 then 300
				when 10..15 then 3600
			end
			base_time += increment
			opt_num += 1
		end
		puts "Time?"
		hsh[gets.chomp.to_i]
	end

	def rounded_minute(min)
		new_min = ((min / 5) * 5) + 5
		new_min > 55 ? 55 : new_min
	end

	def new_sub(data)
		Spire::Subscription.new(@spire, data)
	end
	
	def new_channel(url, capabilities)
		Spire::Channel.new(@spire, data)
	end
end

config_file_location = File.expand_path("#{File.dirname(__FILE__)}/../config.rb")
if File.exists?(config_file_location)
	require config_file_location
	unless defined?(API_URL)
		API_URL = "https://api.spire.io"
  end
  unless defined?(APP_NAME)
    APP_NAME = "PokerMatic"
  end
	Admin = PokerAdmin.new(SPIRE_EMAIL, SPIRE_PASSWORD, APP_NAME, API_URL)
	def ct
		Admin.create_tournament
	end
end