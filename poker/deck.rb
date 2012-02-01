module PokerMatic
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
end