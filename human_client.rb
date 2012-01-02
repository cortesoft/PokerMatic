#!/usr/bin/env ruby
require 'rubygems'
require 'pp'
require 'spire_io'
require 'client_base'

class HumanClient < PokerClientBase
	def initialize
		super
	end

	def display_game_state(game_state)
		print "\n\n\n\n"
		print_state(game_state)
		puts "\n\n\n"
		if game_state.in_this_hand?
			puts "Your hole cards are:"
			puts "| #{game_state.hand.map {|x| x['string']}.join(" | ")} |"
		else
			puts "You are not in this hand.  You will join at the end of this hand"
		end
		puts "\n\n"
	end

	def winner_update(data)
		@mutex.synchronize do
			puts "We have a winner!"
			data['winners'].each do |hsh|
				puts "#{hsh['player']['name']} won #{hsh['winnings']}"
			end
			if data['shown_hands']
				puts "\n\n"
				data['shown_hands'].each do |pname, hand|
					puts "#{pname}: | #{hand.map {|x| x['string']}.join(" | ")} |"
				end
			end
		end
	end

	def ask_for_move(game_state)
		available_moves = {}
		move_num = 1
		game_state.available_moves.sort.reverse.each do |key, value|
			if key == 'all_in'
				puts "#{move_num}: All-In (#{value})"
			elsif key == 'check'
				puts "#{move_num}: Check"
			elsif key == 'call'
				puts "#{move_num}: Call (#{value})"
			elsif key == 'fold'
				puts "#{move_num}: Fold"
			elsif key == 'bet'
				puts "#{move_num}: Bet (minimum bet is #{value})"
			end
			available_moves[move_num] = key
			move_num += 1
		end
		puts "Your move?"
		move = gets.chomp.to_i
		unless available_moves[move]
			puts "Not a valid move"
			return ask_for_move(game_state)
		end
		move = available_moves[move]
		if move == 'bet'
			min_bet = game_state.available_moves['bet']
			max_bet = game_state.available_moves['all_in']
			puts "Bet how much? (#{min_bet} to #{max_bet})"
			move = gets.chomp.to_i
			if move < min_bet or move > max_bet
				puts "Bet must be between #{min_bet} and #{max_bet}"
				return ask_for_move(game_state)
			end
		end
		@player_channel.publish({'table_id' => @active_table_number,
			'command' => 'action', 'action' => move}.to_json)
	end

	#Returns a representation of the users spot
	def user_array(user_data, game_data, index)
		is_button = game_data['state']['button'] == index
		is_active = game_data['state']['acting_player']['id'] == user_data['id']
		in_hand = game_data['state']['players_in_hand'].include?(user_data['id'])
		bet = game_data['state']['player_bets'][user_data['id'].to_s]
		all_in = user_data['bankroll'] == 0
		ar = []
		ar << "#######"
		ar << "##{user_data['name'][0,5].center(5)}#"
		ar << (is_button ? "#  B  #" : "#     #")
		ar << (all_in ? "#ALLIN#" : (is_active ? "# Act #" : "#######"))
		ar << "# Bet #"
		ar << (in_hand ? "##{bet.to_s.center(5)}#" : "# Fold#")
		ar << "#Stack#"
		ar << "##{user_data['bankroll'].to_i.to_s.center(5)}#"
		ar << "#######"
	end

	def print_state(data)
		state = data['state']
		puts "##################################"
		if state['players_waiting_to_join'].size > 0
			puts "Players waiting to join: #{state['players_waiting_to_join'].map {|x| x['name']}.join(", ")}"
		end
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
end

if $PROGRAM_NAME == __FILE__
	client = HumanClient.new
	puts "User name?"
	name = gets.chomp
	client.create_user(name)
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