#!/usr/bin/env ruby
require 'random_client'
require 'smart_bot'
require 'steady_bot'
require 'all_in_bot'
NAMES = ['Abe', 'Ben', 'Cal', 'Dave', 'Ernie', 'Frank', 'Gary', 'Herb', 'Irvin', 'Jack',
	'Kevin', 'Lenny', 'Mike', 'Nate', 'Oren', 'Pat', 'Quin', 'Rod', 'Sam', 'Tom', 'Ursala',
	'Vince', 'Will', 'Xavier', 'Zed', 'Alice', 'Betty', 'Carla', 'Daisy', 'Eunice', 'Fern',
	'Gertrude', 'Harriet', 'Ivy', 'Jill', 'Kelly', 'Leslie', 'Mindy', 'Nelly', 'Ophilia']
KLASSES = {AllInBot => "AB", SmartBot => "SB", SteadyBot => "ST", RandomClient => "RB"}

if $PROGRAM_NAME == __FILE__
	all_clients = []
	nums = {}
	names = NAMES.shuffle + NAMES.shuffle + NAMES.shuffle
	KLASSES.keys.each do |klass|
		puts "How many #{klass} clients?"
		nums[klass] = gets.chomp.to_i
	end
	KLASSES.each do |klass, class_name|
		nums[klass].times do
			name = names.shift
			name = "#{class_name} #{name}"
			puts "Creating #{klass} client #{name}"
			client = klass.new
			client.create_user(name)
			all_clients << client
		end
	end
	puts "Tournament or table? (1 = tournament, 2 = table)"
	if gets.chomp.to_i == 1
		hsh = all_clients.first.ask_to_choose_tournament
		all_clients.each do |c|
			puts "#{c.name} joining the tourney"
			c.join_specific_tournament(hsh)
		end
	else
		hsh = all_clients.first.ask_to_choose_table
		all_clients.each do |c|
			c.join_specific_table(hsh)
		end
	end
	puts "Done joining, sleeping"
	while true
		sleep 1000
	end
end