module PokerMatic
class Tournament
	attr_reader :start_time

	BLIND_LEVELS = [1, 2, 3, 4, 4, 6, 8, 12, 16, 20,
		24, 32, 40, 60, 80, 120, 160, 240, 320, 400, 500]
	ANTE_LEVELS = [0,0,0,0,1,1,2,3,4,4,8,8,12,20,20,40,40,40,80,100,100,100,125,150]

	# :start_time, :log_mutex, :time_limit, :small_blind, :blind_timer, :start_chips
	# :tourney_id, :name, :server, :no_timer
	def initialize(opts = {})
		@server = opts[:server]
		@start_time = opts[:start_time] || Time.now + 600
		@log_mutex = opts[:log_mutex] || MutexTwo.new
		@tourney_id = opts[:tourney_id] || rand(9999999)
		@timelimit = opts[:time_limit] || 30
		@small_blind = opts[:small_blind] || 25
		@blind_timer = opts[:blind_timer] || 300
		@start_chips = opts[:start_chips] || 4000
		@name = opts[:name] || "Tourney #{@tourney_id}"
		@players = []
		@network_games = []
		@table_player_counts = {}
		@mutex = MutexTwo.new
		@started = false
		@channel_hash = {}
		@finish_order = []
		@player_queue = {}
		@game_threads = {}
		start_timer unless opts[:no_timer]
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

	def join_tournament(player, channel)
		@mutex.synchronize do
			if !@started
				@channel_hash[player] = channel
				@players << player
			else
				log "#{player.name} can't join the tournament, as it has already started"
			end
		end
	end

	def start_timer
		@start_timer = Thread.new {
			sleep(@start_time - Time.now)
			start_tournament
		}
	end

	def start_tournament
		@mutex.synchronize do
			@started = true
		end
		give_starting_money
		assign_players_to_tables
		add_table_callbacks
		log "Sleeping before starting tourney"
		sleep 10
		log "Starting tourney"
		start_games
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
			@network_games << ng
			@server.register_table(t,ng)
			@table_player_counts[ng] = num_players
		end
	end

	def add_table_callbacks
		@network_games.each do |ng|
			ng.add_callback {|network_game| hand_finished_callback(network_game)}
			ng.add_tourney_callback {|network_game| tourney_stats(network_game)}
		end
	end

	def start_games
		log "Starting #{@network_games.size} network games"
		@temp_mutex = Mutex.new
		@ng_queue = @network_games.dup
		@network_games.size.times do
			Thread.new {
				network_game = nil
				@temp_mutex.synchronize do
					network_game = @ng_queue.pop
				end
				log "Starting table #{network_game.table.table_id}"
				network_game.start_table
			}
		end
		log "Done starting all tables"
	end

	def hand_finished_callback(network_game)
		should_start_hand = false
		log "Starting hand finished for network_game table #{network_game.table.table_id}"
		@mutex.synchronize do
			network_game.add_players_from_queue
			remove_busted_players(network_game.table)
			log "Removed busted players for #{network_game.table.table_id}"
			add_players_from_queue(network_game)
			rebalance_tables(network_game)
			log "Tables balanced busted players for #{network_game.table.table_id}"
			#If we still have a table to start
			check_for_winner
			log "Checked for winner for #{network_game.table.table_id}"
			if @table_player_counts[network_game]
				set_blind_levels(network_game)
				should_start_hand = network_game.seats.size > 1
			end
		end
		log "End hand finished #{network_game.table.table_id}"
		if should_start_hand
			log "Starting hand for #{network_game.table.table_id}"
			network_game.start_hand
		else
			log "Not starting another hand because table is empty"
		end
	end

	def remove_busted_players(table)
		table.queue.each do |bp|
			log "Player #{bp.name} finished #{@players.size - @finish_order.size} out of #{@players.size}"
			@finish_order << bp
		end
		table.queue = []
	end

	def add_players_from_queue(network_game)
		table = network_game.table
		@player_queue[table.table_id] ||= []
		log "Adding players to the queue for #{table.table_id}, #{@player_queue[table.table_id].size} players"
		@player_queue[table.table_id].each do |player|
			log "Adding player #{player.name} to table #{table.table_id}"
			network_game.add_player_to_table(player, @channel_hash[player])
			@server.signal_player_to_subscribe_to_table(player, table)
		end
		@player_queue[table.table_id] = []
		log "Done adding players from the queue for table id #{@player_queue[table.table_id]}"
	end

	def rebalance_tables(network_game)
		table = network_game.table
		@table_player_counts[network_game] = network_game.seats.size
		return true if close_table_if_possible(network_game)
		@table_player_counts.each do |other_ng, num_players|
			next if other_ng == network_game
			other_table = other_ng.table
			if network_game.seats.size > num_players + 1
				num_to_move = network_game.seats.size - (num_players + 1)
				log "Moving #{num_to_move} players from table #{table.table_id} to #{other_table.table_id}"
				@player_queue[other_table.table_id] ||= []
				log "The current queue for #{other_table.table_id} is: #{@player_queue[other_table.table_id].map {|x| x.name}.join(", ")}"
				num_to_move.times do
					player_to_move = table.player_in_position(table.button + 3)
					@player_queue[other_table.table_id] << player_to_move
					table.seats.delete(player_to_move)
					@table_player_counts[network_game] -= 1
					@table_player_counts[other_ng] += 1
				end
			end
		end
	end

	def close_table_if_possible(network_game)
		available_seats = 0
		@table_player_counts.each do |other_ng, n|
			next if other_ng == network_game
			available_seats += (10 - n)
		end
		if available_seats >= network_game.seats.size #We can close this table
			network_game.stop_timer_thread
			table = network_game.table
			log "We are closing table #{table.table_id} because we have enough open seats"
			new_counts_hash = {}
			@table_player_counts.each do |other_ng, n|
				next if other_ng == network_game
				break if table.seats.size == 0
				other_table = other_ng.table
				log "Moving #{10 - n} players to table #{other_table.table_id}"
				@player_queue[other_table.table_id] ||= []
				new_counts_hash[other_ng] = n
				(10 - n).times do
					p = table.seats.pop
					@player_queue[other_table.table_id] << p
					new_counts_hash[other_ng] += 1
					break if table.seats.size == 0
				end
			end
			log "Done moving all players"
			new_counts_hash.each do |other_ng, n|
				@table_player_counts[other_ng] = n
			end
			@table_player_counts.delete(network_game)
			log "Done closing table"
			true
		else
			false
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
			Stats.record_stats_if_configured(@finish_order + [winner])
		end
	end

	def current_level
		elapsed = (Time.now - @start_time).to_i
		elapsed / @blind_timer
	end

	def current_small_blind
		l = current_level
		multiplier = l > BLIND_LEVELS.size ? BLIND_LEVELS.last : BLIND_LEVELS[l]
		sb = @small_blind * multiplier
		log "#{(Time.now - @start_time).to_i} seconds have gone by, so the level is #{l}, blind timer is #{@blind_timer} with blind is now at #{sb}"
		sb
	end

	def current_ante
		l = current_level
		multiplier = l > ANTE_LEVELS.size ? ANTE_LEVELS.last : ANTE_LEVELS[l]
		ante = @small_blind * multiplier
		log "#{(Time.now - @start_time).to_i} seconds have gone by, so the level is #{l}, blind timer is #{@blind_timer} with ante is now at #{ante}"
		ante
	end

	def set_blind_levels(network_game)
		network_game.table.small_blind = current_small_blind
		network_game.table.ante = current_ante
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
end #class Tournament
end