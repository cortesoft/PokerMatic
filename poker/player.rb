module PokerMatic
class Player
	attr_reader :bankroll, :name, :player_id, :public_key
	def initialize(name, player_id = nil, bankroll = 500, pk = nil)
		@bankroll = bankroll
		@name = name
		@player_id = player_id.to_i
		@public_key = pk
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
end