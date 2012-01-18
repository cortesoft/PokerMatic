module PokerMatic
require 'set'

class Tournament
	attr_reader :start_time
	# :start_time, :log_mutex, :time_limit, :small_blind, :blind_timer, :start_chips
	# :tourney_id, :name, :server, :no_timer

	def initialize(opts = {})
		@server = opts[:server]
		@start_time = opts[:start_time] || Time.now + 600
		@log_mutex = opts[:log_mutex] || Mutex.new
		@tourney_id = opts[:tourney_id] || rand(9999999)
		@timelimit = opts[:time_limit] || 30
		@small_blind = opts[:small_blind] || 1
		@blind_timer = opts[:blind_timer] || 300
		@start_chips = opts[:start_chips] || 1000
		@name = opts[:name] || "Tourney #{@tourney_id}"
		@players = []
		@tables = []
		@table_player_counts = {}
		@mutex = Mutex.new
		@started = false
		@channel_hash = {}
		@finish_order = []
		@player_queue = {}
		start_timer unless opts[:no_timer]
	end
	
	def start_timer
		@timer = Thread.new {
			sleep(@start_time - Time.now)
			start_tournament
		}
	end

	def join_tournament(player, channel)
		@mutex.synchronize do
			if !@started
				@channel_hash[player] = channel
				@players << player
			end
		end
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

	def hand_finished(table)
		should_start_hand = false
		log "Starting hand finished for table #{table.table.table_id}"
		@mutex.synchronize do
			table.add_players_from_queue
			remove_busted_players(table.table)
			log "Removed busted players for #{table.table.table_id}"
			add_players_from_queue(table)
			rebalance_tables(table)
			log "Tables balanced busted players for #{table.table.table_id}"
			#If we still have a table to start
			check_for_winner
			log "Checked for winner for #{table.table.table_id}"
			if @table_player_counts[table]
				set_blind_levels(table)
				should_start_hand = table.seats.size > 1
			end
		end
		log "End hand finished #{table.table.table_id}"
		if should_start_hand
			log "Starting hand for #{table.table.table_id}"
			table.start_hand
		else
			log "Not starting another hand because table is empty"
		end
	end

	def check_for_winner
		if @players.size - @finish_order.size <= 1
			log "We have a winner for the tournament #{@name}!"
			winner = (@players - @finish_order).first
			log "Winner: #{winner.name}!"
			place = 2
			@finish_order.reverse.each do |p|
				log "#{place}. #{p.name}"
				place += 1
			end
		end
	end

	def current_small_blind
		elapsed = (Time.now - @start_time).to_i
		num_levels = (elapsed / @blind_timer)
		sb = @small_blind * (2 ** num_levels)
		log "#{elapsed} seconds have gone by, so the level is #{num_levels}, blind timer is #{@blind_timer} with blind is now at #{sb}"
		sb
	end

	def set_blind_levels(table)
		table.table.small_blind = current_small_blind
	end

	def add_players_from_queue(table)
		@player_queue[table.table.table_id] ||= []
		log "Adding players to the queue for #{table.table.table_id}, #{@player_queue[table.table.table_id].size} players"
		@player_queue[table.table.table_id].each do |player|
			log "Adding player #{player.name} to table #{table.table.table_id}"
			table.add_player_to_table(player, @channel_hash[player])
			@server.signal_player_to_subscribe_to_table(player, table.table)
		end
		@player_queue[table.table.table_id] = []
		log "Done adding players from the queue for table id #{@player_queue[table.table.table_id]}"
	end

	def rebalance_tables(table)
		@table_player_counts[table] = table.seats.size
		return true if close_table_if_possible(table)
		@table_player_counts.each do |other_table, num_players|
			next if other_table == table
			if table.seats.size > num_players + 1
				num_to_move = table.seats.size - (num_players + 1)
				log "Moving #{num_to_move} players from table #{table.table.table_id} to #{other_table.table.table_id}"
				@player_queue[other_table.table.table_id] ||= []
				log "The current queue for #{other_table.table.table_id} is: #{@player_queue[other_table.table.table_id].map {|x| x.name}.join(", ")}"
				num_to_move.times do
					player_to_move = table.table.player_in_position(table.table.button + 3)
					@player_queue[other_table.table.table_id] << player_to_move
					table.table.seats.delete(player_to_move)
					@table_player_counts[table] -= 1
					@table_player_counts[other_table] += 1
				end
			end
		end
	end

	def close_table_if_possible(table)
		available_seats = 0
		@table_player_counts.each {|other_table, n| next if other_table == table; available_seats += (10 - n) }
		if available_seats >= table.seats.size #We can close this table
			log "We are closing table #{table.table.table_id} because we have enough open seats"
			new_counts_hash = {}
			@table_player_counts.each do |other_table, n|
				next if other_table == table
				break if table.seats.size == 0
				log "Moving #{10 - n} players to table #{other_table.table.table_id}"
				@player_queue[other_table.table.table_id] ||= []
				new_counts_hash[other_table] = n
				(10 - n).times do
					p = table.seats.pop
					@player_queue[other_table.table.table_id] << p
					new_counts_hash[other_table] += 1
					break if table.seats.size == 0
				end
			end
			log "Done moving all players"
			new_counts_hash.each do |other_table, n|
				@table_player_counts[other_table] = n
			end
			@table_player_counts.delete(table)
			log "Done closing table"
			true
		else
			false
		end
	end

	def remove_busted_players(table)
		table.queue.each do |bp|
			log "Player #{bp.name} finished #{@players.size - @finish_order.size} out of #{@players.size}"
			@finish_order << bp
		end
		table.queue = []
	end

	def start_tournament
		@mutex.synchronize do
			@started = true
			give_starting_money
			assign_players_to_tables
		end
		add_table_callbacks
		start_games
	end

	def start_games
		@tables.each do |t|
			Thread.new(t) {|tab|
				tab.start_table
			}
		end
	end

	def give_starting_money
		@players.each do |player|
			player.set_bankroll(@start_chips)
		end
	end

	def assign_players_to_tables
		player_queue = @players.shuffle
		table_counts = choose_table_sizes
		log "For #{player_queue.size} players, creating #{table_counts.size} tables of size #{table_counts.join(", ")}"
		table_counts.each do |num_players|
			table_id = @server.get_next_table_number
			log "Creating table #{table_id} of size #{num_players}"
			t = Table.new(@small_blind, table_id)
			ng = NetworkGame.new(t, num_players, @log_mutex, @timelimit)
			num_players.times do
				p = player_queue.pop
				log "Assigning player #{p.name} to table #{table_id}"
				ng.join_table(p, @channel_hash[p])
			end
			@tables << ng
			@server.register_table(t,ng)
			@table_player_counts[ng] = num_players
		end
	end

	def tourney_stats(table)
		@mutex.synchronize do
			{
				'tournament' => {
					'total_players' => @players.size,
					'players_left' => @players.size - @finish_order.size,
					'finished' => @finish_order.map {|p| p.name },
					'number_of_tables' => @table_player_counts.size
				}
			}
		end
	end

	def add_table_callbacks
		@tables.each do |t|
			t.add_callback {|table| hand_finished(table)}
			t.add_tourney_callback {|table| tourney_stats(table)}
		end
	end

	def choose_table_sizes(max_per_table = 10)
		#How many tables do we need?
		num_tables = @players.size / max_per_table
		ret = []
		num_tables.times { ret << max_per_table}
		rem = @players.size % max_per_table
		puts "Max per table = #{max_per_table}, num players = #{@players.size} and num tables is #{num_tables} and remainder is #{rem}"
		if rem == 0
			#We are goo
		elsif rem == (max_per_table - 1)
			#We are still good
			ret << rem
		elsif (max_per_table - rem) <= num_tables
			i = num_tables - 1
			while rem < max_per_table - 1
				ret[i] -= 1
				rem += 1
				i -= 1
			end
			ret << rem
		else
			ret = choose_table_sizes(max_per_table - 1)
		end
		ret
	end
