module PokerMatic
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
end