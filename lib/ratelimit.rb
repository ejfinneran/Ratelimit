require 'redis'
require 'redis-namespace'

class Ratelimit

  # Create a RateLimit object.
  #
  # @param [String] key A name to uniquely identify this rate limit. For example, 'emails'
  # @param [Redis] redis Redis instance to use. One is created if nothing is passed.
  # @param [Hash] options Options hash
  # @option options [Integer] :bucket_span (600) Time span to track in seconds
  # @option options [Integer] :bucket_interval (5) How many seconds each bucket represents
  # @option options [Integer] :bucket_expiry (1200) How long we keep data in each bucket before it is auto expired.
  #
  # @return [RateLimit] RateLimit instance
  #
  def initialize(key, redis = nil, options = {}) #bucket_span = 600, bucket_interval = 5, bucket_expiry = 1200, redis = nil)
    @key = key
    @bucket_span = options[:bucket_span] || 600
    @bucket_interval = options[:bucket_interval] || 5
    @bucket_expiry = options[:bucket_expiry] || 1200
    @bucket_count = (@bucket_span / @bucket_interval).round
    @redis = redis
  end

  # Add to the counter for a given subject.
  #
  # @param [String] subject A unique key to identify the subject. For example, 'user@foo.com'
  def add(subject)
    bucket = get_bucket
    subject = "#{@key}:#{subject}"
    redis.multi do
      redis.hincrby(subject, bucket, 1)
      redis.hdel(subject, (bucket + 1) % @bucket_count)
      redis.hdel(subject, (bucket + 2) % @bucket_count)
      redis.expire(subject, @bucket_expiry)
    end 
  end

  # Returns the count for a given subject and interval
  #
  # @param [String] subject Subject for the count
  # @param [Integer] interval How far back (in seconds) to retrieve activity.
  def count(subject, interval)
    bucket = get_bucket
    interval = [interval, @bucket_interval].max
    count = (interval / @bucket_interval).floor
    subject = "#{@key}:#{subject}"
    counts = redis.multi do
      redis.hget(subject, bucket)
      count.downto(1) do
        bucket -= 1
        redis.hget(subject, (bucket + @bucket_count) % @bucket_count)
      end
    end
    return counts.inject(0) {|a, i| a += i.to_i}
  end

  # Check if the rate limit has been exceeded.
  #
  # @param [String] subject Subject to check
  # @param [Hash] options Options hash
  # @option options [Integer] :interval How far back to retrieve activity.
  # @option options [Integer] :threshold Maximum number of actions
  def exceeded?(subject, options = {})
    return count(subject, options[:interval]) >= options[:threshold]
  end

  # Check if the rate limit is within bounds
  #
  # @param [String] subject Subject to check
  # @param [Hash] options Options hash
  # @option options [Integer] :interval How far back to retrieve activity.
  # @option options [Integer] :threshold Maximum number of actions
  def within_bounds?(subject, options = {})
    return !exceeded?(subject, options)
  end

  # Execute a block once the rate limit is within bounds
  # *WARNING* This will block the current thread until the rate limit is within bounds.
  #
  # @param [String] subject Subject for this rate limit
  # @param [Hash] options Options hash
  # @option options [Integer] :interval How far back to retrieve activity.
  # @option options [Integer] :threshold Maximum number of actions
  # @yield The block to be run
  #
  # @example Send an email as long as we haven't send 5 in the last 10 minutes
  #   ratelimit.exec_with_threshold(email, [:threshold => 5, :interval => 600]) do
  #     send_another_email
  #   end
  def exec_within_threshold(subject, options = {}, &block)
    options[:threshold] ||= 30
    options[:interval] ||= 30
    while exceeded?(subject, options)
      sleep @bucket_interval
    end
    yield(self)
  end

  private

  def get_bucket(time = Time.now.to_i)
    ((time % @bucket_span) / @bucket_interval).floor
  end

  def redis
    @redis ||= Redis::Namespace.new(:ratelimit, :redis => @redis || Redis.new)
  end
end