end

#A class for running a network based game
class NetworkGame
	attr_accessor :started, :table

	def initialize(table, min_players = 2, log_mutex = nil, time_limit = 30)
		@table = table
		@timelimit = time_limit
		@table.timelimit = @timelimit
		@log_mutex = log_mutex || Mutex.new
		@started = false
		@mutex = Mutex.new
		@min_players = min_players
		@channel_hash = {}
		@hand_number = 0
		@move_number = 0
		@callback = nil
		@tourney_callback = nil
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

	def seats
		@table.seats
	end

	def add_callback(&block)
		@callback = block
	end

	def add_tourney_callback(&block)
		@tourney_callback = block
	end

	def join_table(player, channel)
		@mutex.synchronize do
			@channel_hash[player] = channel
			if !@started
				@table.add_player(player) unless @table.seats.include?(player)
			else
				@table.add_player_to_queue(player)
			end
		end
	end

	def add_player_to_table(player, channel)
		@mutex.synchronize do
			@channel_hash[player] = channel
			@table.add_player(player)
		end
	end

	def set_table_channel(channel)
		@table_channel = channel
	end

	def add_players_from_queue
		@table.add_players_from_queue
	end

	def start_hand
		@mutex.synchronize do
			log "Starting hand"
			add_players_from_queue
			@hand_number += 1
			@table.deal
			start_timer
			send_game_state(false, true)
		end
	end

	def send_game_state(no_active = false, include_hands = false)
		base_hash = {'hand_number' => @hand_number, 'table_id' => @table.table_id,
			'state' => @table.table_state_hash(no_active), 'type' => 'game_state'}
		base_hash.merge!(@tourney_callback.call(self)) if @tourney_callback
		t = Time.now
		if include_hands
			@channel_hash.each do |player, channel|
				player_hash = {'player' => player.to_hash}
				if !@table.queue.include?(player) and @table.hands[player]
					hand = @table.hands[player].map {|x| x.to_hash}
					player_hash.merge!({'hand' => hand, 'seat_number' => @table.player_position(player)})
				end
				channel.publish(base_hash.merge(player_hash).to_json)
			end
			log "Took #{Time.now - t} seconds to send #{@channel_hash.size} table updates"
		else #don't include the hands
			@table_channel.publish(base_hash.to_json)
			log "Took #{Time.now - t} seconds to send 1 table update"
		end
	end

	def send_winner(winner_hash, hands)
		hsh = {'hand_number' => @hand_number, 'table_id' => @table.table_id,
			'winners' => winner_hash.to_a.map {|p, w| {'player' => p.to_hash, 'winnings' => w} },
			'type' => 'winner'}
		if hands.size > 1
			hsh['shown_hands'] = {}
			hands.each do |player, hand|
				hsh['shown_hands'][player.name] = hand.map {|x| x.to_hash}
			end
		end
		@table_channel.publish(hsh.to_json)
	end

	def check_start
		should_start = false
		@mutex.synchronize do
			should_start = (!@started and @table.seats.size >= @min_players)
		end
		start_table if should_start
	end

	def start_table
		log "Starting game at table #{@table.table_id} with #{@table.seats.size} players"
		@table.randomize_button
		@table.randomize_seats
		@started = true
		start_hand
	end

	def start_timer
		@move_number += 1
		Thread.new(@move_number, @table.acting_player) {|move_num, acting_player|
			sleep @timelimit
			should_force_move = false
			@mutex.synchronize do
				should_force_move = (@started and (@move_number == move_num) and (acting_player == @table.acting_player))
			end
			if should_force_move
				puts "Reached timelimit for player #{acting_player.name}... folding"
				take_action(acting_player, 'fold')
			end
		}
	end

	def take_action(player, action)
		raise "Hand is not started" unless @started
		@mutex.synchronize do
			if action == 'fold'
				log "Folding for #{player.name}"
				@table.fold(player)
			elsif action == 'check'
				puts "Checking for #{player.name}"
				@table.check(player)
			elsif action == 'call'
				@table.call(player)
			elsif action == 'all_in'
				@table.bet(player, player.bankroll)
			else
				puts "Betting #{action} for #{player.name}"
				@table.bet(player, action.to_i)
			end
		end
		if @table.betting_complete?
			next_round
		else
			@mutex.synchronize do
				send_game_state
				start_timer
			end
		end
	rescue
		log "Rescued action error #{$!.inspect}"
		log $!.backtrace.join("\n")
		#start_timer
		@channel_hash[player].publish({'type' => 'error', 'hand_number' => @hand_number,
			'table_id' => @table_id, 'message' => $!.message}.to_json)
		sleep 2
		@mutex.synchronize do
			send_game_state
		end
	end
	
	def next_round
		if @table.hand_over?
			@mutex.synchronize do
				log "#### HAND OVER #####"
				log "Board is \n\n#{@table.board_string}\n\n"
				log "Hands still in:\n\n"
				@table.hands.each do |player, hand|
					log "#{player.name}: #{hand.join(", ")}"
				end
				log "\n\n"
				log "#################"
				hands = @table.hands.dup
				winner_hash = @table.showdown
				send_winner(winner_hash, hands)
				@table.remove_busted_players
			end
			if @callback
				@callback.call(self)
			else
				if @table.seats.size > 1
					start_hand
				else
					@mutex.synchronize do
						@started = false
					end
				end
			end
		else
			@mutex.synchronize do
				@table.deal
			end
			if @table.betting_complete?
				@mutex.synchronize do
					send_game_state(true)
				end
				next_round
			else
				start_timer
				@mutex.synchronize do
					send_game_state
				end
			end
		end
	end
