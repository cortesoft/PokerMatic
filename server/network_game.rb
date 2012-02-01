module PokerMatic
#A class for running a network based game
class NetworkGame
	attr_accessor :started, :table

	def initialize(table, min_players = 2, log_mutex = nil, time_limit = 30)
		@table = table
		@timelimit = time_limit
		@table.timelimit = @timelimit
		@log_mutex = log_mutex || MutexTwo.new
		@started = false
		@mutex = MutexTwo.new
		@min_players = min_players
		@channel_hash = {}
		@hand_number = 0
		@move_number = 0
		@callback = nil
		@tourney_callback = nil
		@hand_timer = nil
		@timer_mutex = MutexTwo.new
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
			send_game_state(false, true)
			set_timer
		end
	end

	def encrypt_hand(player, hand)
		return hand unless player.public_key
		ret = []
		public_key_encrypter = OpenSSL::PKey::RSA.new(player.public_key)
		hand.each do |card|
			card_hash = {}
			card.each do |key, value|
				card_hash[key] = OpenPGP.enarmor(public_key_encrypter.public_encrypt(value.to_s))
			end
			ret << card_hash
		end
		ret
	end

	def merge_encrypted_hands(base_hash)
		hands_hash = {}
		@channel_hash.keys.each do |player|
			next unless @table.queue.include?(player) or @table.seats.include?(player)
			player_hash = {'player' => player.to_hash}
			if !@table.queue.include?(player) and @table.hands[player]
				hand = @table.hands[player].map {|x| x.to_hash}
				player_hash.merge!({'hand' => encrypt_hand(player, hand), 'seat_number' => @table.player_position(player)})
			end
			hands_hash[player.player_id.to_s] = player_hash
		end
		base_hash.merge!('player_data' => hands_hash)
	end

	def send_game_state(no_active = false, include_hands = false)
		base_hash = {'hand_number' => @hand_number, 'table_id' => @table.table_id,
			'state' => @table.table_state_hash(no_active), 'type' => 'game_state'}
		base_hash.merge!(@tourney_callback.call(self)) if @tourney_callback
		merge_encrypted_hands(base_hash) if include_hands
		t = Time.now
		@table_channel.publish(base_hash.to_json)
		log "Took #{Time.now - t} seconds to send 1 table update"
	rescue Excon::Errors::SocketError
		log "WARNING: Got a socket error #{$!} trying again"
		sleep 1
		send_game_state(no_active, include_hands)
	rescue
		log "Got error sending game state: #{$!.inspect}"
		log $!.backtrace, true
		raise
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
		start_timer_thread
		start_hand
	end

	def stop_timer_thread
		@timer_thread_running = false
	end

	def start_timer_thread
		@timer_thread_running = true
		Thread.new {
			while @timer_thread_running
				sleep 5
				should_force_move = false
				@timer_mutex.synchronize do
					should_force_move = (@started and @move_time_limit_info and
						@move_time_limit_info[:move_number] == @move_number and @move_time_limit_info[:need_move_by] < Time.now)
				end
				if should_force_move
					puts "Forcing move"
					acting_player = nil
					@mutex.synchronize do
						acting_player = @table.acting_player
					end
					puts "Reached timelimit for player #{acting_player.name}... folding"
					Thread.new(acting_player) {|ap|
						take_action(ap, 'fold')
					}
				end
			end
		}
	end

	def set_timer(tl = nil)
		tl ||= @timelimit
		@timer_mutex.synchronize do
			@last_timer_limit = tl
			@move_number += 1
			@move_time_limit_info = {:move_number => @move_number, :need_move_by => (Time.now + tl)}
		end
	end

	def clear_timer
		@timer_mutex.synchronize do
			@move_time_limit_info = nil
		end
	end

	def take_action(player, action)
		raise "Hand is not started" unless @started
		clear_timer
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
				set_timer
			end
		end
	rescue
		log "Rescued action error #{$!.inspect}"
		log $!.backtrace.join("\n")
		@channel_hash[player].publish({'type' => 'error', 'hand_number' => @hand_number,
			'table_id' => @table_id, 'message' => $!.message}.to_json)
		sleep 2
		@mutex.synchronize do
			send_game_state
			set_timer(@last_timer_limit / 2)
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
						stop_timer_thread
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
				@mutex.synchronize do
					send_game_state
					set_timer
				end
			end
		end
	end
end
end