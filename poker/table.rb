module PokerMatic
# Represents a table of poker players
class Table
	attr_reader :board, :button, :phase, :seats, :pot, :current_bet,
		:minimum_bet, :current_bets, :hands, :table_id
	attr_accessor :timelimit, :queue, :small_blind, :ante

	PHASES = ['New Hand', 'Pre-Flop', 'Flop', 'Turn', 'River']
	def initialize(sb = 1, table_id = nil)
		@seats = []
		@queue = []
		@button = 0
		@deck = Deck.new
		@hands = {}
		@board = []
		@phase = 0
		@ante = 0
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
			'ante' => @ante,
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
	def move_position(num_spaces = 1, for_blinds = false)
		if num_spaces > 1
			num_spaces.times { move_position }
		else
			@current_position = person_in_spot(@current_position + 1)
			p = @seats[@current_position]
			if !for_blinds and @hands.size > @max_can_win.size
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
		if @phase == 0
			move_position(3, true)
		else
			move_position(1)
		end
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

	def pay_ante
		return unless @ante > 0
		@seats.each do |player|
			ante_amount = player.bankroll <= (@ante - 1) ? player.bankroll - 1 : @ante
			@pot += player.make_bet(ante_amount)
		end
	end

	def pay_blinds
		pay_ante
		small = @seats[person_in_spot(@button + 1)]
		big = @seats[person_in_spot(@button + 2)]
		if small.bankroll > @small_blind
			@current_bets[small] = small.make_bet(@small_blind)
			@pot += @small_blind
		else
			go_all_in(small, true)
		end
		if big.bankroll > big_blind
			@current_bets[big] = big.make_bet(big_blind)
			@pot += big_blind
			check_side_pots(big, big_blind, 0)
		else
			go_all_in(big, true)
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
	def go_all_in(player, for_blinds = false)
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
		unless for_blinds
			move_position unless @max_can_win.size == @hands.size
			@moves_taken += 1
		end
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
end