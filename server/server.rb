require 'rubygems'
require 'pp'
require 'spire_io'
require 'gibberish'
require 'openpgp'

#Fixes a super strange bug with OpenPGP where it can't find internal constants
::OpenPGP::Armor.decode(::OpenPGP::Armor.encode('hello'))

["network_game", "quick_game", "tournament"].each do |fname|
	require File.expand_path("#{File.dirname(__FILE__)}/#{fname}.rb")
end

config_file_location = File.expand_path("#{File.dirname(__FILE__)}/../config.rb")
require config_file_location if File.exists?(config_file_location)
unless defined?(API_URL)
	API_URL = "https://api.spire.io"
end
unless defined?(APP_NAME)
  APP_NAME = "PokerMatic"
end

require File.expand_path("#{File.dirname(__FILE__)}/../poker/poker.rb")
require File.expand_path("#{File.dirname(__FILE__)}/../utils/mutex_two.rb")
require File.expand_path("#{File.dirname(__FILE__)}/../utils/stats.rb")

class PokerServer
	attr_reader :app_key, :spire

	include PokerMatic
	
	def initialize
		#Trying to avoid collisions
		@player_number = Time.now.to_i - 1323827358
		@table_number = Time.now.to_i - 1323828358
		create_spire
		@mutex = MutexTwo.new
		@log_mutex = Mutex.new
		@tables = {}
		@players = {}
		@table_names = []
		@tournaments = {}
		create_channels
		create_admin_channels
	end

	def create_spire
		@spire = Spire.new(API_URL)
    login_server_account rescue create_server_account
    find_or_create_application
	end

  def login_server_account
    check_for_missing_configs
    @session = @spire.login(SPIRE_EMAIL, SPIRE_PASSWORD).session
  end

  def create_server_account
    @session = @spire.register(:email => SPIRE_EMAIL, :password => SPIRE_PASSWORD).session
  end

  def check_for_missing_configs
    missing_configs = []
    ['SPIRE_EMAIL', 'SPIRE_PASSWORD'].each do |c|
      if !(Kernel.const_get(c) rescue false)
        missing_configs << c
      end
    end
    if missing_configs.size > 0
      raise "Please define #{missing_configs.join(" and ")} in your config.rb file"
    end
  end

  def find_or_create_application
    @application = @session.find_or_create_application(APP_NAME)
    @app_key = @application.key
    create_server_member rescue login_server_member
  end

  def create_server_member
    @server_member = @application.create_member(:login => "Admin", :password => SPIRE_PASSWORD)
  end

  def login_server_member
    @server_member = @application.authenticate("Admin", SPIRE_PASSWORD)
  end

	def create_admin_channels
		@admin = get_channel('admin')
		@admin_sub = @admin.subscribe
		@admin_sub.last = (Time.now.to_i * 1000 * 1000)
		@admin_sub.add_listener('message', "admin_sub") {|m| process_admin_command(m.content)}
		@admin_sub.start_listening
    profile = @server_member['profile']
    profile['admin'] = {
      'url' => @admin.url,
      'capabilities' => @admin.capabilities
    }
    profile['player_ids'] ||= {}
		@server_member.update(:profile => profile)
	end

	def create_channels
		@tables_channel = get_channel("tables")
		@registration = get_channel('registration')
		@registration_response = get_channel("registration_response")
		@create_table_channel = get_channel('create_table')
		@tournaments_channel = get_channel("tournaments")
		payload = {}
		[['tables', @tables_channel.subscribe, 'events'],
		['registration', @registration, 'publish'],
		['create_table', @create_table_channel, 'publish'],
		['registration_response', @registration_response.subscribe, 'events'],
		['tournaments', @tournaments_channel.subscribe, 'events']].each do |key, resource, cap|
			payload[key] = {
        'url' => resource.url, 
        'capabilities' => {cap => resource.capabilities[cap]}
      }
		end
		set_default_profile(payload)
		setup_listeners
	end

  def set_default_profile(default_profile)
    @discovery = default_profile
    @application.update(:default_profile => default_profile)
  end

	def setup_listeners
		@registration_sub = @registration.subscribe
		@registration_sub.last = (Time.now.to_i * 1000 * 1000)
		@registration_sub.add_listener('message', 'reg_sub') {|m|
      begin
        process_registration(m.content)
      rescue
        log "ERROR in registration: #{$!.inspect}"
      end
    }
		@registration_sub.start_listening
		@create_table_sub = @create_table_channel.subscribe
    @create_table_sub.last = (Time.now.to_i * 1000 * 1000)
		@create_table_sub.add_listener('message', 'create_table') {|m|
      begin
        process_create_table(m.content)
      rescue
        log "ERROR in creating table #{$!.inspect}"
        log $!.backtrace, true
      end
    }
		@create_table_sub.start_listening
	end

	#Thread safe logging to standard out
	def log(m, use_pp = false)
		@log_mutex.synchronize do
			use_pp ? pp(m) : puts("#{Time.now}: #{m}")
		end
	end

	def get_next_player_number(member = nil)
    if member && id = @server_member['profile']['player_ids'][member['login']]
      log "Got member id from my own profile"
      return id
    end
		@mutex.synchronize do
			@player_number += 1
			@player_number
      if member
        profile = @server_member['profile']
        profile['player_ids'][member['login']] = @player_number
        log "updating member"
        log profile, true
        @server_member.update(:profile => profile)
      end
      log "Updated"
      @player_number
		end
	end

  def store_player_in_member_profile(player_hash)
    #TODO This
  end

	#Process a request to register a user from the registration channel
	def process_registration(message)
		command = JSON.parse(message)
		log 'Creating player with attributes:'
		log command, true
		return unless command.has_key?('login') and command.has_key?('id')
    member = @application.get_member(command['login']) rescue nil
    if !member
      log "Could not find a member with the login #{command['login']}"
      resp_hash = {'command_id' => command['id'], 'status' => 'failed'}
      @registration_response.publish(resp_hash.to_json)
      return
    end
		pnum = get_next_player_number(member)
    profile = member['profile']
		p = Player.new(command['login'], pnum, 500, profile['encryption_key'])
		channel = get_channel("player_#{pnum}")
		sub = channel.subscribe
    sub.last = (Time.now.to_i * 1000 * 1000)
		sub.add_listener('message', "player_action") {|m| process_player_action(p, m.content)}
		sub.start_listening
		player_response = get_channel("player_response_#{pnum}")
		pr_sub = player_response.subscribe
    player_hash = {:player => p, :id => pnum,
        :channel => channel, :subscription => sub, :response_channel => player_response,
        :response_sub => pr_sub, :member => member}
		@mutex.synchronize do
			@players[pnum] = player_hash
    end
    store_player_in_member_profile(player_hash)
    profile['player_channel'] = {
      'url' => channel.url,
      'capabilities' => channel.capabilities
    }
    profile['player_response'] = {
      'url' => pr_sub.url,
      'capabilities' => pr_sub.capabilities
    }
    profile = profile.merge(@discovery)
    member.update(:profile => profile)
		resp_hash = {'command_id' => command['id'], 'player_id' => pnum, 'status' => 'registered'}
		@registration_response.publish(resp_hash.to_json)
	end #def process_registration

	#Encrypts the capabilities before sending them out, to ensure privacy
	def encrypt_capabilities(resp_hash, public_key)
		public_key_encrypter = OpenSSL::PKey::RSA.new(public_key)
		rc = public_key_encrypter.public_encrypt(resp_hash.delete('response_capability'))
		resp_hash['encrypted_response_capability'] = ::OpenPGP::Armor.encode(rc)
		c = public_key_encrypter.public_encrypt(resp_hash.delete('capability'))
		resp_hash['encrypted_capability'] = ::OpenPGP::Armor.encode(c)
	end

	#Process a create table request from the tables channel
	def process_create_table(message)
		command = JSON.parse(message)
		log 'Creating table with attributes:'
		log command, true
		next_table_number = get_next_table_number
		@mutex.synchronize do
			return unless command.has_key?('name')
			return if @table_names.include?(command['name'])
			@table_names << command['name']
			min_players = (command['min_players'] || 2).to_i
			blinds = (command['blinds'] || 1).to_i
			table = Table.new(blinds, next_table_number)
			game = NetworkGame.new(table, min_players, @log_mutex)
			channel = get_channel("table_#{next_table_number}")
			sub = channel.subscribe("sub_table_#{next_table_number}")
			game.set_table_channel(channel)
			@tables[next_table_number] = {:table => table, :min_players => min_players,
				:game => game, :name => command['name'], :mutex => MutexTwo.new, :channel => channel,
				:subscription => sub}
			@tables_channel.publish({'command_id' => command['id'], 'name' => command['name'],
				'id' => next_table_number, 'min_players' => min_players, 'blinds' => blinds}.to_json)
		end
	end

	def get_next_table_number
		@mutex.synchronize do
			@table_number += 1
			@table_number
		end
	end

	#called by the tournament code
	def register_table(table, network_game)
		log "Registering table #{table.table_id} with the server"
		channel = get_channel("table_#{table.table_id}")
		sub = channel.subscribe("sub_table_#{table.table_id}")
		hsh = {:table => table, :min_players => 2,
				:game => network_game, :name => "Table #{table.table_id}", :mutex => MutexTwo.new,
				:channel => channel, :subscription => sub}
		@mutex.synchronize do
			@tables[table.table_id] = hsh
			network_game.set_table_channel(channel)
			table.seats.each do |player|
				signal_player_to_subscribe_to_table(player, table)
			end
		end
		hsh
	end

	def signal_player_to_subscribe_to_table(player, table)
		player_channel = @players[player.player_id][:response_channel]
		table_sub = @tables[table.table_id][:subscription]
		log "Telling player #{player.name} to join table"
		hsh = {"type" => "table_subscription", 
      "table" => {
        "url" => table_sub.url,
        "capabilities" => {
          'events' => table_sub.capabilities['events']
        }
      }
    }
		log hsh, true
		player_channel.publish(hsh.to_json)
		log "Done telling player #{player.name} to join table, updating the member profile"
    member = @players[player.player_id][:member]
    profile = member['profile']
    profile['current_table'] = hsh['table']
    member.update(:profile => profile)
    log "Done updating member profile for #{player.name}"
	end

	#Process a request from a player channel
	def process_player_action(player, message)
		command = JSON.parse(message)
		log "Processing player action for #{player.name}"
		log command, true
		case command['command']
			when 'join_table' then join_table(player, command)
			when 'join_tournament' then join_tournament(player, command)
			when 'action' then take_table_action(player, command)
		end
	end

	def join_table(player, command)
		table_data = nil
		@mutex.synchronize do
			table_data = @tables[command['table_id']]
			signal_player_to_subscribe_to_table(player, table_data[:table])
		end
		return false unless table_data
		table_data[:mutex].synchronize do
			table_data[:game].join_table(player, @players[player.player_id][:response_channel])
			table_data[:game].check_start unless table_data[:game].started
		end
	end

	def join_tournament(player, command)
		@mutex.synchronize do
			return false unless tournament = @tournaments[command['tournament_id']]
			log "Player #{player.name} joined the tournament"
			tournament.join_tournament(player, @players[player.player_id][:response_channel])
		end
	end

	def take_table_action(player, command)
		table_data = nil
		@mutex.synchronize do
			table_data = @tables[command['table_id']]
		end
		return false unless table_data
		table_data[:mutex].synchronize do
			return false unless table_data[:table].acting_player == player
			table_data[:game].take_action(player, command['action'])
		end
	rescue
		puts "ERROR TAKING TABLE ACTION: #{$!.inspect}"
		pp $!.backtrace
	end

	def process_admin_command(m)
		command = JSON.parse(m)
		log "Recieved admin command:"
		log command, true
		case command['command']
			when 'create_tournament' then create_tournament(command)
		end
	end

	def create_tournament(command)
		tourney_number = get_next_table_number
		name = command['name'] || "Tourney #{tourney_number}"
		starting_blinds = command['starting_blinds'] || 25
		start_time = command['start_time'] ? Time.at(command['start_time']) : Time.now + 600
		blind_timer = command['blind_timer'] || 300
		start_chips = command['start_chips'] || 5000
		tourney = Tournament.new(:server => self, :log_mutex => @log_mutex,
			:tourney_id => tourney_number, :small_blind => starting_blinds,
			:blind_timer => blind_timer, :name => name, :start_time => start_time,
			:start_chips => start_chips)
		@mutex.synchronize do
			@tournaments[tourney_number] = tourney
			@tournaments_channel.publish({'name' => name, 'starting_time' => start_time.to_i,
				'id' => tourney_number}.to_json)
		end
		log "Tournament created"
  end

  def get_channel(name)
    @application.get_channel(name) rescue @application.create_channel(name, {:message_limit => 100})
  end
  
  def new_sub(data)
    Spire::API::Subscription.new(@spire.api, data)
  end
  
  def new_channel(data)
    Spire::API::Channel.new(@spire.api, data)
  end
end #class PokerServer