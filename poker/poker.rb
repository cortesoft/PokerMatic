module PokerMatic
	require 'set'
	["player", "table", "deck", "card", "hand_comparison"].each do |fname|
		require File.expand_path("#{File.dirname(__FILE__)}/#{fname}.rb")
	end
end #module PokerMatic