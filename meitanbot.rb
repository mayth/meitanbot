#coding:utf-8

require 'net/https'
require 'oauth'
require 'json'
require 'psych'
require 'yaml'
require 'twitter'
require 'thread'
require 'rexml/document'
require 'kconv'

class User
  attr_reader :id, :screen_name
  
  def initialize(id, screen_name)
    @id = id
    @screen_name = screen_name
  end
end

class Tweet
  attr_reader :id, :text, :user, :other
  
  def initialize(id, text, user, other = nil)
    @id = id
    @text = text
    @user = user
    if other
      raise ArgumentError unless other.is_a?(Hash)
      @other = other
    end
  end
end

class CurrentWeather 
  attr_reader :condition, :temp, :humidity, :wind

  def initialize(condition, temp, humidity, wind)
    @condition = condition
	@temp = temp
	@humidity = humidity.gsub('湿度 : ', '')
	@wind = wind.gsub('風: ', '')
  end
end

class ForecastWeather 
  attr_reader :condition, :day_of_week, :low, :high

  def initialize(day_of_week, condition, low, high)
    @day_of_week = day_of_week
	@condition = condition
	@low = Integer(low)
	@high = Integer(high)
  end
end

class MeitanBot
  # YAML-File including credential data
  CREDENTIAL_FILE = 'credential.yaml'
  # Text for replying "not-meitan"
  NOTMEITAN_FILE = 'notmeitan.txt'
  # Text for replying mentions
  MENTION_FILE = 'reply_mention.txt'
  # Text for replying "C#"
  REPLY_CSHARP_FILE = 'reply_csharp.txt'
  # Text for replying morning greeting
  REPLY_MORNING_FILE = 'reply_morning.txt'
  # Text for replying departure posts
  REPLY_DEPARTURE_FILE = 'reply_departure.txt'
  # Text for replying returning posts
  REPLY_RETURN_FILE = 'reply_return.txt'
  # HTTPS Certificate file
  HTTPS_CA_FILE = 'certificate.crt'

  # Forecast API URL
  FORECAST_API_URL = 'http://www.google.com/ig/api'
  # Forecast location
  FORECAST_LOCATION = 'tsukuba,ibaraki'

  # Screen name of this bot
  SCREEN_NAME = 'meitanbot'
  # User-Agent
  BOT_USER_AGENT = 'Nowhere-type Meitan bot 1.0 by @maytheplic'
  # Continuative retrying count when disconnected from Twitter or exception was thrown
  # If retry count is exceeded this value, sleeping receiver _LONG_RETRY_INTERVAL_ sec.
  MAX_CONTINUATIVE_RETRY_COUNT = 5
  # Interval time for continuative retrying
  SHORT_RETRY_INTERVAL = 15
  # Interval time for retrying. This value will be used when retry count is exceeded _MAX_CONTINUATIVE_RETRY_COUNT_
  LONG_RETRY_INTERVAL = 60
  # Twitter ID of the owner of this bot
  OWNER_ID = 246793872
  # Twitter ID of this bot
  MY_ID = 323080975
  # Twitter IDs to ignore
  IGNORE_IDS = [MY_ID]
  # Sleeping time when Twitter API returns 403(Forbidden)
  SLEEP_WHEN_FORBIDDEN = 600
  # Interval time for statistics
  STAT_INTERVAL = 60
  # Statistics output file
  STAT_FILE = 'statistics.log'

  # Initialize this class.
  def initialize
    # Queue for threads
    @post_queue = Queue.new
    @reply_queue = Queue.new
	@retweet_queue = Queue.new
    @event_queue = Queue.new
    @message_queue = Queue.new
    
    ## Statistics
    # Required time for status update request.
    @tweet_request_time = Array.new
    @statistics = {
      tweet_request_time_average: 0.0,
      post_received_count: 0,
      event_received_count: 0,
      message_received_count: 0,
      reply_received_count: 0,
      post_count: 0,
      reply_count: 0,
      send_message_count: 0,
      total_retry_count: 0
    }

    # fields
    @is_ignore_owner = true
    @is_enabled_posting = true

    # load credential
    open(CREDENTIAL_FILE) do |file|
      @credential = YAML.load(file)
    end

    @consumer = OAuth::Consumer.new(
      @credential['consumer_key'],
      @credential['consumer_secret']
    )
    
    @access_token = OAuth::AccessToken.new(
      @consumer,
      @credential['access_token'],
      @credential['access_token_secret']
    )

    read_post_text_files
  end

  # Connect to Twitter UserStream
  def connect
    uri = URI.parse("https://userstream.twitter.com/2/user.json?track=#{SCREEN_NAME}")

    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.ca_file = HTTPS_CA_FILE
    https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    https.verify_depth = 5

    https.start do |https|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = BOT_USER_AGENT
      request.oauth!(https, @consumer, @access_token)

      buf = ""
      https.request(request) do |response|
        response.read_body do |chunk|
          buf << chunk
          while ((line = buf[/.+?(\r\n)+/m]) != nil)
            begin
              buf.sub!(line, "")
              line.strip!
              status = JSON.parse(line)
            rescue
              break
            end

            yield status
          end
        end
      end
    end
  end

  # Start bot
  def run
    puts 'run!'

    post_thread = Thread.new do
      puts 'post thread start'
      loop do
        json = @post_queue.pop
        user = json['user']
        if json['text'].include?('#meitanbot') and user['id'] == OWNER_ID
          puts 'Owner update the status including meitanbot hash-tag.'
          @retweet_queue.push json
        end
		unless IGNORE_IDS.include?(user['id'])
          if /^@#{SCREEN_NAME} (今|明日|あさって)の天気を教えて( #[a-zA-Z0-9_]+){0,1}$/=~ json['text']
            puts "Inquiry of weather detected. reply to #{json['id']}"
            p $1 
			ahead = 0
            case $1
            when '今'
              ahead = 0
            when '明日'
              ahead = 1
            when 'あさって'
              ahead = 2
            end
            @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :weather, :ahead => ahead}))
		  end # end of checking for replying text
          unless (@is_ignore_owner and user['id'] == OWNER_ID)
            if /め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]*ん/ =~ json['text'] or json['text'].include?('#mei_tan')
              puts "meitan detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :meitan}))
            elsif /^@#{SCREEN_NAME}/ =~ json['text']
              @statistics[:reply_received_count] += 1
              puts "reply detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :normal_reply}))
            elsif /.*C#.*/ =~ json['text']
              puts "C# detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :csharp}))
            elsif /(おはよ[うー]{0,1}(ございます|ございました){0,1})|(むくり)|(^mkr$)/ =~ json['text'] and not (/^@[a-zA-Z0-9_]+/ =~ json['text'])
              puts "morning greeting detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :morning}))
            end # end of replying text checks
          else
            puts 'owner ignored'
          end # end of unless block (ignoring owner)
        else
		  puts "ignore list includes id:#{user['id']}. ignored."
		end # end of unless block (ignoring IGNORE_IDS)
      end # end of loopd
    end # end of Thread

    sleep 1

    reply_thread = Thread.new do
      puts 'reply thread start'
      loop do
        tweet = @reply_queue.pop
		puts "tweet: text=#{tweet.text}, other=#{tweet.other.inspect}"
        case tweet.other[:reply_type]
        when :meitan
          res = reply_meitan(tweet.user, tweet.id)
        when :normal_reply
          res = reply_mention(tweet.user, tweet.id)
        when :csharp
          res = reply_csharp(tweet.user, tweet.id)
        when :morning
          res = reply_morning(tweet.user, tweet.id)
        when :weather
          res = reply_weather(tweet.user, tweet.id, tweet.other[:ahead])
        else
          puts "undefined reply_type: #{tweet.other[:reply_type]}"
		end
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "reply thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    
    sleep 1
    
    retweet_thread = Thread.new do
      puts 'retweet thread start'
      loop do
        json = @retweet_queue.pop
        res = retweet(json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "retweet thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    
    sleep 1

    event_thread = Thread.new do
      puts 'event thread start'
      loop do
        json = @event_queue.pop
        case json['event'].to_sym
        when :follow
          puts "new follower: id:#{json['source']['id']}, screen_name:@#{json['source']['screen_name']}"
          follow_user json['source']['id']
        end
      end
    end

    sleep 1

    message_thread = Thread.new do
      puts 'message thread start'
      loop do
        json = @message_queue.pop
        puts 'Message received.'
        sender = json['direct_message']['sender']
        text = json['direct_message']['text'].strip
        if sender['id'] == OWNER_ID && text.start_with?('cmd ')
          puts "Received Command Message"
		  cmd_ary = text.split
		  cmd_ary.shift
		  cmd = cmd_ary.shift
          control_command(cmd.to_sym, cmd_ary, true)
        end
      end # end of loop do ...
    end # end of Thread.new do ...

    sleep 1

    time_signal_thread = Thread.new do
      puts 'time signal thread start'
      loop do
        t = Time.now.getutc
        if t.min == 0
          loop do
            t = Time.now.getutc
            h = t.hour + 7
            diff = t.sec < 10 ? 0 : t.sec - 1
            post_time_signal h >= 24 ? h - 24 : h
            sleep(60 * 60 - diff) # sleep 1 hour
          end
        end
      end
    end

    sleep 1

    friendship_check_thread = Thread.new do
      puts 'friendship check thread start'
      loop do
        follow_unfollowing_user
        remove_removed_user
        sleep(60 * 60 * 12) # sleep half a day
      end
    end

    sleep 1

    receiver_thread = Thread.new do
      begin
        puts "receiver thread start"
        total_retry_count = 0
        retry_count = 0
        loop do
          begin
            connect do |json|
              if json['text']
                @statistics[:post_received_count] += 1
                @post_queue.push json
              elsif json['event']
                @statistics[:event_received_count] += 1
                @event_queue.push json
              elsif json['direct_message']
                @statistics[:message_received_count] += 1
                @message_queue.push json
              end
            end
          rescue Timeout::Error, StandardError
            puts '<RESCUE> SConnection to Twitter is disconnected or Application error was occured.'
            @statistics[:total_retry_count] += 1
            if (retry_count < MAX_CONTINUATIVE_RETRY_COUNT)
              retry_count += 1
              puts $!
              puts("<RESCUE> retry:#{retry_count}")
              sleep SHORT_RETRY_INTERVAL
              puts 'retry!'
            else
              puts '<RESCUE> Continuative retry was failed. Receiver will sleep long...'
              sleep LONG_RETRY_INTERVAL
              retry_count = 0
              puts 'retry!'
            end
          end
        end
      ensure
        puts 'receiver thread terminated.'
        post "Terminating meitan-bot Bye! #{Time.now.strftime("%X")}"
      end
    end
    
    sleep 1
    
    statistics_thread = Thread.new do
      begin
        puts 'statistics thread start'
        before_time = Time.now
        puts "<STAT> Meitan-bot statistics thread started at #{Time.now.strftime("%X")}"
        loop do
          current_time = Time.now
          puts "<STAT> Statistics at #{current_time.to_s}"
          @tweet_request_time.compact!
          total = 0.0
          for t in @tweet_request_time
            total += t
          end
          @statistics[:tweet_request_time_average] = total / @statistics[:post_count]
          @statistics.to_s.lines do |line|
            puts "<STAT> #{line}"
          end
          if (current_time.min % 10) == 0
            puts 'output log'
            out = { current_time.strftime('%F_%H:%M') => @statistics }
            open(STAT_FILE, 'a:UTF-8') do |file|
              file << out.to_yaml
            end
          end
          sleep STAT_INTERVAL
        end
      ensure
        puts "<STAT> Meitan-bot statistics thread terminated at #{Time.now.strftime("%X")}"
      end
    end
    
    sleep 1

    tweet_greeting
    
    puts 'startup complete.'
  end # end of run method

  # Tweet the greeting post when bot is started.
  def tweet_greeting
    puts "greeting"
    post "Starting meitan-bot. Hello! #{Time.now.strftime('%X')}"
  end

  # Tweet the time signal post.
  def post_time_signal(hour)
    puts "time signal: #{hour}"
    post "#{hour}時(TST)をお知らせします。"
  end

  # Tweet "I'm not meitan!"
  def reply_meitan(reply_to_user, in_reply_to_id)
    puts "replying to meitan"
    post_reply(reply_to_user, in_reply_to_id, random_notmeitan)
  end

  # Reply to reply to me
  def reply_mention(reply_to_user, in_reply_to_id)
    puts "replying to mention"
    post_reply(reply_to_user, in_reply_to_id, random_mention)
  end

  # Reply to the post containing "C#"
  def reply_csharp(reply_to_user, in_reply_to_id)
    puts "replying to csharp"
    post_reply(reply_to_user, in_reply_to_id, random_csharp)
  end
  
  def reply_morning(reply_to_user, in_reply_to_id)
    puts 'replying to morning greeting'
    post_reply(reply_to_user, in_reply_to_id, random_morning)
  end

  def reply_departure(reply_to_user, in_reply_to_id)
    puts 'replying to departure'
    post_reply(reply_to_user, in_reply_to_id, random_departure)
  end
  
  def reply_return(reply_to_user, in_reply_to_id)
    puts 'replying to returning'
    post_reply(reply_to_user, in_reply_to_id, random_return)
  end

  def reply_weather(reply_to_user, in_reply_to_id, ahead)
    raise ArgumentError if ahead < 0 or 4 < ahead
	puts 'replying to weather inquiry'
	doc = REXML::Document.new(Net::HTTP.get(URI.parse(FORECAST_API_URL + '?weather=' + FORECAST_LOCATION + '&hl=ja')).toutf8)
    puts 'doc generated.'
	if ahead == 0 # Get current condition
      puts 'get current conditions'
	  cond_element = doc.elements['/xml_api_reply/weather/current_conditions']
	  p cond_element
	  cond = CurrentWeather.new(
        cond_element.elements['condition'].attributes['data'],
        cond_element.elements['temp_c'].attributes['data'],
		cond_element.elements['humidity'].attributes['data'],
		cond_element.elements['wind'].attributes['data'])
	  puts "cond: condition=#{cond.condition}, temp=#{cond.temp}, humidity=#{cond.humidity}, wind=#{cond.wind}"
	  post_reply(reply_to_user, in_reply_to_id, "今の天気は#{cond.condition}、気温#{cond.temp}℃、湿度#{cond.humidity}、風は#{cond.wind}だよ。")
    else # Get forecast condition
      puts 'get forecast condition'
	  cond_element = doc.elements['/xml_api_reply/weather/forecast_conditions[' + String(ahead) + ']']
	  cond = ForecastWeather.new(
	    cond_element.elements['condition'].attributes['data'],
		cond_element.elements['day_of_week'].attributes['data'],
		cond_element.elements['low'].attributes['data'],
		cond_element.elements['high'].attributes['data'])
	  case Integer(ahead)
	  when 1
	    target_day = '明日'
      when 2
	    target_day = 'あさって'
      else
        puts 'unknown ahead value'
	    raise ArgumentError
	  end
	  puts "cond:"
	  puts " condition=#{cond.condition}"
	  puts " temp=#{String(cond.temp)}"
	  puts " humidity=#{String(cond.humidity)}"
	  puts " wind=#{String(cond.wind)}"
	  puts "target_day: #{target_day}"
	  post_reply(reply_to_user, in_reply_to_id, "#{target_day}（#{cond.day_of_week}曜日）の天気は#{cond.condition}、気温は最高#{cond.high}℃、最低#{cond.low}℃だよ。")
    end
  end

  # Reply
  def post_reply(reply_to_user, in_reply_to_id, status)
    if @is_enabled_posting
      @statistics[:post_count] += 1
      @statistics[:reply_count] += 1
      puts "replying"
      req_start = Time.now
      @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => "@#{reply_to_user.screen_name} " + status,
        'in_reply_to_status_id' => in_reply_to_id)
      req_end = Time.now
      @tweet_request_time << req_end - req_start
    else
      puts "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Post
  def post(status)
    if @is_enabled_posting
      @statistics[:post_count] += 1
      puts "posting"
      req_start = Time.now
      res = @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => status)
      req_end = Time.now
      @tweet_request_time << req_end - req_start
    else
      puts "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Retweet the status
  def retweet(id)
    @statistics[:post_count] += 1
    puts "retweeting status-id: #{id}"
    req_start = Time.now
    @access_token.post("https://api.twitter.com/1/statuses/retweet/#{id}.json")
    req_end = Time.now
    @tweet_request_time << req_end - req_start
  end

  # Send Direct Message
  def send_direct_message(text, recipient_id)
    @statistics[:send_message_count] += 1
    puts "Sending Direct Message"
    @access_token.post('https://api.twitter.com/1/direct_messages/new.json',
      'user_id' => recipient_id,
      'text' => text)
  end

  # Follow the user
  def follow_user(id)
    unless id == MY_ID
      puts "following user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/create.json',
        'user_id' => id)
    end
  end

  # Remove the user
  def remove_user(id)
    unless id == MY_ID
      puts "removing user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/destroy.json',
        'user_id' => id)
    end
  end

  # Get "not-meitan" text
  def random_notmeitan
    @notmeitan_text.sample
  end

  # Get the replying text
  def random_mention
    @reply_mention_text.sample
  end

  # Get the replying for the status containing "C#"
  def random_csharp
    @reply_csharp_text.sample
  end

  # Get the replying text for the status containing morning greeting
  def random_morning
    @reply_morning_text.sample
  end
  
  # Get the replying text for the status containing departures
  def random_departure
    @reply_departure_text.sample
  end
  
  def random_return
    @reply_return_text.sample
  end

  # Get followers
  def get_followers(cursor = '-1')
    puts "get_followers: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/followers/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json
      # get_followers(json['next_cursor_str'])
      return result.flatten!
    end
  end

  # Get followings
  def get_followings(cursor = '-1')
    puts "get_followings: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/friends/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json
      # get_followings(json['next_cursor_str'])
      return result.flatten!
    end
  end

  # Follow the user that he/she follows me but I don't.
  # [RETURN] Number of following users after this following process.
  def follow_unfollowing_user
    # Following new users
    # followers - following = need to follow
    followers = get_followers
    followings = get_followings
    need_to_follow = followers - followings

    puts "need to follow: "
    for id in need_to_follow do
      puts " #{id}"
    end

    for id in need_to_follow do
      follow_user id
    end

    return followings.size + need_to_follow.size
  end

  # Remove the user that he/she removed me but I'm still following.
  # [RETURN] Number of following users after this removing process.
  def remove_removed_user
    followers = get_followers
    followings = get_followings
    need_to_remove = followings - followers

    puts 'need to remove: '
    for id in need_to_remove do
      puts " #{id}"
    end

    for id in need_to_remove do
      remove_user id
    end
    
    return followings.size - need_to_remove.size
  end

  # Reading the text for tweet from files.
  def read_post_text_files
    open(MENTION_FILE, 'r:UTF-8') do |file|
      @reply_mention_text = file.readlines.collect{|line| line.strip}
    end

    open(NOTMEITAN_FILE, 'r:UTF-8') do |file|
      @notmeitan_text = file.readlines.collect{|line| line.strip}
    end

    open(REPLY_CSHARP_FILE, 'r:UTF-8') do |file|
      @reply_csharp_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_MORNING_FILE, 'r:UTF-8') do |file|
      @reply_morning_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_DEPARTURE_FILE, 'r:UTF-8') do |file|
      @reply_departure_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_RETURN_FILE, 'r:UTF-8') do |file|
      @reply_return_text = file.readlines.collect{|line| line.strip}
    end

    puts 'notmeitan text:'
    for s in @notmeitan_text do
      puts ' ' + s
    end

    puts 'reply text:'
    for s in @reply_mention_text do
      puts ' ' + s
    end

    puts 'reply csharp text:'
    for s in @reply_csharp_text do
      puts ' ' + s
    end
    
    puts 'reply departure text:'
    for s in @reply_departure_text do
      puts ' ' + s
    end

    puts 'reply returning text:'
    for s in @reply_return_text do
      puts ' ' + s
    end
  end
  
  # Control this bot.
  # _cemmand_ is command symbol.
  # _params_ is command parameters. Parameters is array.
  # If _report_by_message is true, report the command result by sending direct message to owner. By default, this is true.
  def control_command(command, params, report_by_message = true)
    puts "control_command: #{command}"
    raise ArgumentError unless params.is_a?(Array)
	case command
    when :is_ignore_owner
      if params[0]
        case params[0].to_sym
        when :true
          @is_ignore_owner = true
        when :false
          @is_ignore_owner = false
        else
          puts 'unknown value'
        end
      else
        puts 'no param'
      end
      puts "command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}"
      send_direct_message("command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_ignore_owner?
      puts "inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}"
      send_direct_message("inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_enable_posting
      if params[0]
        case params[0].to_sym
        when :true
          @is_enabled_posting = true
        when :false
          @is_enabled_posting = false
        else
          puts 'unknown value'
        end
      else
        puts 'no param'
      end
      puts "command<is_enable_posting> accepted. current value is #{@is_enabled_posting}"
      send_direct_message("command<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :is_enable_posting?
      puts "inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}"
      send_direct_message("inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :show_post_text_count
      puts "command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}"
      send_direct_message("command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :reload_post_text
      read_post_text_files
      puts "command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}"
      send_direct_message("command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :ignore_user
      log = "command<ignore_user> accepted."
      id = 0
      begin
        id = Integer(params[1])
      rescue
        puts 'ID Conversion failure. Try to get ID from string'
        begin
          screen_name = String(params[1])
          res = @access_token.post('http://api.twitter.com/1/users/lookup.json', 'screen_name' => screen_name)
          json = JSON.parse(res.body)
          json.each do |user|
            id = json['id'] if json['screen_name'] == screen_name
          end
        rescue
          puts 'String conversion / Get the ID from Screen Name failure.'
        end
      end
      unless id == 0
        if params[0]
          case params[0].to_sym
          when :add
            unless IGNORE_IDS.include?(id)
              IGNORE_IDS.concat id
              log += " added #{id}"
            end
          when :remove
            if IGNORE_IDS.include?(id)
              IGNORE_IDS.delete id
              log += " removed #{id}"
            end
          end
        else
          puts 'no param'
        end
      else
        puts 'ID is 0'
      end
      log += " current ignoring users: #{IGNORE_IDS.size}"
      puts log
      send_direct_message(log, OWNER_ID) if report_by_message
    when :check_friendships
      follow_unfollowing_user
      users = remove_removed_user
      puts "command<check_friendships> accepted. current followings: #{users}"
    when :show_friendships
      followings = get_followings
      followers = get_followers
      puts "inquiry<show_friendships> accepted. followings/followers=#{followings.size}/#{followers.size}"
      send_direct_message("inquiry<show_friendships> accepted. followings/followers=#{followings.size}/#{followers.size}", OWNER_ID) if report_by_message
    when :help
      puts "inquiry<help> accepted. Available commands: is_ignore_owner(?), is_enable_posting(?), reload_post_text, ignore_user."
      send_direct_message("This function is only available on command-line.", OWNER_ID) if report_by_message
    when :ping
      puts 'inquiry<ping> accepted. Meitan-bot is alive! ' + Time.now.to_s
      send_direct_message("inquiry<ping> accepted. Meitan-bot is alive! #{Time.now.to_s}", OWNER_ID) if report_by_message
    else
      puts 'unknown command received. to show help, please send help command.'
      send_direct_message('unknown command received.', OWNER_ID) if report_by_message
    end
  end

end


if $0 == __FILE__
  bot = MeitanBot.new
  bot.run

  command_line_vars = {is_report_enabled: false}

  loop do
    print 'meitan-bot> '  
    line = gets
    line.chop!
    cmd_ary = line.split(nil, 2)
    redo unless cmd_ary[0]
    case cmd_ary[0].to_sym
    when :show_vars
      puts command_line_vars.inspect
    when :is_report_enabled
      if cmd_ary[1]
        case cmd_ary[1].to_sym
        when :true
          command_line_vars[:is_report_enabled] = true
        when :false
          command_line_vars[:is_report_enabled] = false
        end
      end
      puts "Report by Direct Message: #{command_line_vars[:is_report_enabled]}"
    when :exit, :quit
      break
    else
      param = cmd_ary[1] ? cmd_ary[1].split : []
      bot.control_command(cmd_ary[0].to_sym, param, command_line_vars[:is_report_enabled])
    end
  end
end
