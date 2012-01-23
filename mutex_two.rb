class MutexTwo
	def initialize
		@m = Mutex.new
	end
	
	def synchronize
		t = Time.now
		#sync_id = rand(99999)
		#puts "Starting synchronize id #{sync_id} from #{caller[0,3].join(",")}"
		ret = nil
		@m.synchronize do
			elapsed = Time.now - t
			if elapsed > 1
				puts "MUTEX WARNING: Took #{elapsed} seconds to lock: #{caller[0,5].join(",")}"
			end
			ret = yield
		end
		ret
	end
end