end

#A class for running a quick console game with 4 players
class QuickGame
	attr_reader :table
	def initialize(blinds = 1)
		@table = Table.new(blinds)
		populate_table
	end
	
	def populate_table
		@table.add_player(Player.new("Daniel"))
		@table.add_player(Player.new("Computer 1"))
		@table.add_player(Player.new("Computer 2"))
		@table.add_player(Player.new("Computer 3"))
		@table.randomize_button
	end

	def play_hand
		while true
			puts "\n\n\n\n\n\n"
			@table.deal
			while !@table.betting_complete?
				puts "\n\n\n"
				ap = @table.acting_player
				puts "Board is \n\n#{@table.board_string}\n\n"
				puts "Pot is #{@table.pot} and current bet is #{@table.current_bet}"
				puts "Minimum raise is to #{@table.current_bet + @table.minimum_bet}"
				puts "Acting player is #{ap.name} with a current bet of #{@table.current_bets[ap]}"
				puts "Hand is \n\n#{@table.acting_players_hand_string}\n\nand a stack of #{ap.bankroll}"
				puts "Bet? f for fold, c for check, call for call, # for bet"
				move = gets.chomp
				begin
					if move == 'f'
						puts "Folding"
						@table.fold(ap)
					elsif move == 'c'
						puts "Checking"
						@table.check(ap)
					elsif move == 'call'
						@table.call(ap)
					else
						puts "Betting #{move.to_i}"
						@table.bet(ap, move.to_i)
					end
				rescue
					puts "Invalid move: #{$!}"
				end
			end #while !@table.betting_complete?
			break if @table.hand_over?
		end
		puts "#### HAND OVER #####"
		puts "Board is \n\n#{@table.board_string}\n\n"
		puts "Hands still in:\n\n"
		@table.hands.each do |player, hand|
			puts "#{player.name}: #{hand.join(", ")}"
		end
		puts "\n\n"
		w = @table.showdown
		puts "#{w[:winners].map {|x| x.name}.join(", ")} won #{w[:winnings]}"
	end #def play_hand

