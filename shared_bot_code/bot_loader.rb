class BotLoader
	attr_reader :bot_classes, :bot_map

	def initialize(file_path = nil)
		@path = file_path || File.expand_path("#{File.dirname(__FILE__)}/../bots")
		load_bots
		map_names
	end
	
	def load_bots
		@bot_classes = []
		Dir.entries(@path).each do |fname|
			if fname.include?('.rb')
				require "#{@path}/#{fname}"
				file_data = File.read("#{@path}/#{fname}")
				file_data.scan(/class (\S*) < PokerBotBase/).flatten.each do |klass_name|
					klass = Kernel.const_get(klass_name)
					@bot_classes << klass
				end
			end
		end
		raise "No Bot Classes!" unless @bot_classes.size > 0
		@bot_classes
	end

	def map_names
		@bot_map = {}
		@bot_classes.each do |klass|
			@bot_map[klass] = prefix_for_class(klass)
		end
	end

	def prefix_for_class(klass)
		name = capital_letters_in_word(klass)
		current_attempt = name
		num = 1
		while @bot_map.values.include?(current_attempt)
			current_attempt = "#{name}#{num}"
			num += 1
		end
		current_attempt
	end

	def capital_letters_in_word(word)
		ret = []
		word.to_s.each_char do |c|
			next unless c.upcase == c
			ret << c
		end
		ret
	end
end