#coding:utf-8

require 'net/https'
require 'oauth'
require 'json'
require 'psych'
require 'yaml'
require 'thread'
require 'rexml/document'
require 'kconv'
require 'sqlite3'
require 'date'
require 'MeCab'

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
  class Config
    def Config.load(path)
      c = new()
      c.instance_eval File.read(path)
      c
    end

    attr_accessor :max_continuative_retry_count
    attr_accessor :short_retry_interval, :long_retry_interval
    attr_accessor :reply_limit_reset_time, :reply_limit_threshold
    attr_accessor :sleep_when_forbidden_time
    attr_accessor :stat_interval
    attr_accessor :stat_file_prefix, :log_file_prefix
    attr_accessor :tsukuba_time_table
    attr_accessor :ignore_id_file
    attr_accessor :random_post_interval, :word_replace_probability
    attr_accessor :min_word_length, :min_status_length
  end

  class StatTypes
    STARTUP = 'START'
    STAT = 'STATS'
    NORMAL = 'NORML'
    ERROR = 'ERROR'
  end

  # DateTime format from Twitter API
  TWITTER_DATETIME_FORMAT = '%a %b %d %H:%M:%S +0000 %Y'
  # DateTime format to output to DB
  DB_DATETIME_FORMAT = '%Y-%m-%d %H:%M:%S'

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
  # Text for replying sleeping posts
  REPLY_SLEEPING_FILE = 'reply_sleeping.txt'
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
  # Twitter ID of the owner of this bot
  OWNER_ID = 246793872
  # Twitter ID of this bot
  MY_ID = 323080975
  # Twitter IDs to ignore
  IGNORE_IDS = []

  # Database for post
  POST_DATABASE_FILE = 'posts.db'

  # Regular-Expression that represents replying
  REPLY_REGEX = /^@[a-zA-Z0-9_]+ /

  # Initialize this class.
  def initialize
    # Queue for threads
    @received_queue = Queue.new
    @post_queue = Queue.new
    @reply_queue = Queue.new
    @retweet_queue = Queue.new
    @event_queue = Queue.new
    @message_queue = Queue.new
    @log_queue = Queue.new
    @recorder_queue = Queue.new

    @replied_count = Hash.new

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

    load_config

    read_post_text_files

    # load ignore list
    open(@config.ignore_id_file, 'r:UTF-8') do |file|
      IGNORE_IDS << Integer(file.readline)
    end
    IGNORE_IDS.uniq!
  end

  def load_config
    @config = Config.load('config')
  end

  def config
    @config
  end

  def update_config(key, value)
    if @config.method_defined?(key + '=')
      @config.send(key + '=', value)
    else
      log("config key:#{key} is undefined.", StatTypes::ERROR)
    end
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

  def get_usertimeline
    res = @access_token.get('https://api.twitter.com/1/statuses/home_timeline.json?count=100&trim_user=true&include_rts=false&exclude_replies=false')
    JSON.parse(res.body)
  end

  # Start bot
  def run
    log('run!', StatTypes::STARTUP)

    log_thread = Thread.new do
      log 'log thread start'
      loop do
        s = @log_queue.pop
        write_log s
      end
    end

    recorder_thread = Thread.new do
      log('recorder thread start', StatTypes::STARTUP)
      loop do
        json = @recorder_queue.pop
        db = SQLite3::Database.new(POST_DATABASE_FILE)
        begin
          text = create_cleared_text json['text']
          unless text.length < @config.min_status_length
            time = DateTime.parse(json['created_at'], TWITTER_DATETIME_FORMAT)
            mecab = MeCab::Tagger.new
            node = mecab.parseToNode(text)
            db.transaction do
              db.execute('insert into posts values(?, ?, ?, ?, ?, ?)', json['id'], json['user']['id'], json['in_reply_to_status_id'], time.strftime(DB_DATETIME_FORMAT), text, 0) # last element is post class. classfy!
              while node
                if node.stat == 2 or node.stat == 3 or (node.posid < 36 or 67 < node.posid)
                  node = node.next
                  next
                end
                if node.surface.length < @config.min_word_length
                  node = node.next
                  next
                end
                type = 1 # Type 1 means this word is noun.
                db.execute('insert into words values(NULL, ?, ?, ?, ?, ?)', json['user']['id'], time.strftime(DB_DATETIME_FORMAT), type, node.surface, 0) # last element is word class. classify!
                node = node.next
              end
            end # transaction end
          end # end unless statement
        rescue
          log($!, StatTypes::ERROR)
        ensure
          db.close
        end
      end
    end

    response_thread = Thread.new do
      log('response thread start', StatTypes::STARTUP)
      loop do
        json = @received_queue.pop
        user = json['user']
        if /(^#meitanbot | #meitanbot$)/ =~ json['text'] and user['id'] == OWNER_ID
          log('Owner update the status including meitanbot hash-tag.')
          @retweet_queue.push json
        end
		unless IGNORE_IDS.include?(user['id'])
          if /^@#{SCREEN_NAME} (今|明日|あさって)の天気を教えて$/=~ json['text']
            log "Inquiry of weather detected. reply to #{json['id']}"
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
			next
          elsif /^@#{SCREEN_NAME} ([1-6１２３４５６一二三四五六壱弐参伍])時{0,1}限目{0,1}(の時間を教えて)?$/ =~ json['text']
		    log "Inquiry of timetable detected. reply to #{json['id']}"
			time = 0
			case $1
			when '1', '１', '一', '壱'
              time = 1
			when '2', '２', '二', '弐'
              time = 2
			when '3', '３', '三', '参'
              time = 3
			when '4', '４', '四'
              time = 4
			when '5', '５', '五', '伍'
              time = 5
			when '6', '６', '六'
              time = 6
			end
			@reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :time_inquiry, :time => time}))
			next
		  end # end of checking for replying text
          @recorder_queue.push json
          unless (@is_ignore_owner and user['id'] == OWNER_ID)
            if /め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]*ん/ =~ json['text'] or json['text'].include?('#mei_tan')
              log "meitan detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :meitan}))
            elsif /^@#{SCREEN_NAME}/ =~ json['text']
              @statistics[:reply_received_count] += 1
              log "reply detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :normal_reply}))
            elsif /.*C#.*/ =~ json['text']
              log "C# detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :csharp}))
            elsif /あ[あぁ]、?(.*)ってそういう/ =~ json['text']
              log "metaphor detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :metaphor, :word => $1}))
            elsif not REPLY_REGEX.match(json['text'])
              if /(おはよ[うー]{0,1}(ございます|ございました){0,1})|(^(むくり|mkr)$)/ =~ json['text']
                log "morning greeting detected. reply to #{json['id']}"
                @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :morning}))
              end
              if /(おやすみ(なさい)ー?)|(寝る)/ =~ json['text']
                log "sleeping detected. reply to #{json['id']}"
                @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :sleeping}))
              end
              if /((い|行)ってきまー?すー?)|(いてきまー)|(出発)|(でっぱつ)/ =~ json['text']
			    log "departure detected. reply to #{json['id']}"
                @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :departure}))
              end
              if /(ただいま|帰宅)/ =~ json['text']
                log "returning detected. reply to #{json['id']}"
			    @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :returning}))
              end
            elsif json['text'].include?('ぬるぽ')
              log "nullpo detected. reply to #{json['id']}"
              @reply_queue.push(Tweet.new(json['id'], json['text'], User.new(user['id'], user['screen_name']), {:reply_type => :nullpo}))
            end # end of replying text checks
          else
            log 'owner ignored'
          end # end of unless block (ignoring owner)
        else
		  log "ignore list includes id:#{user['id']}. ignored."
		end # end of unless block (ignoring IGNORE_IDS)
      end # end of loopd
    end # end of Thread

    sleep 1

    reply_thread = Thread.new do
      log('reply thread start', StatTypes::STARTUP)
      loop do
        tweet = @reply_queue.pop
        unless @replied_count[tweet.user.id]
          @replied_count[tweet.user.id] = {reset_time: Time.now + @config.reply_limit_reset_time, count: 0}
        end
        @replied_count[tweet.user.id][:count] += 1
        if @replied_count[tweet.user.id][:count] > @config.reply_limit_threshold
          if @replied_count[tweet.user.id][:reset_time] < Time.now
            @replied_count[tweet.user.id] = {reset_time: Time.now + @config.reply_limit_reset_time, count: 0}
          else
            log "user:#{tweet.user.name}(#{tweet.user.id}) exceeds reply limit! suspend!"
            IGNORE_IDS << tweet.user.id
          end
        end
        case tweet.other[:reply_type]
        when :meitan
          res = reply_meitan(tweet.user, tweet.id)
        when :normal_reply
          res = reply_mention(tweet.user, tweet.id)
        when :csharp
          res = reply_csharp(tweet.user, tweet.id)
        when :morning
          res = reply_morning(tweet.user, tweet.id)
        when :sleeping
          res = reply_sleeping(tweet.user, tweet.id)
        when :returning
          res = reply_return(tweet.user, tweet.id)
        when :departure
          res = reply_departure(tweet.user, tweet.id)
        when :weather
          res = reply_weather(tweet.user, tweet.id, tweet.other[:ahead])
        when :nullpo
          res = reply_nullpo(tweet.user, tweet.id)
        when :time_inquiry
          res = reply_time_inquiry(tweet.user, tweet.id, tweet.other[:time])
        when :metaphor
          res = reply_metaphor(tweet.user, tweet.id, tweet.other[:word])
        else
          log("undefined reply_type: #{tweet.other[:reply_type]}", StatTypes::ERROR)
        end
        if res === Net::HTTPForbidden
          log("returned 403 Forbidden. Considering status duplicate, or rate limit.", StatTypes::ERROR)
          log "reply thread sleeps #{@config.sleep_when_forbidden_time} sec"
          sleep @config.sleep_when_forbidden_time
        end
      end
    end
    
    sleep 1
    
    retweet_thread = Thread.new do
      log('retweet thread start', StatTypes::STARTUP)
      loop do
        json = @retweet_queue.pop
        res = retweet(json['id'])
        if res === Net::HTTPForbidden
          log('returned 403 Forbidden. Considering status duplicate, or rate limit.', StatTypes::ERROR)
          log "retweet thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    
    sleep 1

    event_thread = Thread.new do
      log('event thread start', StatTypes::STARTUP)
      loop do
        json = @event_queue.pop
        case json['event'].to_sym
        when :follow
          log "new follower: id:#{json['source']['id']}, screen_name:@#{json['source']['screen_name']}"
          follow_user json['source']['id']
        when :unfollow
          log "removed from: id:#{json['source']['id']}, screen_name:@#{json['source']['screen_name']}"
          remove_user json['source']['id']
        end
      end
    end

    sleep 1

    message_thread = Thread.new do
      log('message thread start', StatTypes::STARTUP)
      loop do
        json = @message_queue.pop
        log 'Message received.'
        sender = json['direct_message']['sender']
        text = json['direct_message']['text'].strip
        if sender['id'] == OWNER_ID && text.start_with?('cmd ')
          log "Received Command Message"
		  cmd_ary = text.split
		  cmd_ary.shift
		  cmd = cmd_ary.shift
          control_command(cmd.to_sym, cmd_ary, true)
        end
      end # end of loop do ...
    end # end of Thread.new do ...

    sleep 1

    post_thread = Thread.new do
      log('post thread start', StatTypes::STARTUP)
      loop do
        s = @post_queue.pop
        post(s)
      end
    end

    sleep 1

    random_post_thread = Thread.new do
      log('random post thread start', StatTypes::STARTUP)
      loop do
        @post_queue.push random_post
        sleep @config.random_post_interval
      end
    end

    sleep 1

    time_signal_thread = Thread.new do
      log('time signal thread start', StatTypes::STARTUP)
      loop do
        e = Time.now.getutc
        if t.min == 0 and t.sec < 5
          h = t.hour + 7
          post_time_signal(h >= 24 ? h - 24 : h)
          while Time.now.getutc.min == 0
            sleep(1)
          end
        end
      end
    end

    sleep 1

    friendship_check_thread = Thread.new do
      log('friendship check thread start', StatTypes::STARTUP)
      loop do
	    log 'check friendship'
        follow_unfollowing_user
        remove_removed_user
        sleep(60 * 60 * 12) # sleep half a day
      end
    end

    sleep 1

    receiver_thread = Thread.new do
      begin
        log('receiver thread start', StatTypes::STARTUP)
        total_retry_count = 0
        retry_count = 0
        loop do
          begin
            connect do |json|
              if json['text'] and not json['retweeted_status']
                @statistics[:post_received_count] += 1
                @received_queue.push json
              elsif json['event']
                @statistics[:event_received_count] += 1
                @event_queue.push json
              elsif json['direct_message']
                @statistics[:message_received_count] += 1
                @message_queue.push json
              end
            end
          rescue Timeout::Error, StandardError
            log('Connection to Twitter is disconnected or Application error was occured.', StatTypes::ERROR)
            log($!, StatTypes::ERROR)
            @statistics[:total_retry_count] += 1
            if (retry_count < @config.max_continuative_retry_count)
              retry_count += 1
              log('retry:#{retry_count}')
              sleep @config.short_retry_interval
              log 'retry!'
            else
              log('Continuative retry was failed. Receiver will sleep long...', StatTypes::ERROR)
              sleep @config.long_retry_interval
              retry_count = 0
              log 'retry!'
            end
          end
        end
      ensure
        # Termination post
        post "Terminating meitan-bot Bye! #{Time.now.strftime("%X")}"
        log 'receiver thread terminated.'
        # Write ignore id list
        update_ignore_list
      end
    end
    
    sleep 1
    
    statistics_thread = Thread.new do
      begin
        log('statistics thread start', StatTypes::STARTUP)
        before_time = Time.now
        log("Meitan-bot statistics thread started at #{Time.now.strftime("%X")}", StatTypes::STARTUP)
        loop do
          current_time = Time.now
          log("Statistics at #{current_time.to_s}", StatTypes::STAT)
          @tweet_request_time.compact!
          total = 0.0
          for t in @tweet_request_time
            total += t
          end
          @statistics[:tweet_request_time_average] = total / @statistics[:post_count]
          @statistics.to_s.lines do |line|
            log(line, StatTypes::STAT)
          end
          if (current_time.min % 10) == 0
            log('output stat', StatTypes::STAT)
            out = { current_time.strftime('%F_%H:%M') => @statistics }
            open(@config.stat_file_prefix + Time.now.strftime('%Y%m%d'), 'a:UTF-8') do |file|
              file << out.to_yaml
            end
          end
          sleep @config.stat_interval
        end
      ensure
        log("Meitan-bot statistics thread terminated at #{Time.now.strftime("%X")}", StatTypes::STAT)
      end
    end
    
    sleep 1

    tweet_greeting
    
    log('startup complete.', StatTypes::STARTUP)
  end # end of run method

  # Tweet the greeting post when bot is started.
  def tweet_greeting
    log "greeting"
    post "Starting meitan-bot. Hello! #{Time.now.strftime('%X')}"
  end

  # Tweet the time signal post.
  def post_time_signal(hour)
    log "time signal: #{hour}"
    post "#{hour}時(TST)をお知らせします。"
  end

  # Tweet "I'm not meitan!"
  def reply_meitan(reply_to_user, in_reply_to_id)
    log "replying to meitan"
    post_reply(reply_to_user, in_reply_to_id, random_notmeitan)
  end

  # Reply to reply to me
  def reply_mention(reply_to_user, in_reply_to_id)
    log "replying to mention"
    post_reply(reply_to_user, in_reply_to_id, random_mention(reply_to_user.id))
  end

  # Reply to the post containing "C#"
  def reply_csharp(reply_to_user, in_reply_to_id)
    log "replying to csharp"
    post_reply(reply_to_user, in_reply_to_id, random_csharp)
  end
  
  def reply_morning(reply_to_user, in_reply_to_id)
    log 'replying to morning greeting'
    post_reply(reply_to_user, in_reply_to_id, random_morning)
  end

  def reply_sleeping(reply_to_user, in_reply_to_id)
    log 'replying to sleeping'
    post_reply(reply_to_user, in_reply_to_id, random_sleeping)
  end

  def reply_departure(reply_to_user, in_reply_to_id)
    log 'replying to departure'
    post_reply(reply_to_user, in_reply_to_id, random_departure)
  end
  
  def reply_return(reply_to_user, in_reply_to_id)
    log 'replying to returning'
    post_reply(reply_to_user, in_reply_to_id, random_return)
  end

  def reply_weather(reply_to_user, in_reply_to_id, ahead)
    raise ArgumentError if ahead < 0 or 4 < ahead
	log 'replying to weather inquiry'
	doc = REXML::Document.new(Net::HTTP.get(URI.parse(FORECAST_API_URL + '?weather=' + FORECAST_LOCATION + '&hl=ja')).toutf8)
    log 'doc generated.'
	if ahead == 0 # Get current condition
      log 'get current conditions'
	  cond_element = doc.elements['/xml_api_reply/weather/current_conditions']
	  p cond_element
	  cond = CurrentWeather.new(
        cond_element.elements['condition'].attributes['data'],
        cond_element.elements['temp_c'].attributes['data'],
		cond_element.elements['humidity'].attributes['data'],
		cond_element.elements['wind'].attributes['data'])
	  log "cond: condition=#{cond.condition}, temp=#{cond.temp}, humidity=#{cond.humidity}, wind=#{cond.wind}"
	  post_reply(reply_to_user, in_reply_to_id, "今の天気は#{cond.condition}、気温#{cond.temp}℃、湿度#{cond.humidity}、風は#{cond.wind}だよ。")
    else # Get forecast condition
      log 'get forecast condition'
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
        log 'unknown ahead value'
	    raise ArgumentError
	  end
	  log "cond:"
	  log " condition=#{cond.condition}"
	  log " temp=#{String(cond.temp)}"
	  log " humidity=#{String(cond.humidity)}"
	  log " wind=#{String(cond.wind)}"
	  log "target_day: #{target_day}"
	  post_reply(reply_to_user, in_reply_to_id, "#{target_day}（#{cond.day_of_week}曜日）の天気は#{cond.condition}、気温は最高#{cond.high}℃、最低#{cond.low}℃だよ。")
    end
  end

  def reply_nullpo(reply_to_user, in_reply_to_id)
    post_reply(reply_to_user, in_reply_to_id, 'ｶﾞｯ')
  end

  def reply_time_inquiry(reply_to_user, in_reply_to_id, time)
    post_reply(reply_to_user, in_reply_to_id, "#{time}時限目は #{@config.tsukuba_time_table[time - 1][0]} から #{@config.tsukuba_time_table[time - 1][1]} までだよ。")
  end

  def reply_metaphor(reply_to_user, in_reply_to_id, word)
    post_reply(reply_to_user, in_reply_to_id, "#{word}ってどういう？")
  end

  def random_post()
    db = SQLite3::Database.new(POST_DATABASE_FILE)
    status = db.get_first_value('SELECT status FROM posts ORDER BY RANDOM() LIMIT 1')
    words = db.execute('SELECT word FROM words ORDER BY RANDOM() LIMIT 10')
    db.close
    mecab = MeCab::Tagger.new
    node = mecab.parseToNode(status)
    result = Array.new
    while node
      unless node.stat == 2 or node.stat == 3 
        if node.posid < 36 or 67 < node.posid
          result << node.surface
        else
          if rand(100) < @config.word_replace_probability 
            result << words[rand(10)]
          else
            result << node.surface
          end
        end
      end
      node = node.next
    end
    result.join(nil)
  end

  # Reply
  def post_reply(reply_to_user, in_reply_to_id, status)
    if @is_enabled_posting
      @statistics[:post_count] += 1
      @statistics[:reply_count] += 1
      log "replying"
      req_start = Time.now
      res = @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => "@#{reply_to_user.screen_name} " + status,
        'in_reply_to_status_id' => in_reply_to_id)
      req_end = Time.now
      @tweet_request_time << req_end - req_start
      res
    else
      log "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Post
  def post(status)
    if @is_enabled_posting
      @statistics[:post_count] += 1
      log "posting"
      req_start = Time.now
      res = @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => status)
      req_end = Time.now
      @tweet_request_time << req_end - req_start
      res
    else
      log "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Retweet the status
  def retweet(id)
    @statistics[:post_count] += 1
    log "retweeting status-id: #{id}"
    req_start = Time.now
    @access_token.post("https://api.twitter.com/1/statuses/retweet/#{id}.json")
    req_end = Time.now
    @tweet_request_time << req_end - req_start
  end

  # Send Direct Message
  def send_direct_message(text, recipient_id)
    @statistics[:send_message_count] += 1
    log "Sending Direct Message"
    @access_token.post('https://api.twitter.com/1/direct_messages/new.json',
      'user_id' => recipient_id,
      'text' => text)
  end

  # Follow the user
  def follow_user(id)
    unless id == MY_ID
      log "following user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/create.json',
        'user_id' => id)
    end
  end

  # Remove the user
  def remove_user(id)
    unless id == MY_ID
      log "removing user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/destroy.json',
        'user_id' => id)
    end
  end

  # Get "not-meitan" text
  def random_notmeitan
    @notmeitan_text.sample
  end

  # Get the replying text
  def random_mention(id)
    db = SQLite3::Database.new(POST_DATABASE_FILE)
    status = db.get_first_value('SELECT status FROM posts WHERE user_id = ? ORDER BY RANDOM() LIMIT 1', id)
    user_words = db.execute('SELECT word FROM words WHERE user_id = ? ORDER BY RANDOM() LIMIT 5', id)
    other_words = db.execute('SELECT word FROM words ORDER BY RANDOM() LIMIT 5')
    db.close
    words = user_words + other_words
    mecab = MeCab::Tagger.new
    node = mecab.parseToNode(status)
    result = Array.new
    while node
      unless node.stat == 2 or node.stat == 3
        if node.posid < 36 or 67 < node.posid
          result << node.surface
        else
          if rand(100) < @config.word_replace_probability
            result << words[rand(10)]
          else
            result << node.surface
          end
        end
      end
      node = node.next
    end
    result.join(nil)
  end

  # Get the replying for the status containing "C#"
  def random_csharp
    @reply_csharp_text.sample
  end

  # Get the replying text for the status containing morning greeting
  def random_morning
    @reply_morning_text.sample
  end
  
  # Get the replying text for the status containing sleeping
  def random_sleeping
    @reply_sleeping_text.sample
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
    log "get_followers: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/followers/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json['ids']
      if json['next_cursor_str']
        result << get_followers(json['next_cursor_str'])
      end
      return result.flatten!
    end
  end

  # Get followings
  def get_followings(cursor = '-1')
    log "get_followings: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/friends/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json['ids']
      if json['next_cursor_str']
        result << get_followings(json['next_cursor_str'])
      end
      return result.flatten!
    end
  end

  # Follow the user that he/she follows me but I don't.
  # [RETURN] Number of following users after this following process.
  def follow_unfollowing_user
    # Following new users
    # followers - following = need to follow
    begin
      followers = get_followers
      followings = get_followings
      need_to_follow = followers - followings
    rescue
      log($!, StatTypes::ERROR)
    end

    log "need to follow: "
    for id in need_to_follow do
      log " #{id}"
    end

    for id in need_to_follow do
      follow_user id
    end

    return followings.size + need_to_follow.size
  end

  # Remove the user that he/she removed me but I'm still following.
  # [RETURN] Number of following users after this removing process.
  def remove_removed_user
    begin
      followers = get_followers
      followings = get_followings
      need_to_remove = followings - followers
    rescue
      log($!, StatTypes::ERROR)
    end

    log 'need to remove: '
    for id in need_to_remove do
      log " #{id}"
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
    
    open(REPLY_SLEEPING_FILE, 'r:UTF-8') do |file|
      @reply_sleeping_text = file.readlines.collect{|line| line.strip}
    end

    open(REPLY_DEPARTURE_FILE, 'r:UTF-8') do |file|
      @reply_departure_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_RETURN_FILE, 'r:UTF-8') do |file|
      @reply_return_text = file.readlines.collect{|line| line.strip}
    end

    log 'notmeitan text:'
    for s in @notmeitan_text do
      log ' ' + s
    end

    log 'reply text:'
    for s in @reply_mention_text do
      log ' ' + s
    end

    log 'reply csharp text:'
    for s in @reply_csharp_text do
      log ' ' + s
    end
    
    log 'reply departure text:'
    for s in @reply_departure_text do
      log ' ' + s
    end

    log 'reply returning text:'
    for s in @reply_return_text do
      log ' ' + s
    end
  end

  def update_ignore_list
    log 'update ignore list'
    open(@config.ignore_id_file, 'w:UTF-8') do |file|
     IGNORE_IDS.each {|s| file.puts s}
    end
  end

  # Create cleared text
  # _s_ is the text to clear.
  # Cleared text is the text that is removed mentions, hashtags, URLs, RTs and QTs.
  def create_cleared_text(s)
    s.gsub(/[RMQ]T @[a-zA-Z0-9_]+:.*/, '')
     .gsub(/\. ?(@[a-zA-Z0-9_]+ )+/, '')
     .gsub(/@[a-zA-Z0-9_]+/, '')
     .gsub(%r[(https?|ftp)(:\/\/[-_.!~*\'()a-zA-Z0-9;\/?:\@&=+\$,%#]+)], '')
     .gsub(/#.+([ 　、。]|$)/, '')
     .strip
  end

  # Control this bot.
  # _cemmand_ is command symbol.
  # _params_ is command parameters. Parameters is array.
  # If _report_by_message is true, report the command result by sending direct message to owner. By default, this is true.
  def control_command(command, params, report_by_message = true)
    log "control_command: #{command}"
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
          log('unknown value', StatTypes::ERROR)
        end
      else
        log('no param', StatTypes::ERROR)
      end
      log("command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}")
      send_direct_message("command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_ignore_owner?
      log("inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}")
      send_direct_message("inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_enable_posting
      if params[0]
        case params[0].to_sym
        when :true
          @is_enabled_posting = true
        when :false
          @is_enabled_posting = false
        else
          log('unknown value', StatTypes::ERROR)
        end
      else
        log('no param', StatTypes::ERROR)
      end
      log("command<is_enable_posting> accepted. current value is #{@is_enabled_posting}")
      send_direct_message("command<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :is_enable_posting?
      log("inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}")
      send_direct_message("inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :show_post_text_count
      log("command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}")
      send_direct_message("command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :reload_post_text
      read_post_text_files
      log("command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}")
      send_direct_message("command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :load_config
      load_config
      log 'command<load_config> accepted.'
      send_direct_message('command<load_config> accepted.') if report_by_message
    when :update_config
      update_config(params[0], params[1])
      log 'command<update_config> accepted.'
      send_direct_message('command<update_config> accepted.') if report_by_message
    when :ignore_user
      logstr = "command<ignore_user> accepted."
      id = 0
      begin
        id = Integer(params[1])
      rescue
        log('ID Conversion failure. Try to get ID from string')
        begin
          screen_name = String(params[1])
          res = @access_token.post('http://api.twitter.com/1/users/lookup.json', 'screen_name' => screen_name)
          json = JSON.parse(res.body)
          json.each do |user|
            id = json['id'] if json['screen_name'] == screen_name
          end
        rescue
          log('String conversion / Get the ID from Screen Name failure.', StatTypes::ERROR)
        end
      end
      unless id == 0
        if params[0]
          case params[0].to_sym
          when :add
            unless IGNORE_IDS.include?(id)
              IGNORE_IDS.concat id
              logstr += " added #{id}"
            end
          when :remove
            if IGNORE_IDS.include?(id)
              IGNORE_IDS.delete id
              logstr += " removed #{id}"
            end
          end
        else
          log('no param', StatTypes::ERROR)
        end
      else
        log('ID is 0', StatTypes::ERROR)
      end
      logstr += " current ignoring users: #{IGNORE_IDS.size}"
      log(logstr)
      send_direct_message(logstr, OWNER_ID) if report_by_message
    when :update_ignore_list
      log 'command<update_ignore_list> accepted.'
      update_ignore_list
      log "now ignoring #{IGNORE_IDS.size} user(s)."
      send_direct_message("comamnd<update_ignore_list> accepted. now ignoring #{IGNORE_IDS.size} user(s).") if report_by_message
    when :check_friendships
      follow_unfollowing_user
      users = remove_removed_user
      log("command<check_friendships> accepted. current followings: #{users}")
	  send_direct_message("command<check_friendships> accepted. current followings: #{users}") if report_by_message
    when :show_friendships
      followings = get_followings
      followers = get_followers
      log("inquiry<show_friendships> accepted. followings/followers=#{followings.size}/#{followers.size}")
      send_direct_message("inquiry<show_friendships> accepted. followings/followers=#{followings.size}/#{followers.size}", OWNER_ID) if report_by_message
    when :show_db_status
      db = SQLite3::Database.new(POST_DATABASE_FILE)
      posts = db.execute('select * from posts');
      words = db.execute('select * from words');
      db.close
      log("inquiry<show_db_status> accepted. current recorded posts=#{posts.size}, words=#{words.size}")
      send_direct_message("inquiry<show_db_status> accepted. current recorded posts=#{posts.size}, words=#{words.size}") if report_by_message
    when :help
      log("inquiry<help> accepted. Available commands: is_ignore_owner(?), is_enable_posting(?), reload_post_text, ignore_user.")
      send_direct_message("This function is only available on command-line.", OWNER_ID) if report_by_message
    when :ping
      log('inquiry<ping> accepted. Meitan-bot is alive! ' + Time.now.to_s)
      send_direct_message("inquiry<ping> accepted. Meitan-bot is alive! #{Time.now.to_s}", OWNER_ID) if report_by_message
	when :host
	  running_host = 'unknown'
	  open('running_host', 'r:UTF-8') {|file| running_host = file.gets} if File.exist?('running_host')
	  log('inquiry<host> accepted. Meitan-bot is running at: ' + running_host)
	  send_direct_message('inquiry<host> accepted. Meitan-bot is running at: ' + running_host, OWNER_ID) if report_by_message
	when :kill
	  log('command<kill> accepted. Meitan-bot will be terminated soon.')
	  send_direct_message('command<kill> accepted. Meitan-bot will be terminated soon.', OWNER_ID) if report_by_message
	  exit
    else
      log('unknown command received. to show help, please send help command.')
      send_direct_message('unknown command received.', OWNER_ID) if report_by_message
    end
  end

  def log(s, log_type = StatTypes::NORMAL)
    @log_queue.push create_logstr(s, log_type)
  end

  def write_log(s)
    open(@config.log_file_prefix + Time.now.strftime('%Y%m%d'), 'a:UTF-8') do |file|
      file.puts s
    end
  end

  def create_logstr(s, log_type = StatTypes::NORMAL)
	"[#{Time.now.strftime('%F_%T%z')}]<#{log_type}> #{String(s)}"
  end

  private :connect, :tweet_greeting, :post_time_signal
  private :reply_meitan, :reply_mention, :reply_csharp, :reply_morning
  private :reply_departure, :reply_return, :reply_weather, :reply_nullpo
  private :post, :post_reply, :retweet, :send_direct_message, :follow_user, :remove_user
  private :random_notmeitan, :random_mention, :random_csharp
  private :random_morning, :random_departure, :random_return
  private :get_followers, :get_followings, :follow_unfollowing_user, :remove_removed_user
  private :read_post_text_files, :log
end

open('running_host', 'w:UTF-8') {|file| file.puts `echo $HOSTNAME`}

if $0 == __FILE__
  bot = MeitanBot.new
  bot.run

  command_line_vars = {is_report_message_enabled: false, is_show_result_enabled: false}

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
          command_line_vars[:is_report_message_enabled] = true
        when :false
          command_line_vars[:is_report_message_enabled] = false
        end
      end
      puts "Report by Direct Message: #{command_line_vars[:is_report_enabled]}"
	when :is_show_result_enabled
      if cmd_ary[1]
        case cmd_ary[1].to_sym
        when :true
          command_line_vars[:is_show_result_enabled] = true
        when :false
          command_line_vars[:is_show_result_enabled] = false
        end
      end
	  puts "Show Result: #{command_line_vars[:is_show_result_enabled]}"
    when :show_config
      p bot.config
    when :exit, :quit, :kill
      break
    else
      param = cmd_ary[1] ? cmd_ary[1].split : []
      bot.control_command(cmd_ary[0].to_sym, param, command_line_vars[:is_report_enabled])
    end
  end
end
