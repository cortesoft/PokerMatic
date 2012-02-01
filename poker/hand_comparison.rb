module PokerMatic
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
end