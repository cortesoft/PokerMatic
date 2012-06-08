require 'rubygems'
require 'pp'
require 'timeout'
require 'spire_io'
require 'gibberish'
require 'openpgp'

#Fixes a super strange bug with OpenPGP where it can't find internal constants
::OpenPGP::Armor.decode(::OpenPGP::Armor.encode('hello'))

config_file_location = File.expand_path("#{File.dirname(__FILE__)}/../config.rb")
require config_file_location if File.exists?(config_file_location)
unless defined?(API_URL)
	API_URL = "https://api.spire.io"
end
require File.expand_path("#{File.dirname(__FILE__)}/../utils/mutex_two.rb")
require File.expand_path("#{File.dirname(__FILE__)}/../poker/poker.rb")


#The PokerBotBase class contains all the code needed to create PokerServer clients
#This class should be extended to create your own client; it will not work on its own
#The only method absolutely needed for your client is ask_for_move, which is called every
#time it is the client's turn to make a move.  It is passed a GameState object, which
#is a representation of the current state of the game
#NOTE: Make sure to call super on your subclass's initialize method
class PokerBotBase
	attr_accessor :player_id, :mutex, :name

	def initialize(app_id = nil)
		@mutex = MutexTwo.new
		@player_id = nil
		@spire = Spire.new(API_URL)
		@table_channel = nil
		@hand_hash = {}
    @app_id = app_id
		@app_id ||= get_app_id
    @application = @spire.api.get_application(@app_id)
		#d_sub = new_sub(discovery_url, discovery_capability)
		#@discovery = JSON.parse(d_sub.listen.last)
	end
	
  def login_member
    @member = @application.authenticate(@login, @password)
  end

  def create_member
    @member = @application.create_member(:login => @login, :password => @password, :email => @email)
  end

  def member_taken
    raise "Failed to create or login a poker player with the login #{@login}.  If you have created a player with this" +
      " login before, please make sure your login and password are correct"
  end

  def setup_discovery
    #TODO: Does anything else need to happen here?
    @discovery = @member['profile']
  end

	#Registers a user with the given name and waits for the server to respond with the created user
	def create_user(login = nil, password = nil, email = nil)
    @login = login || get_member_login
    @password = password || get_member_password
    @email = email || get_member_email
    login_member rescue create_member rescue member_taken
    setup_discovery
    @key = ::OpenPGP::Armor.encode(Digest::SHA2.new(256).digest(@password))
    @discovery['encryption_key'] = @key
    @member.update(:profile => @discovery)
    @cipher = Gibberish::AES.new(@key)
		@reg_response = new_sub(@discovery['registration_response'])
		@command_id = rand(99999999)
		@reg_response.last = (Time.now.to_i * 1000) - 5
		@reg_response.add_listener('message', 'reg_response') {|m|
      begin
        user_created(m.content)
      rescue
        puts "Error with user created: #{$!}"
        pp $!.backtrace
      end
    }
		@reg_response.start_listening
		@create_player_channel = new_channel(@discovery['registration'])
		hsh = {'login' => @login, 'id' => @command_id}
		@create_player_channel.publish(hsh.to_json)
		wait_for_player_to_be_created
	end

	def wait_for_player_to_be_created
		while true
			should_exit = false
			@mutex.synchronize do
				should_exit = !!@player_id
			end
			break if should_exit
			sleep 1
		end
		@reg_response.stop_listening if @reg_response
    true
	end

	#Callback for whenever a user is created.  If the created user was created by this client,
	#set the current user to the newly created user
	def user_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @command_id
      if resp['status'] == 'registered'
        @member = @application.authenticate(@login, @password)
        setup_discovery
				@player_channel = new_channel(@discovery['player_channel'])
				@player_updates = new_sub(@discovery['player_response'])
				@player_updates.add_listener('message', 'player_update') {|mess| table_update_proxy(mess.content)}
				@player_updates.start_listening
				@player_id = resp['player_id']
  		elsif resp['status'] == 'failed'
        puts "Failed to register for user #{@login}!"
      end
		end
	end

	def subscribe_to_table(parsed)
    puts "Subscribing to table" 
		@table_channel.stop_listening if @table_channel
		@table_channel = new_sub(parsed['table'])
		#@table_channel.last = ((Time.now.to_i - 5) * 1000)
		@table_channel.add_listener('message', 'table_update') {|mess| table_update_proxy(mess.content)}
		@table_channel.start_listening
	end

	#Joins a table described by data
	# Data should include an 'id', 'url', 'capability', and 'name'
	def join_specific_table(data)
		@player_channel.publish({'table_id' => data['id'], 'command' => 'join_table'}.to_json)
	end

	def join_specific_tournament(data)
		@player_channel.publish({'tournament_id' => data['id'], 'command' => 'join_tournament'}.to_json)
	end

	#Listener for table updates, proxys the requests to the correct handler
	def table_update_proxy(m)
		parsed = JSON.parse(m)
		case parsed['type']
			when 'game_state' then game_state_update(parsed)
			when 'winner' then winner_update(parsed)
			when 'error' then invalid_move(parsed)
			when 'table_subscription' then subscribe_to_table(parsed)
    end
  rescue
    puts "Error during table update: #{$!.inspect}"
    pp $!.backtrace
	end

	def decrypt_hand(encrypted_hand)
		encrypted_hand.map do |card|
			ret = {}
			card.each do |key, value|
        begin
          text = ::OpenPGP::Armor.decode(value)
				  ret[key] = @cipher.dec(text)
				  ret[key] = ret[key].to_i if key == "value"
				rescue
          puts "Error decrypting hand! #{$!.inspect}"
          puts "Entire encrypted hand:"
          pp encrypted_hand
          puts "Bad key: #{key}"
          puts "Bad value: #{value}"
          puts "Unarmored: #{::OpenPGP::Armor.decode(value)}"
        end
			end
			ret
		end
	end

	#Called whenever a new game state comes in
	#Creates a GameState object, waits for the hand information to come in,
	#and calls ask_for_move if it is the clients turn
	#Also calls display_game_state if the client has defined it
	def game_state_update(parsed_state)
		game_state = nil
		@mutex.synchronize do
			if parsed_state['player_data'] and my_data = parsed_state['player_data'][@player_id.to_s]
				hand = decrypt_hand(my_data['hand'])
				@hand_hash[parsed_state['hand_number']] = hand
				@seat_number = my_data['seat_number']
				@bankroll = my_data['player']['bankroll']
			else
				hand = @hand_hash[parsed_state['hand_number']]
			end
			game_state = GameState.new(parsed_state, @player_id, hand)
		end
		@mutex.synchronize do
			self.display_game_state(game_state) if self.respond_to?(:display_game_state)
			if game_state.is_acting_player? and game_state.hand
				begin
					#Timeout.timeout(game_state.timelimit) do
						move = ask_for_move(game_state)
						move = 'fold' unless move
						make_move(game_state, move)
					#end
				#rescue Timeout::Error
					#puts "Took too long to make a move, folding"
				rescue
					puts "Error: #{$!.inspect}"
					pp $!.backtrace
				end
			end
		end
	end

	def make_move(game_state, move)
		@player_channel.publish({'table_id' => game_state.table_id,
			'command' => 'action', 'action' => move}.to_json)
	rescue Excon::Errors::SocketError
		puts "Excon error #{$!.inspect}"
		sleep 1
		make_move(game_state, move)
	end

	#Called when the client makes an invalid move
	#Can be overridden by subclasses to handle errors
	def invalid_move(data)
		@mutex.synchronize do
			puts "Invalid move: #{data['message']}"
		end
	end

	def winner_update(parsed)
		#Should be defined by parent class
	end

	#Callback for a table being created.. joins the table if we created it
	def my_table_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @player_id
			join_specific_table(resp)
		end
	end

	#Creates a table and joins it
	# @param [String] name Name for the table
	# @param [String] min_players Minimum players the table requires before starting game
	# @param [String] blinds Starting small blind for the table
	def create_table(name, min_players = 2, blinds = 1)
		raise "No player yet!" unless @player_id
		@table_response = new_sub(@discovery['tables'])
		@create_table_channel = new_channel(@discovery['create_table'])
		@table_response.last = (Time.now.to_i * 1000) - 5
		@table_response.add_listener('message', 'table_response') {|m|
      begin
        my_table_created(m.content)
      rescue
        puts "Error with my table created: #{$!.inspect}"
      end
    }
		@table_response.start_listening
		@create_table_channel.publish({'name' => name, 'id' => @player_id,
			'min_players' => min_players, 'blinds' => blinds}.to_json)
	end

	# Get a listing of all available tables
	# @return [Array] An array of hashes describing each table
	def get_all_tables
		tc = new_sub(@discovery['tables'])
		tc.poll[:messages].map {|x| pp x; JSON.parse(x.content) rescue nil}.compact
	end

	# Get a listing of all available tables
	# @return [Array] An array of hashes describing each table
	def get_all_tournaments
		tc = new_sub(@discovery['tournaments'])
		tc.poll[:messages].map {|x| JSON.parse(x.content) rescue nil}.compact
	end

	#Displays all available tables and prompts to join one
	#Uses gets, so requires CLI input
	def join_table
		raise "No player yet!" unless @player_id
		join_specific_table(ask_to_choose_table)
	end

	def join_tournament
		raise "No player yet!" unless @player_id
		join_specific_tournament(ask_to_choose_tournament)
	end

	def ask_to_choose_table
		#get all the possible tables
		all_tables = get_all_tables
		hsh_map = {}
		num = 0
		all_tables.each do |table|
			num += 1
			hsh_map[num] = table
			puts "Table #{num}: #{table['name']} Blinds #{table['blinds']} Min Players #{table['min_players']}"
		end
		puts "Join which table?"
		tnum = gets.chomp.to_i
		hsh_map[tnum]
	end

	def ask_to_choose_tournament
		#get all the possible tables
		all_tourneys = get_all_tournaments
		hsh_map = {}
		num = 0
		all_tourneys.each do |tourney|
			num += 1
			hsh_map[num] = tourney
			puts "Tourney #{num}: #{tourney['name']} Starting at #{Time.at(tourney['starting_time'])}"
		end
		puts "Join which tourney?"
		tnum = gets.chomp.to_i
		hsh_map[tnum]
	end

	def check_fold(game_state)
		game_state.available_moves['check'] ? 'check' : 'fold'
	end

	def ask_for_move(game_state)
		raise "Subclass does not define ask_for_move!"
	end

	def new_sub(data)
		Spire::API::Subscription.new(@spire.api, data)
	end
	
	def new_channel(data)
		Spire::API::Channel.new(@spire.api, data)
	end

  def get_app_id
    if defined?(APP_KEY)
      APP_KEY
    else
      puts "App ID?"
      gets.chomp
    end
  end

  def get_member_login
    if defined?(POKER_LOGIN) and POKER_LOGIN
      POKER_LOGIN
    else
      puts "Poker Login?"
      gets.chomp
    end
  end

  def get_member_email
    if defined?(POKER_EMAIL) and POKER_EMAIL
      POKER_EMAIL
    else
      nil
    end
  end
  
  def get_member_password
    if defined?(POKER_PASSWORD) and POKER_PASSWORD
      POKER_PASSWORD
    else
      puts "Poker Member Password?"
      gets.chomp
    end
  end
	#A class representing the current state of the game
	class GameState
		attr_accessor :hand, :player_id

		def initialize(state, my_player_id, my_hand = nil)
			@state_hash = state
			@player_id = my_player_id
			@hand = my_hand
		end
		
		#Access the state hash or sub hash directly
		def [](key)
			self.send(key.to_sym)
		end

		def tournament?
			!!@state_hash['tournament']
		end

		#Uses method missing to access the underlying state hash
		def method_missing(meth, *args)
			if @state_hash.has_key?(meth.to_s)
				@state_hash[meth.to_s]
			elsif @state_hash['state'].has_key?(meth.to_s)
				@state_hash['state'][meth.to_s]
			else
				super
			end
		end

		def respond_to?(meth)
			(@state_hash.has_key?(meth.to_s) or @state_hash['state'].has_key?(meth.to_s)) ? true : super
		end

		#Sets the clients hand for the given game state.  When the hand is returned by the server
		#before the game state is, the hand is set during initialization, otherwise it is set
		#at a later time
		def set_hand(hand)
			@hand = hand
		end
		
		# returns true if the client is in the hand
		def in_this_hand?
			@state_hash['state']['players'].any? {|p| p['id'] == @player_id}
		end

		def still_in_hand?(player_id)
			@state_hash['state']['players_in_hand'].include?(player_id.to_i)
		end

		# returns true if it is the clients turn to act
		def is_acting_player?
			@_iap ||= @state_hash['state']['acting_player']['id'] == @player_id
		end
		
		def number_of_players_in_hand
			@_npih ||= @state_hash['state']['players_in_hand'].size
		end
		
		#Returns the position of the acting player compared to the button (0 is button, 1 is the spot before the button)
		def position
			return 0 if self.button == self.acting_seat
			spots = 1
			current_spot = self.acting_seat - 1
			self.number_of_players_in_hand.size.times do
				current_spot = @state_hash['state']['players'].size - 1 if current_spot < 0
				return spots if current_spot == self.acting_seat
				spots += 1 if still_in_hand?(@state_hash['state']['players'][current_spot]['id'])
				current_spot -= 1
			end
		end
	end #class GameState
end #Class PokerBotBase