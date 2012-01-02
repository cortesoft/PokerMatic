#!/usr/bin/env ruby
require 'rubygems'
require 'pp'
require 'spire_io'
require 'client_base'

class RandomClient < PokerClientBase
	
	def initialize
		super
	end

	def winner_update(data)
	end

	def ask_for_move(game_state)
		weights = {}
		game_state.available_moves.sort.reverse.each do |key, value|
			weights[key] = case key
				when 'all_in' then 1
				when 'check' then 20
				when 'call' then 20
				when 'fold' then 30
				when 'bet' then 50
			end
		end
		move = game_state.available_moves[pick_move(weights)]
		if move == 'bet'
			min_bet = game_state.available_moves['bet']
			max_bet = game_state.available_moves['all_in']
			current_bet = min_bet
			while current_bet < max_bet
				break if rand(100) < 25
				current_bet *= 1200.0 / (rand(1000) + 1)
				current_bet = current_bet.round
			end
			current_bet = max_bet if current_bet > max_bet
			move = current_bet
		end
		move
	end

	def pick_move(weights)
		total = weights.values.inject(0) {|i, x| i + x}
		curr_tot = 0
		rval = rand(total)
		weights.each do |key, value|
			curr_tot += value
			return key if rval < curr_tot
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
end

if $PROGRAM_NAME == __FILE__
	client = RandomClient.new
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