end #class QuickGame

class Player
	attr_reader :bankroll, :name, :player_id
	def initialize(name, player_id = nil, bankroll = 500)
		@bankroll = bankroll
		@name = name
		@player_id = player_id.to_i
	end

	def make_bet(amount)
		@bankroll -= amount
		amount
	end

	def take_winnings(amount)
		@bankroll += amount
		amount
	end

	def set_bankroll(amount)
		@bankroll = amount
	end

	def to_hash
		{'name' => @name, 'bankroll' => @bankroll, 'id' => @player_id}
	end
end #class Player

# Represents a table of poker players
class Table
	attr_reader :board, :button, :phase, :seats, :pot, :current_bet,
		:minimum_bet, :current_bets, :hands, :table_id
	attr_accessor :timelimit, :queue, :small_blind

	PHASES = ['New Hand', 'Pre-Flop', 'Flop', 'Turn', 'River']
	def initialize(sb = 1, table_id = nil)
		@seats = []
		@queue = []
		@button = 0
		@deck = Deck.new
		@hands = {}
		@board = []
		@phase = 0
		@timelimit = 30
		@small_blind = sb
		@table_id = table_id
	end

	def remove_busted_players
		@seats.each do |player|
			@queue << player if player.bankroll <= 0
		end
		@seats -= @queue
	end

	def add_player_to_queue(player)
		puts "Adding player #{player.name} to queue"
		@queue << player
		puts "New queue: #{@queue.map {|x| x.name}.join(", ")}"
	end

	def add_players_from_queue
		players_to_remove = []
		@queue.each do |player|
			next if player.bankroll <= 0
			players_to_remove << player
			self.add_player(player) unless @seats.include?(player)
		end
		@queue -= players_to_remove
	end

	#Returns the current state of the table
	# @param [Boolean] no_active Set to true if there is no currently active player
	# @return [Hash] A hash representing the state of the table
	def table_state_hash(no_active = false)
		ap = (no_active or !acting_player) ? {} : acting_player.to_hash
		hsh = {
			'phase' => @phase,
			'phase_name' => PHASES[@phase],
			'button' => @button,
			'pot' => @pot,
			'big_blind' => big_blind, 
			'current_bet' => @current_bet,
			'minimum_bet' => @minimum_bet,
			'players' => @seats.map {|p| p.to_hash},
			'acting_player' => ap,
			'acting_seat' => no_active ? @button : @current_position,
			'board' => @board.map {|c| c.to_hash },
			'players_in_hand' => @hands.keys.map {|p| p.player_id.to_i},
			'players_waiting_to_join' => @queue.map {|p| p.to_hash },
			'player_bets' => {},
			'available_moves' => available_moves,
			'all_in' => @max_can_win.map {|p, mcw| {'player' => p.to_hash, 'pot' => mcw}},
			'round_history' => @round_history,
			'last_five_moves' => last_five_moves,
			'timelimit' => @timelimit
		}
		@current_bets.each do |player, bet|
			hsh['player_bets'][player.player_id] = bet
		end
		hsh
	end

	def last_five_moves
		@hand_history.size > 5 ? @hand_history[-5,5] : @hand_history
	end

	def available_moves
		am = {}
		cb = @current_bets[acting_player] || 0
		if cb == @current_bet
			am['check'] = 0
		else
			am['call'] = @current_bet - cb
		end
		am['bet'] = @minimum_bet + (@current_bet - cb)
		am['all_in'] = acting_player.bankroll
		am['fold'] = 0
		am
	end

	def add_player(player)
		@seats << player
	end

	def board_string
		@board.map {|x| x.to_s}.join("\n")
	end

	def acting_players_hand_string
		h = @hands[acting_player]
		h ? "#{h.map {|x| x.to_s}.join("\n")}" : ""
	end

	def hand_over?
		(betting_complete? and @phase == 4) or @hands.size == 1
	end

	def increase_blinds(multiplier = 2)
		@small_blind *= multiplier
	end

	def pay_blinds
		small = @seats[person_in_spot(@button + 1)]
		big = @seats[person_in_spot(@button + 2)]
		sb = small.bankroll > @small_blind ? @small_blind : small.bankroll
		bb = big.bankroll > big_blind ? big_blind : big.bankroll
		@pot += sb + bb
		@current_bets[small] = small.make_bet(sb)
		@current_bets[big] = big.make_bet(bb)
	end

	def randomize_button
		@button = rand(@seats.size)
	end

	def randomize_seats
		@seats = @seats.shuffle
	end

	def acting_player
		@seats[@current_position]
	end

	#Moves the current position
	def move_position(num_spaces = 1)
		if num_spaces > 1
			num_spaces.times { move_position }
		else
			@current_position = person_in_spot(@current_position + 1)
			p = @seats[@current_position]
			if @hands.size > @max_can_win.size
				move_position if !@hands.keys.include?(p) or @max_can_win.keys.include?(p)
			end
		end
	end

	def clear_hand
		@phase = 0
	end

	#Deals the next phase of the game
	def deal
		case @phase
			when 0 then new_hand
			when 1 then flop
			when 2 then turn_or_river
			when 3 then turn_or_river
		end
		@current_position = @button
		@round_history = []
		@players_at_start_of_hand = @hands.size - @max_can_win.size
		@minimum_bet = big_blind
		move_position(@phase == 0 ? 3 : 1) 
		@phase += 1
		@moves_taken = 0
	end
	
	def new_hand
		@board = []
		@hands = {}
		@hand_history = []
		@pot = 0
		@current_bets = {}
		@current_bet = big_blind
		@max_can_win = {}
		pay_blinds
		@deck.shuffle
		2.times do
			@seats.each do |player|
				@hands[player] ||= []
				@hands[player] << @deck.deal_card
			end
		end
	end
	
	def clear_bets
		@current_bets = {}
		@current_bet = 0
	end

	def big_blind
		@small_blind * 2
	end

	def flop
		#burn a card, for fun
		@deck.deal_card
		3.times do
			@board << @deck.deal_card
		end
		clear_bets
	end
	
	def turn_or_river
		@deck.deal_card
		@board << @deck.deal_card
		clear_bets
	end

	def player_in_position(pos)
		@seats[person_in_spot(pos)]
	end

	#A helper method that wraps around if needed
	def person_in_spot(pos)
		pos % @seats.size
	end

	#Returns the position of the current player
	def player_position(player)
		@seats.include?(player) ? @seats.index(player) : false
	end

	def ensure_acting_player(player)
		raise "#{player.name} is not the acting player" unless acting_player == player
	end

	def fold(player)
		ensure_acting_player(player)
		@hands.delete(player)
		@current_bets.delete(player)
		store_action('fold', player)
		move_position
		@moves_taken += 1
	end

	def check(player)
		bet(player, 0)
	end
	
	def call(player)
		bet(player, @current_bet - (@current_bets[player] || 0))
	end

	def bet(player, amount)
		ensure_acting_player(player)
		return go_all_in(player) if amount >= player.bankroll
		current_player_bet = @current_bets[player] || 0
		new_amount = current_player_bet + amount
		raise "Bet must be greater than or equal to #{@current_bet}" if @current_bet > new_amount
		raise "Minimum raise is #{@minimum_bet} and your raise is #{new_amount - @current_bet}" if 
			new_amount > @current_bet and new_amount < (@current_bet + @minimum_bet)
		raise_amount = new_amount - @current_bet
		@minimum_bet = raise_amount if raise_amount > @minimum_bet
		is_raise = @current_bet != 0
		@current_bet = new_amount
		@current_bets[player] = new_amount
		@pot += player.make_bet(amount)
		check_side_pots(player, amount, current_player_bet)
		move_position
		if amount == 0
			action_name = 'check'
		elsif raise_amount == 0
			action_name = 'call'
		else
			action_name = is_raise ? 'raise' : 'bet'
		end
		store_action(action_name, player, amount)
		@moves_taken += 1
	end

	def store_action(action, player, bet_amount = 0)
		hsh = {'action' => action, 'player' => player.player_id, 'pot' => @pot,
			'bet_amount' => bet_amount, 'current_total_bet' => @current_bet}
		@hand_history << hsh
		@round_history << hsh
	end

	#Sees if we need to add any money into the side pots
	def check_side_pots(player, amount, current_player_bet)
		return unless @max_can_win.size > 0
		@max_can_win.each do |other_player, bet|
			next if other_player == player
			next unless cb = @current_bets[other_player]
			next if cb <= current_player_bet
			if amount > (cb - current_player_bet)
				@max_can_win[other_player] += (cb - current_player_bet)
			else
				@max_can_win[other_player] += amount
			end
		end
	end

	#Goes all in
	def go_all_in(player)
		current_player_bet = @current_bets[player] || 0
		new_bet_amount = player.bankroll
		all_in_amount = new_bet_amount + current_player_bet
		@pot += player.make_bet(new_bet_amount)
		@max_can_win[player] = @pot
		@current_bets.each do |other_player, bet|
			next if other_player == player
			if bet > all_in_amount #we need to subtract some of the current pot
				@max_can_win[player] -= (bet - all_in_amount)
			end
		end
		@current_bets[player] = all_in_amount
		raise_amount = all_in_amount - @current_bet
		@minimum_bet = raise_amount if raise_amount > @minimum_bet
		@current_bet = all_in_amount if all_in_amount > @current_bet
		check_side_pots(player, new_bet_amount, current_player_bet)
		store_action('all-in', player, new_bet_amount)
		move_position unless @max_can_win.size == @hands.size
		@moves_taken += 1
	end

	def betting_complete?
		players_in_hand = @hands.size - @max_can_win.size
		players_in_hand < 1 or @hands.size == 1 or @players_at_start_of_hand == 1 or
		(@moves_taken >= @players_at_start_of_hand and @current_bets.all? {|player, bet| @max_can_win.keys.include?(player) || bet == @current_bet })
	end
	
	#Returns the winning user(s) and adds their winnings
	def showdown(winners_hash = {}, won_so_far = 0)
		puts "Starting showdown with hash:"
		pp winners_hash
		puts "Max can win:"
		pp @max_can_win
		top_hands = {}
		current_top = nil
		@hands.each do |player, hand|
			if top_hands.size == 0
				top_hands[player] = hand
				current_top = hand
			else
				w = HandComparison.new(current_top, hand, @board).winner
				if w == 2 #New winner
					top_hands = {player => hand}
					current_top = hand
				elsif w == 0 #tie
					top_hands[player] = hand
				end
			end
		end
		if @max_can_win.any? {|player, max_win| top_hands.keys.include?(player)} #One or more players had a side pot
			puts "At least one winner was in the side pot"
			@max_can_win.sort_by {|player, max_win| max_win}.each do |player, max_win|
				next unless top_hands.keys.include?(player)
				puts "Player #{player.name} was a winner, the current pot is #{@pot} and we have won #{won_so_far} so far.. max win is #{max_win}"
				winnings = (max_win - won_so_far) / top_hands.size
				winnings = @pot if winnings > @pot
				if winnings > 0
					puts "Winning #{winnings} for #{player.name}"
					player.take_winnings(winnings)
					@pot -= winnings
					won_so_far += winnings
					winners_hash[player] = winnings
				else
					puts "Not enough in the pot for this guy to win anything, moving on.. he wanted #{winnings}"
				end
				top_hands.delete(player)
				@hands.delete(player)
			end
			if @pot > 0 and top_hands.size == 0 #we need to recurse
				return showdown(winners_hash, won_so_far)
			end
		end
		winnings = @pot / top_hands.size.to_f
		top_hands.each do |player, hand|
			player.take_winnings(winnings)
			winners_hash[player] = winnings
		end
		@phase = 0
		@button = (@button + 1) % @seats.size
		@board = []
		@hands = {}
		@pot = 0
		@current_bets = {}
		@current_bet = @small_blind * 2
		winners_hash
	end
