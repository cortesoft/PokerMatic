module PokerMatic
#A class for running a quick console game with 4 players
class QuickGame
	attr_reader :table
	def initialize(blinds = 1)
		@table = Table.new(blinds)
		populate_table
	end
	
	def populate_table
		@table.add_player(Player.new("Daniel"))
		@table.add_player(Player.new("Computer 1"))
		@table.add_player(Player.new("Computer 2"))
		@table.add_player(Player.new("Computer 3"))
		@table.randomize_button
	end

	def play_hand
		while true
			puts "\n\n\n\n\n\n"
			@table.deal
			while !@table.betting_complete?
				puts "\n\n\n"
				ap = @table.acting_player
				puts "Board is \n\n#{@table.board_string}\n\n"
				puts "Pot is #{@table.pot} and current bet is #{@table.current_bet}"
				puts "Minimum raise is to #{@table.current_bet + @table.minimum_bet}"
				puts "Acting player is #{ap.name} with a current bet of #{@table.current_bets[ap]}"
				puts "Hand is \n\n#{@table.acting_players_hand_string}\n\nand a stack of #{ap.bankroll}"
				puts "Bet? f for fold, c for check, call for call, # for bet"
				move = gets.chomp
				begin
					if move == 'f'
						puts "Folding"
						@table.fold(ap)
					elsif move == 'c'
						puts "Checking"
						@table.check(ap)
					elsif move == 'call'
						@table.call(ap)
					else
						puts "Betting #{move.to_i}"
						@table.bet(ap, move.to_i)
					end
				rescue
					puts "Invalid move: #{$!}"
				end
			end #while !@table.betting_complete?
			break if @table.hand_over?
		end
		puts "#### HAND OVER #####"
		puts "Board is \n\n#{@table.board_string}\n\n"
		puts "Hands still in:\n\n"
		@table.hands.each do |player, hand|
			puts "#{player.name}: #{hand.join(", ")}"
		end
		puts "\n\n"
		w = @table.showdown
		puts "#{w[:winners].map {|x| x.name}.join(", ")} won #{w[:winnings]}"
	end #def play_hand

end #class QuickGame
end