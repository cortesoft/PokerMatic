#!/usr/bin/env ruby
require 'config.rb'
require 'rubygems'
require 'poker.rb'
require 'pp'
require 'spire_io'
require 'openssl'
require 'openpgp'
require 'mutex_two'

class PokerServer
	attr_reader :discovery_url, :discovery_capability, :admin_url, :admin_capability

	include PokerMatic
	
	def initialize
		#Trying to avoid collisions
		@player_number = Time.now.to_i - 1323827358
		@table_number = Time.now.to_i - 1323828358
		create_spire
		@mutex = MutexTwo.new
		@log_mutex = Mutex.new
		@tables = {}
		@players = {}
		@table_names = []
		@tournaments = {}
		create_channels
		create_admin_channels
	end

	def create_spire
		t = Time.now
		@spire = Spire.new("http://build.spire.io")
		puts "Took #{Time.now - t} seconds to do discovery"
		t = Time.now
		if !defined?(API_KEY) or !API_KEY
			puts "Creating new account"
			@spire.register(:email => "poker#{@player_number}@spire.io", :password => "#{rand(9999999999)}dageg")
		else
			api_key = API_KEY
			@spire.start(api_key)
		end
		puts "Took #{Time.now - t} seconds to start spire session"
	end

	def create_admin_channels
		@admin = @spire['admin']
		@admin_sub = @admin.subscribe
		@admin_sub.last = (Time.now.to_i * 1000)
		@admin_sub.add_listener("admin_sub") {|m| process_admin_command(m)}
		@admin_sub.start_listening
		@admin_url = @admin.url
		@admin_capability = @admin.capability
	end

	def create_channels
		@discovery = @spire["discovery_#{@player_number}"]
		@tables_channel = @spire["tables_#{@player_number}"]
		@registration = @spire['registration']
		@registration_response = @spire["registration_response_#{@player_number}"]
		@create_table_channel = @spire['create_table']
		@tournaments_channel = @spire["tournaments_#{@player_number}"]
		payload = {}
		[['tables', @tables_channel.subscribe],
		['registration', @registration],
		['create_table', @create_table_channel],
		['registration_response', @registration_response.subscribe],
		['tournaments', @tournaments_channel.subscribe]].each do |key, channel|
			payload[key] = {'url' => channel.url, 'capability' => channel.capability}
		end
		@discovery.publish(payload.to_json)
		@dsub = @discovery.subscribe
		setup_listeners
		@discovery_url = @dsub.url
		@discovery_capability = @dsub.capability
	end

	def setup_listeners
		@registration_sub = @registration.subscribe
		@registration_sub.last = (Time.now.to_i * 1000)
		@registration_sub.add_listener('reg_sub') {|m| process_registration(m)}
		@registration_sub.start_listening
		@create_table_sub = @create_table_channel.subscribe
		@create_table_sub.add_listener('create_table') {|m| process_create_table(m)}
		@create_table_sub.start_listening
	end

	#Thread safe logging to standard out
	def log(m, use_pp = false)
		@log_mutex.synchronize do
			use_pp ? pp(m) : puts("#{Time.now}: #{m}")
		end
	end

	def get_next_player_number
		@mutex.synchronize do
			@player_number += 1
			@player_number
		end
	end

	#Process a request to register a user from the registration channel
	def process_registration(message)
		command = JSON.parse(message)
		log 'Creating player with attributes:'
		log command, true
		return unless command.has_key?('name') and command.has_key?('id')
		pnum = get_next_player_number
		p = Player.new(command['name'], pnum)
		channel = @spire["player_#{pnum}"]
		sub = channel.subscribe
		sub.add_listener("player_action") {|m| process_player_action(p, m)}
		sub.start_listening
		player_response = @spire["player_response_#{pnum}"]
		pr_sub = player_response.subscribe
		@mutex.synchronize do
			@players[pnum] = {:player => p, :id => pnum,
				:channel => channel, :subscription => sub, :response_channel => player_response,
				:response_sub => pr_sub}
		end
		resp_hash = {'command_id' => command['id'],
			'url' => channel.url, 'capability' => channel.capability,
			'response_url' => pr_sub.url, 'player_id' => pnum,
			'response_capability' => pr_sub.capability}
		encrypt_capabilities(resp_hash, command['public_key']) if command['public_key']
		@registration_response.publish(resp_hash.to_json)
	end #def process_registration

	#Encrypts the capabilities before sending them out, to ensure privacy
	def encrypt_capabilities(resp_hash, public_key)
		public_key_encrypter = OpenSSL::PKey::RSA.new(public_key)
		rc = public_key_encrypter.public_encrypt(resp_hash.delete('response_capability'))
		resp_hash['encrypted_response_capability'] = OpenPGP.enarmor(rc)
		c = public_key_encrypter.public_encrypt(resp_hash.delete('capability'))
		resp_hash['encrypted_capability'] = OpenPGP.enarmor(c)
	end

	#Process a create table request from the tables channel
	def process_create_table(message)
		command = JSON.parse(message)
		log 'Creating table with attributes:'
		log command, true
		next_table_number = get_next_table_number
		@mutex.synchronize do
			return unless command.has_key?('name')
			return if @table_names.include?(command['name'])
			@table_names << command['name']
			min_players = (command['min_players'] || 2).to_i
			blinds = (command['blinds'] || 1).to_i
			table = Table.new(blinds, next_table_number)
			game = NetworkGame.new(table, min_players, @log_mutex)
			channel = @spire["table_#{next_table_number}"]
			sub = channel.subscribe("sub_table_#{next_table_number}")
			game.set_table_channel(channel)
			@tables[next_table_number] = {:table => table, :min_players => min_players,
				:game => game, :name => command['name'], :mutex => MutexTwo.new, :channel => channel,
				:subscription => sub}
			@tables_channel.publish({'command_id' => command['id'], 'name' => command['name'],
				'id' => next_table_number, 'min_players' => min_players, 'blinds' => blinds}.to_json)
		end
	end

	def get_next_table_number
		@mutex.synchronize do
			@table_number += 1
			@table_number
		end
	end

	#called by the tournament code
	def register_table(table, network_game)
		log "Registering table #{table.table_id}"
		channel = @spire["table_#{table.table_id}"]
		sub = channel.subscribe("sub_table_#{table.table_id}")
		hsh = {:table => table, :min_players => 2,
				:game => network_game, :name => "Table #{table.table_id}", :mutex => MutexTwo.new,
				:channel => channel, :subscription => sub}
		@mutex.synchronize do
			@tables[table.table_id] = hsh
			network_game.set_table_channel(channel)
			table.seats.each do |player|
				signal_player_to_subscribe_to_table(player, table)
			end
		end
		hsh
	end

	def signal_player_to_subscribe_to_table(player, table)
		player_channel = @players[player.player_id][:response_channel]
		table_sub = @tables[table.table_id][:subscription]
		log "Telling player #{player.name} to join table"
		hsh = {"type" => "table_subscription", "url" => table_sub.url,
			"capability" => table_sub.capability}
		log hsh, true
		player_channel.publish(hsh.to_json)
		log "Done telling player #{player.name} to join table"
	end

	#Process a request from a player channel
	def process_player_action(player, message)
		command = JSON.parse(message)
		log "Processing player action for #{player.name}"
		log command, true
		case command['command']
			when 'join_table' then join_table(player, command)
			when 'join_tournament' then join_tournament(player, command)
			when 'action' then take_table_action(player, command)
		end
	end

	def join_table(player, command)
		table_data = nil
		@mutex.synchronize do
			table_data = @tables[command['table_id']]
			signal_player_to_subscribe_to_table(player, table_data[:table])
		end
		return false unless table_data
		table_data[:mutex].synchronize do
			table_data[:game].join_table(player, @players[player.player_id][:response_channel])
			table_data[:game].check_start unless table_data[:game].started
		end
	end

	def join_tournament(player, command)
		@mutex.synchronize do
			return false unless tournament = @tournaments[command['tournament_id']]
			log "Player #{player.name} joined the tournament"
			tournament.join_tournament(player, @players[player.player_id][:response_channel])
		end
	end

	def take_table_action(player, command)
		table_data = nil
		@mutex.synchronize do
			table_data = @tables[command['table_id']]
		end
		return false unless table_data
		table_data[:mutex].synchronize do
			return false unless table_data[:table].acting_player == player
			table_data[:game].take_action(player, command['action'])
		end
	end

	def process_admin_command(m)
		command = JSON.parse(m)
		log "Recieved admin command:"
		log command, true
		case command['command']
			when 'create_tournament' then create_tournament(command)
		end
	end

	def create_tournament(command)
		tourney_number = get_next_table_number
		@mutex.synchronize do
			name = command['name'] || "Tourney #{tourney_number}"
			starting_blinds = command['starting_blinds'] || 1
			start_time = command['start_time'] ? Time.at(command['start_time']) : Time.now + 600
			blind_timer = command['blind_timer'] || 300
			tourney = Tournament.new(:server => self, :log_mutex => @log_mutex,
				:tourney_id => tourney_number, :small_blind => starting_blinds,
				:blind_timer => blind_timer, :name => name, :start_time => start_time)
			@tournaments[tourney_number] = tourney
			@tournaments_channel.publish({'name' => name, 'starting_time' => start_time.to_i,
				'id' => tourney_number}.to_json)
		end
		log "Tournament created"
	end
end #class PokerServer

if $PROGRAM_NAME == __FILE__
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
end