end #class Table

class Deck
	attr_accessor :cards, :delt_cards

	SUITS = ["Heart", "Diamond", "Club", "Spade"]

	def initialize(num_decks = 1)
		@cards = []
		@delt_cards = []
		create_cards(num_decks)
		shuffle
	end
	
	def create_cards(num_decks)
		num_decks.times do
			SUITS.each do |suit|
				(1..13).each do |value|
					@cards << Card.new(suit, value)
				end
			end
		end
	end
	
	def shuffle
		@cards = (@cards + @delt_cards).shuffle
		@delt_cards = []
	end
	
	def deal_card
		c = @cards.pop
		@delt_cards << c
		c
	end
end #class Deck

class Card
	attr_reader :suit, :value

	VAL_TO_NAME = {
		1 => "Ace",
		11 => "Jack",
		12 => "Queen",
		13 => "King"
	}

	def self.create(hsh_or_array)
		if hsh_or_array.is_a?(Array)
			hsh_or_array.map {|x| self.create(x)}
		else
			self.new(hsh_or_array['suit'], hsh_or_array['value'])
		end
	end

	def initialize(suit, value)
		@suit = suit
		@value = value
	end
	
	def to_hash
		{'suit' => @suit, 'value' => @value, 'name' => value_name, 'string' => to_s}
	end

	def value_name
		VAL_TO_NAME[@value] || @value
	end

	def to_s
		"#{value_name} of #{@suit}s"
	end
	
	def sort_value
		self.value == 1 ? 14 : self.value
	end
