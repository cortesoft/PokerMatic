#!/usr/bin/env ruby
require 'rubygems'
require 'pp'
require 'spire_io'

class PokerClient
	attr_accessor :player_id, :mutex
	DISCOVERY_URL = 'https://api.spire.io/subscription/Su-YoEn'
	DISCOVERY_CAPABILITY = '2Pfe5sqfFdmTuK9Z4fjbXQ='
	
	def initialize
		@mutex = Mutex.new
		@player_id = nil
		@spire = Spire.new
		d_sub = new_sub(DISCOVERY_URL, DISCOVERY_CAPABILITY)
		@discovery = JSON.parse(d_sub.listen.last)
	end
	
	def table_update(m)
		data = JSON.parse(m)
		if data['type'] == 'game_state'
			unless wait_for_hand_data(data['hand_number'])
				puts "Never got the hand data! FUCCCKKK"
				return false
			end
			@mutex.synchronize do
				print "\n\n\n\n"
				print_state(data)
				puts "\n\n\n"
				puts "Your hole cards are:"
				hand = @hand_hash[data['hand_number']]
				puts "| #{hand.map {|x| x['string']}.join(" | ")} |"
				puts "\n\n"
				ask_for_move(data) if data['state']['acting_player']['id'] == @player_id
			end
		elsif data['type'] == 'winner'
			@mutex.synchronize do
				puts "We have a winner!"
				puts "#{data['winners'].map {|x| x['name']}.join(", ")} won #{data['winnings']}"
				if data['shown_hands']
					data['shown_hands'].each do |pname, hand|
						puts "#{pname}: | #{hand.map {|x| x['string']}.join(" | ")} |"
					end
				end
			end
		end
	end

	def ask_for_move(data)
		puts "Your move? (fold, check, call, or a number to bet)"
		move = gets.chomp
		@player_channel.publish({'table_id' => @active_table_number,
			'command' => 'action', 'action' => move}.to_json)
	end

	#Returns a representation of the users spot
	def user_array(user_data, game_data, index)
		is_button = game_data['state']['button'] == index
		is_active = game_data['state']['acting_player']['id'] == user_data['id']
		in_hand = game_data['state']['players_in_hand'].include?(user_data['id'])
		bet = game_data['state']['player_bets'][user_data['id'].to_s]
		ar = []
		ar << "#######"
		ar << "##{user_data['name'][0,5].center(5)}#"
		ar << (is_button ? "#  B  #" : "#     #")
		ar << (is_active ? "# Act #" : "#######")
		ar << "# Bet #"
		ar << (in_hand ? "##{bet.to_s.center(5)}#" : "# Fold#")
		ar << "#Stack#"
		ar << "##{user_data['bankroll'].to_i.to_s.center(5)}#"
		ar << "#######"
	end

	def print_state(data)
		state = data['state']
		puts "##################################"
		puts "Hand number #{data['hand_number']}"
		puts state['phase_name']
		puts "Pot #{state['pot']} Current Bet #{state['current_bet']}"
		puts "Board:"
		print_board(state['board'])
		i = -1
		ar = state['players'].map {|d| i += 1; user_array(d, data, i)}
		(0..8).each do |x|
			puts ar.map {|l| l[x]}.join("  ")
		end
	end

	def print_board(board)
		puts "| #{board.map {|x| x['string']}.join(" | ")} |"
	end

	def player_update(m)
		data = JSON.parse(m)
		return unless data['type'] == 'hand'
		@mutex.synchronize do
			#puts "Got hand update for #{data['hand_number']}"
			@hand_hash[data['hand_number']] = data['hand']
			@bankroll = data['player']['bankroll']
		end
	end

	def wait_for_hand_data(hand_number)
		20.times do
			@mutex.synchronize do
				return true if @hand_hash[hand_number]
			end
			sleep 2
			puts "Still waiting for hand data"
		end
		false
	end

	def create_user(name)
		@mutex.synchronize do
			@reg_response = new_sub(@discovery['registration_response']['url'],
				@discovery['registration_response']['capability'])
			@command_id = rand(99999999)
			@reg_response.last = Time.now.to_i - 5
			@reg_response.add_listener('reg_response') {|m| user_created(m)}
			@reg_response.start_listening
			@create_player_channel = new_channel(@discovery['registration']['url'],
				@discovery['registration']['capability'])
			@create_player_channel.publish({'name' => name, 'id' => @command_id}.to_json)
		end
	end

	#Callback for after a user is created
	def user_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @command_id
			@mutex.synchronize do
				@player_channel = new_channel(resp['url'], resp['capability'])
				@player_updates = new_sub(resp['response_url'], resp['response_capability'])
				@player_id = resp['player_id']
			end
		else
			#puts "Registration response for someone else"
		end
	end

	def join_table
		raise "No player yet!" unless @player_id
		#get all the possible tables
		tc = new_sub(@discovery['tables']['url'], @discovery['tables']['capability'])
		all_tables = tc.listen.map {|x| JSON.parse(x) rescue nil}.compact
		hsh_map = {}
		num = 0
		all_tables.each do |table|
			num += 1
			hsh_map[num] = table
			puts "Table #{num}: #{table['name']} Blinds #{table['blinds']} Min Players #{table['min_players']}"
		end
		puts "Join which table?"
		tnum = gets.chomp.to_i
		join_specific_table(hsh_map[tnum])
	end

	def join_specific_table(data)
		puts "Joining table #{data['name']}"
		@hand_hash = {}
		@active_table_number = data['id']
		@active_table_sub = new_sub(data['url'], data['capability'])
		@active_table_name = data['name']
		@active_table_sub.add_listener('active_table_sub') {|m| table_update(m)}
		@player_updates.add_listener('player_update') {|m| player_update(m)}
		@active_table_sub.start_listening
		@player_updates.start_listening
		@player_channel.publish({'table_id' => @active_table_number, 'command' => 'join_table'}.to_json)
	end

	def my_table_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @table_command_id
			join_specific_table(resp)
		#else
			#puts "Another user created a table"
		end
	end

	def create_table(name, min_players = 2, blinds = 1)
		raise "No player yet!" unless @player_id
		@reg_response.stop_listening if @reg_response
		@table_command_id = rand(99999999)
		@table_response = new_sub(@discovery['tables']['url'],
				@discovery['tables']['capability'])
		@create_table_channel = new_channel(@discovery['create_table']['url'],
				@discovery['create_table']['capability'])
		@table_response.last = Time.now.to_i - 5
		@table_response.add_listener('table_response') {|m| my_table_created(m)}
		@table_response.start_listening
		@create_table_channel.publish({'name' => name, 'id' => @table_command_id,
			'min_players' => min_players, 'blinds' => blinds}.to_json)
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

if $PROGRAM_NAME == __FILE__
	client = PokerClient.new
	puts "User name?"
	name = gets.chomp
	client.create_user(name)
	while true
		sleep 1
		client.mutex.synchronize do
			next unless client.player_id
		end
		break
	end
	puts "Join a room or create a new one? 'join' or name of room"
	if 'join' == (choice = gets.chomp)
		client.join_table
	else
		puts "Number of players at the table?"
		num = gets.chomp.to_i
		client.create_table(choice, num)
	end
	while true
		sleep 1000
	end
end