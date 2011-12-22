class PokerClientBase
	attr_accessor :player_id, :mutex
	

	def initialize(discovery_url = nil, discovery_capability = nil)
		@mutex = Mutex.new
		@player_id = nil
		@spire = Spire.new
		discovery_url ||= get_discovery_url
		discovery_capability ||= get_discovery_capability
		d_sub = new_sub(discovery_url, discovery_capability)
		@discovery = JSON.parse(d_sub.listen.last)
	end
	
	def get_discovery_url
		require 'config.rb'
		DISCOVERY_URL
	end
	
	def get_discovery_capability
		require 'config.rb'
		DISCOVERY_CAPABILITY
	end
	
	def player_update(data)
		if data['type'] == 'hand'
			@mutex.synchronize do
				@hand_hash[data['hand_number']] = data['hand']
				@bankroll = data['player']['bankroll']
				if @game_state_hash[data['hand_number']]
					@game_state_hash[data['hand_number']].set_hand(data['hand'])
				end
			end
		elsif data['type'] == 'error'
			invalid_move(data)
		end
	end
	
	def invalid_move(data)
		@mutex.synchronize do
			puts "Invalid move: #{data['message']}"
		end
	end

	def wait_for_hand_data(hand_number)
		20.times do
			@mutex.synchronize do
				return true if @hand_hash[hand_number]
			end
			sleep 2
		end
		false
	end
	
	def create_user(name)
		@mutex.synchronize do
			@reg_response = new_sub(@discovery['registration_response']['url'],
				@discovery['registration_response']['capability'])
			@command_id = rand(99999999)
			@reg_response.last = (Time.now.to_i * 1000) - 5
			@reg_response.add_listener('reg_response') {|m| user_created(m)}
			@reg_response.start_listening
			@create_player_channel = new_channel(@discovery['registration']['url'],
				@discovery['registration']['capability'])
			@create_player_channel.publish({'name' => name, 'id' => @command_id}.to_json)
		end
		while true
			should_exit = false
			@mutex.synchronize do
				should_exit = !!@player_id
			end
			break if should_exit
			sleep 1
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
		end
	end

	def join_specific_table(data)
		@hand_hash = {}
		@game_state_hash = {}
		@active_table_number = data['id']
		@active_table_sub = new_sub(data['url'], data['capability'])
		@active_table_name = data['name']
		@active_table_sub.add_listener('active_table_sub') {|m| table_update_proxy(m)}
		@player_updates.add_listener('player_update') {|m| player_update_proxy(m)}
		@active_table_sub.start_listening
		@player_updates.start_listening
		@player_channel.publish({'table_id' => @active_table_number, 'command' => 'join_table'}.to_json)
	end

	def table_update_proxy(m)
		parsed = JSON.parse(m)
		if parsed['type'] == 'game_state'
			hand = nil
			gs = nil
			@mutex.synchronize do
				hand = @hand_hash[parsed['hand_number']]
				gs = GameState.new(parsed, @player_id, hand)
				@game_state_hash[parsed['hand_number']] = gs
			end
			table_update(gs)
		elsif parsed['type'] == 'winner'
			winner_update(parsed)
		end
	end

	def player_update_proxy(m)
		player_update(JSON.parse(m))
	end

	def my_table_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @table_command_id
			join_specific_table(resp)
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
		@table_response.last = (Time.now.to_i * 1000) - 5
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
	
	class GameState
		attr_accessor :hand, :player_id

		def initialize(state, my_player_id, my_hand = nil)
			@state_hash = state
			@player_id = my_player_id
			@hand = my_hand
		end
		
		def [](key)
			@state_hash[key] || @state_hash['state'][key]
		end

		def method_missing(meth, *args)
			if @state_hash.has_key?(meth.to_s)
				@state_hash[meth.to_s]
			elsif @state_hash['state'].has_key?(meth.to_s)
				@state_hash['state'][meth.to_s]
			else
				super
			end
		end
		
		def set_hand(hand)
			@hand = hand
		end

		def respond_to?(meth)
			(@state_hash.has_key?(meth.to_s) or @state_hash['state'].has_key?(meth.to_s)) ? true : super
		end
		
		def in_this_hand?
			@_ith ||= @state_hash['state']['players'].any? {|p| p['id'] == @player_id}
		end
		
		def is_acting_player?
			@_iap ||= @state_hash['state']['acting_player']['id'] == @player_id
		end
	end #class GameState
end #Class PokerClientBase