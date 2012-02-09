module PokerMatic
	class Stats
		
		def self.record_stats_if_configured(finish_order)
			if defined?(STATS_FILE) and STATS_FILE
				s = self.new(STATS_FILE)
				s.store_stats(finish_order)
			end
		end

		def initialize(path)
			@path = path
			if File.exists?(@path)
				@stats = JSON.parse(File.read(@path))
			else
				@stats = {"bots" => {}, "tournaments" => {}}
			end
		end

		def print
			bot_names = @stats["bots"].keys.sort
			puts "###### Poker Bot Stats ######"
			puts "| Name | Wins | Average Finish | Standard Deviation |"
			bot_names.each do |bot_name|
				pct_fins = percentile_finishes_for(bot_name)
				puts "| #{bot_name} | #{wins_for(bot_name)} | #{pct_fins.mean.to_i} | #{pct_fins.standard_deviation.to_i rescue 0} |"
			end
		end

		def percentile_finishes_for(bot_name)
			@stats["bots"][bot_name].map {|x| 
				total_players = @stats["tournaments"][x["tournament"]]["total_players"]
				((total_players - x["finish"]) / total_players.to_f) * 100
			}
		end

		def wins_for(bot_name)
			@stats["bots"][bot_name].select {|x| 
				total_players = @stats["tournaments"][x["tournament"]]["total_players"]
				x["finish"] == total_players
			}.size
		end

		def save
			File.open(@path, "w") {|f| f.write(@stats.to_json)}
		end

		def store_stats(finish_order)
			finish_order.map! {|x| x.name }
			register_tournament(finish_order)
			finish_order.each_with_index {|name, i| store_player_stats(name, i + 1)}
			save
		end

		def register_tournament(finish_order)
			@tourney_id = (@stats["tournaments"].size + 1).to_s
			@stats["tournaments"][@tourney_id] = {"total_players" => finish_order.size,
				"all_players" => finish_order, "date" => Time.now}
		end

		def store_player_stats(name, finish_position)
			bot_name = extract_bot_name(name)
			@stats["bots"][bot_name] ||= []
			@stats["bots"][bot_name] << {'finish' => finish_position, 'tournament' => @tourney_id}
		end

		def extract_bot_name(name)
			name.split(" ").first
		end
	end#class Stats
end

module Enumerable
    def sum
      self.inject(0){|accum, i| accum + i }
    end

    def mean
      self.sum/self.length.to_f
    end

    def sample_variance
      m = self.mean
      sum = self.inject(0){|accum, i| accum +(i-m)**2 }
      sum/(self.length - 1).to_f
    end

    def standard_deviation
      return Math.sqrt(self.sample_variance)
    end
end 