end #class Card

#Takes care of figuring out the winner
class HandComparison
	def initialize(hand1 = nil, hand2 = nil, board = nil)
		@hand1 = hand1
		@hand2 = hand2
		@board = board
	end
	
	#Returns 1 if the winner is hand 1, 2 if the winner is hand 2, and 0 if it is a tie
	def winner
		best_for_1 = best_hand(@hand1)
		best_for_2 = best_hand(@hand2)
		case best_for_1[:rank] <=> best_for_2[:rank]
			when -1 then 2
			when 1 then 1
			when 0 then check_kicker(best_for_1, best_for_2)
		end
	end
	
	def check_kicker(best_for_1, best_for_2)
		best_for_1[:kicker].each_with_index do |card, i|
			next if best_for_2[:kicker][i].value == card.value
			return card.sort_value > best_for_2[:kicker][i].sort_value ? 1 : 2
		end
		0 #tie
	end

	def best_hand(hand)
		straight_flush(hand) || four_of_a_kind(hand) || full_house(hand) || flush(hand) ||
			straight(hand) || three_of_a_kind(hand) || two_pair(hand) || pair(hand) || high_card(hand)
	end
	
	#returns all the cards of the most frequent suit
	def flush_cards(cards)
		hsh = {}
		cards.each {|c| hsh[c.suit] ||= []; hsh[c.suit] << c}
		ret = []
		hsh.each {|suit, suit_cards| ret = suit_cards if suit_cards.size > ret.size}
		ret.sort_by {|x| x.sort_value}
	end

	def straight_cards(cards)
		cards_in_a_row = []
		sorted = cards.sort_by {|c| c.value}.reverse
		cards_in_a_row << sorted.last if sorted.last.value == 1
		sorted.each do |card|
			if cards_in_a_row.size == 0 or
					(card.value == cards_in_a_row.last.value - 1) or 
					(card.value == 13 and cards_in_a_row.last.value == 1)
				cards_in_a_row << card
			elsif card.value != cards_in_a_row.last.value
				cards_in_a_row = [card]
			end
			break if cards_in_a_row.size == 5
		end
		cards_in_a_row.size == 5 ? cards_in_a_row : false
	end

	def straight_flush(hand)
		fc = flush_cards(hand + @board)
		return false unless fc.size >= 5
		st = straight_cards(fc)
		return false unless st
		{:rank => 8, :hand => st, :kicker => st}
	end
	
	def four_of_a_kind(hand)
		hsh = {}
		(hand + @board).each {|c| hsh[c.value] ||= []; hsh[c.value] << c}
		ret = nil
		hsh.each do |value, cards|
			next unless cards.size == 4
			ret = cards
			break
		end
		return false unless ret
		kicker = nil
		(hand + @board).sort_by {|x| x.sort_value}.reverse.each do |card|
			next if card.value == ret.first.value
			ret << card
			kicker = [ret.first, card]
			break
		end
		{:rank => 7, :hand => ret, :kicker => kicker}
	end
	
	def full_house(hand)
		hsh = {}
		at_least_two = Set.new
		at_least_three = Set.new
		(hand + @board).each {|c|
			hsh[c.value] ||= []
			hsh[c.value] << c
			at_least_two << c.value if hsh[c.value].size >= 2
			at_least_three << c.value if hsh[c.value].size >= 3
		}
		return false unless at_least_three.size >= 1 and at_least_two.size >= 2
		trips_val = at_least_three.include?(1) ? 1 : at_least_three.sort.last
		at_least_two.delete(trips_val)
		pair_val = at_least_two.include?(1) ? 1 : at_least_two.sort.last
		ret = hsh[trips_val] + hsh[pair_val][0,2]
		kicker = [hsh[trips_val].first, hsh[pair_val].first]
		{:rank => 6, :hand => ret, :kicker => kicker}
	end

	def flush(hand)
		fc = flush_cards(hand + @board)
		return false unless fc.size >= 5
		fc << fc.shift if fc.first.value == 1 #Use the ace if we have it
		ret = fc.reverse[0,5]
		{:rank => 5, :hand => ret, :kicker => ret}
	end
	
	def straight(hand)
		sc = straight_cards(hand + @board)
		sc ? {:rank => 4, :hand => sc, :kicker => sc} : false
	end
	
	def three_of_a_kind(hand)
		hsh = {}
		at_least_three = Set.new
		(hand + @board).each {|c|
			hsh[c.value] ||= []
			hsh[c.value] << c
			at_least_three << c.value if hsh[c.value].size >= 3
		}
		return false unless at_least_three.size > 0
		ret = hsh[at_least_three.first]
		kicker = [ret.first]
		(hand + @board).sort_by {|x| x.sort_value}.reverse.each do |card|
			next if ret.include?(card)
			ret << card
			kicker << card
			break if ret.size == 5
		end
		{:rank => 3, :hand => ret, :kicker => kicker}
	end
	
	def two_pair(hand)
		hsh = {}
		at_least_two = Set.new
		(hand + @board).each {|c|
			hsh[c.value] ||= []
			hsh[c.value] << c
			at_least_two << c if hsh[c.value].size >= 2
		}
		return false unless at_least_two.size >= 2
		ret = []
		kicker = []
		at_least_two.to_a.sort_by {|x| x.sort_value }.reverse[0,2].each do |v|
			ret += hsh[v.value]
			kicker << hsh[v.value].first
		end
		(hand + @board).sort_by {|x| x.sort_value}.reverse.each do |card|
			next if ret.include?(card)
			ret << card
			kicker << card
			break if ret.size == 5
		end
		{:rank => 2, :hand => ret, :kicker => kicker}
	end
	
	def pair(hand)
		hsh = {}
		at_least_two = Set.new
		(hand + @board).each {|c|
			hsh[c.value] ||= []
			hsh[c.value] << c
			at_least_two << c.value if hsh[c.value].size >= 2
		}
		return false unless at_least_two.size >= 1
		ret = hsh[at_least_two.first]
		kicker = [ret.first]
		(hand + @board).sort_by {|x| x.sort_value}.reverse.each do |card|
			next if ret.include?(card)
			ret << card
			kicker << card
			break if ret.size == 5
		end
		{:rank => 1, :hand => ret, :kicker => kicker}
	end
	
	def high_card(hand)
		ret = (hand + @board).sort_by {|x| x.sort_value}.reverse[0,5]
		{:rank => 0, :hand => ret, :kicker => ret}
	end
end #class HandComparison

end #module PokerMatic