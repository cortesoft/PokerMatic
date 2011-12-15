#!/usr/bin/env ruby
API_KEY = nil
require 'rubygems'
require 'poker.rb'
require 'pp'
require 'spire_io'

class PokerServer
	attr_reader :discovery_url, :discovery_capability

	include PokerMatic
	
	def initialize
		@spire = Spire.new
		if !API_KEY
			puts "API key?"
			api_key = gets.chomp
		else
			api_key = API_KEY
		end
		@spire.start(api_key)
		@mutex = Mutex.new
		@log_mutex = Mutex.new
		@tables = {}
		@discovery = @spire['discovery']
		@tables_channel = @spire['tables']
		@registration = @spire['registration']
		@registration_response = @spire['registration_response']
		@create_table_channel = @spire['create_table']
		@players = {}
		@player_number = Time.now.to_i - 1323827358
		@table_number = Time.now.to_i - 1323828358
		payload = {}
		[['tables', @tables_channel.subscribe("table_sub")],
		['registration', @registration],
		['create_table', @create_table_channel],
		['registration_response', @registration_response.subscribe("reg_sub")]].each do |key, channel|
			payload[key] = {'url' => channel.url, 'capability' => channel.capability}
		end
		@discovery.publish(payload.to_json)
		@dsub = @discovery.subscribe("discovery_sub")
		setup_listeners
		@discovery_url = @dsub.url
		@discovery_capability = @dsub.capability
	end
	
	def log(m, use_pp = false)
		@log_mutex.synchronize do
			if use_pp
				pp m
			else
				puts "#{Time.now}: #{m}"
			end
		end
	end

	def setup_listeners
		@registration_sub = @registration.subscribe("reg_sub")
		@registration_sub.add_listener('reg_sub') {|m| process_registration(m)}
		@registration_sub.start_listening
		@create_table_sub = @create_table_channel.subscribe('create_table_sub')
		@create_table_sub.add_listener('create_table') {|m| process_create_table(m)}
		@create_table_sub.start_listening
	end
	
	def process_registration(message)
		command = JSON.parse(message)
		@mutex.synchronize do
			log 'Creating player with attributes:'
			log command, true
			return unless command.has_key?('name') and command.has_key?('id')
			if @players.has_key?(command['name'])
				log "Already have a player with the name #{command['name']}"
				@registration_response.publish({'id' => command['id'], 'status' => 'Name taken'}.to_json)
			else
				@player_number += 1
				p = Player.new(command['name'], @player_number)
				channel = @spire["player_#{@player_number}"]
				sub = channel.subscribe("sub_player_#{@player_number}")
				sub.add_listener("player_action") {|m| process_player_action(p, m)}
				sub.start_listening
				player_response = @spire["player_response_#{@player_number}"]
				pr_sub = player_response.subscribe("player_resp_sub_#{@player_number}")
				@players[command['name']] = {:player => p, :id => @player_number,
					:channel => channel, :subscription => sub, :response_channel => player_response,
					:response_sub => pr_sub}
				@registration_response.publish({'command_id' => command['id'],
					'url' => channel.url, 'capability' => channel.capability,
					'response_url' => pr_sub.url, 'player_id' => @player_number,
					'response_capability' => pr_sub.capability}.to_json)
			end
		end
	end #def process_registration

	def process_create_table(message)
		command = JSON.parse(message)
		log 'Creating table with attributes:'
		log command, true
		@mutex.synchronize do
			return unless command.has_key?('name')
			min_players = (command['min_players'] || 2).to_i
			blinds = (command['blinds'] || 1).to_i
			@table_number += 1
			table_channel = @spire["table_#{@table_number}"]
			channel_sub = table_channel.subscribe("table_sub_#{@table_number}")
			table = Table.new(blinds, @table_number)
			game = NetworkGame.new(self, table_channel, table, min_players, @log_mutex)
			@tables[@table_number] = {:table => table, :channel => table_channel,
				:channel_sub => channel_sub, :min_players => min_players,
				:game => game, :name => command['name']}
			@tables_channel.publish({'command_id' => command['id'], 'name' => command['name'],
				'id' => @table_number, 'min_players' => min_players, 'blinds' => blinds,
				'url' => channel_sub.url, 'capability' => channel_sub.capability}.to_json)
		end
	end
	
	def process_player_action(player, message)
		command = JSON.parse(message)
		log "Processing player action for #{player.name}"
		log command, true
		case command['command']
			when 'join_table' then join_table(player, command)
			when 'action' then take_table_action(player, command)
		end
	end
	
	def join_table(player, command)
		@mutex.synchronize do
			return false unless table_data = @tables[command['table_id']]
			table_data[:game].join_table(player, @players[player.name][:response_channel])
			table_data[:game].check_start unless table_data[:game].started
		end
	end
	
	def take_table_action(player, command)
		@mutex.synchronize do
			return false unless table_data = @tables[command['table_id']]
			return false unless table_data[:table].acting_player == player
			table_data[:game].take_action(player, command['action'])
		end
	end
end #class PokerServer

if $PROGRAM_NAME == __FILE__
	puts "Starting up server"
	s = PokerServer.new
	puts "Server running:"
	puts "Url: #{s.discovery_url}"
	puts "Capability: #{s.discovery_capability}"
	while true
		sleep 1000
	end
end