#!/usr/bin/env jruby
require File.expand_path("#{File.dirname(__FILE__)}/../shared_bot_code/bot_loader.rb")
bl = BotLoader.new

puts "Choose a bot:"
bot_map = {}
bl.bot_classes.each_with_index do |klass, i|
	puts "#{i + 1}: #{klass}"
	bot_map[i + 1] = klass
end
chosen_klass = nil
while !chosen_klass
	puts "Choose a bot class:"
	chosen_klass = bot_map[gets.chomp.to_i]
	puts "Invalid choice" unless chosen_klass
end

client = chosen_klass.new
puts "Player name?"
name = gets.chomp
client.create_user(name)
puts "Tournament or table? (1 = tournament, 2 = table)"
if gets.chomp.to_i == 1
	client.join_tournament
else
	puts "Join a room or create a new one? 'join' or name of room"
	if 'join' == (choice = gets.chomp)
		client.join_table
	else
		puts "Number of players at the table?"
		num = gets.chomp.to_i
		client.create_table(choice, num)
	end
end
while true
	sleep 1000
end