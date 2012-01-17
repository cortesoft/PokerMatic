#!/usr/bin/env ruby
require 'rubygems'
require 'pp'
require 'spire_io'
require 'client_base'
require 'poker'

class AllInBot < PokerClientBase
	
	def initialize
		super
		@aggressiveness = (rand(40) + 80) / 100.0
	end

	def starting_hand_value(hand)
		hand = hand.dup
		hand.each {|x| x['sort_val'] = x['value'] == 1 ? 14 : x['value'] }
		hand.sort! {|x, y| y['sort_val'] <=> x['sort_val']}
		top_val = hand.first['sort_val']
		base_val = case top_val
			when 14 then 10
			when 13 then 8
			when 12 then 7
			when 11 then 6
			else top_val / 2.0
		end
		if hand.first['value'] == hand.last['value']
			if base_val == 2.5
				base_val = 3 
			end
			base_val *= 2
			base_val = 5 if base_val < 5
		else
			base_val += 2 if hand.first['suit'] == hand.last['suit']
			diff = hand.first['sort_val'] - hand.last['sort_val']
			if diff == 1
				base_val += 1 if hand.first['sort_val'] < 12 #lower than a queen
			elsif diff == 2
				base_val -= 1
			elsif diff == 3
				base_val -= 2
			elsif diff == 4
				base_val -= 4
			else
				base_val -= 5
			end
		end
		base_val
	end

	def ask_for_move(game_state)
		shv = starting_hand_value(game_state.hand)
		puts "Move for #{self.name}"
		puts "My aggressiveness: #{@aggressiveness} with shv #{shv}" 
		game_state.hand.each {|h| puts h['string']}
		if game_state.phase > 1
			puts "After phase 1"
			hand_rank = PokerMatic::HandComparison.new(nil, nil,
				PokerMatic::Card.create(game_state.board)).best_hand(PokerMatic::Card.create(game_state.hand))[:rank] - 
				PokerMatic::HandComparison.new(nil, nil,
				PokerMatic::Card.create(game_state.board)).best_hand([])[:rank]
			return hand_rank >= 2 ? 'all_in' : check_fold(game_state)
		end
		return another_big_bettor(game_state, shv) if game_state.current_bet > game_state.big_blind * 5
		if (shv * @aggressiveness) >= 12
			puts "Passed initial all in check"
			rand(10) >= 1 ? 'all_in' : check_fold(game_state)
		elsif (shv * @aggressiveness) ** 2 > (r = rand(400))
			puts "Rand was #{r} and calc was #{(shv * @aggressiveness) ** 2} so going all in"
			'all_in'
		else
			puts "Rand was #{r} and calc was #{(shv * @aggressiveness) ** 2} so NOT going all in"
			check_fold(game_state)
		end
	end
	
	def another_big_bettor(game_state, shv)
		puts "we have another big bettor"
		(shv * @aggressiveness) > 15 ? 'all_in' : 'fold'
	end
end

if $PROGRAM_NAME == __FILE__
	client = AllInBot.new
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